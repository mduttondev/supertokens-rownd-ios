//
//  Rownd.swift
//  framework
//
//  Created by Matt Hamann on 6/23/22.
//

import AnyCodable
import AuthenticationServices
import Foundation
import Get
import GoogleSignIn
import ReSwift
import SwiftUI
import SuperTokensIOS
import UIKit
import WebKit

public class Rownd: NSObject {
    private static let inst: Rownd = Rownd()
    public static var config: RowndConfig = RowndConfig()
    private let appStateListener = AppStateListener()

    public static let user = UserPropAccess()
    internal static var appleSignUpCoordinator: AppleSignUpCoordinator = AppleSignUpCoordinator(inst)
    internal static var googleSignInCoordinator: GoogleSignInCoordinator = GoogleSignInCoordinator(
        inst)
    @MainActor private var _bottomSheetController: BottomSheetViewController?
    @MainActor private var activeHubRequestID: UUID?
    @MainActor private var presentedHubRequestID: UUID?
    @MainActor private var dismissingHubRequestID: UUID?
    @MainActor private var pendingHubRequest: HubPresentationRequest?
    @MainActor private var presentedHubDeepLinkURL: URL?
    internal static var apiClient = RowndApi().client
    internal static let automationsCoordinator = AutomationsCoordinator()
    internal static var customerWebViews = CustomerWebViewManager()
    @MainActor private static var instantUsers: InstantUsers?
    internal static var isSuperTokensInitialized = false
    private static let smartLinkStateLock = NSLock()
    private static let signOutLock = NSLock()
    private static var pendingSignOutCount = 0
    private static var isConfigurationComplete = false
    private static var pendingSmartLinkUrls: [URL] = []
    internal static var displayHubHandler: ((HubPageSelector, Encodable?) -> Void)?

    private struct HubPresentationRequest {
        let page: HubPageSelector
        let jsFnOptions: Encodable?
        let requestID: UUID
        let deepLinkURL: URL?
    }

    // Run processAutomations() every second to support time-based automations
    internal var automationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
        Rownd.automationsCoordinator.processAutomations()
    }

    @discardableResult
    public static func configure(
        launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil,
        appKey: String?,
        appVariantId: String? = nil,
        supertokens: RowndSuperTokensConfig
    ) async -> RowndState {
        UserDefaults.standard.removeObject(forKey: "userAppleSignInData")
        smartLinkStateLock.lock()
        isConfigurationComplete = false
        smartLinkStateLock.unlock()
        do {
            let validatedConfig = try validateSuperTokensConfig(supertokens)
            config.supertokens = validatedConfig
            config.apiUrl = validatedConfig.apiDomain
        } catch {
            fatalError("Invalid Rownd SuperTokens configuration: \(error)")
        }

        if let _appKey = appKey {
            config.appKey = _appKey
        }
        config.appVariantId = appVariantId

        NetworkTimeManager.shared.start(store: Context.currentContext.store)

        let installationPreparation: InstallationSessionManager.Preparation
        do {
            try initializeSuperTokensIfNeeded()
            installationPreparation = try InstallationSessionManager.prepareForInitialization(
                config: config.supertokens
            )
            if installationPreparation.didClearSuperTokensSession,
               !Bundle.main.bundlePath.hasSuffix(".appex") {
                try await HubWebsiteDataCleaner.clear(for: config.baseUrl)
            }
        } catch {
            fatalError("Failed to initialize SuperTokens: \(error)")
        }

        var state = await inst.inflateStoreCache()
        let preparedAuthState = InstallationSessionManager.authStateAfterPreparation(
            state.auth,
            didClearSuperTokensSession: installationPreparation.didClearSuperTokensSession
        )
        var persistPreparedState: (() -> Bool)?
        if let preparedState = await MainActor.run(body: {
            applyPreparedAuthState(preparedAuthState, to: Context.currentContext.store)
        }) {
            state = preparedState
            persistPreparedState = { state.saveImmediately() }
        }
        do {
            try InstallationSessionManager.completeInitialization(
                installationPreparation,
                persistPreparedState: persistPreparedState
            )
        } catch {
            fatalError("Failed to initialize SuperTokens: \(error)")
        }
        await LegacySessionMigrator.migrateIfNeeded(authState: state.auth)
        _ = await reconcileStartupSession()

        // Skip the rest within app extensions
        if Bundle.main.bundlePath.hasSuffix(".appex") {
            return Context.currentContext.store.state
        }

        await inst.loadAppConfig()
        inst.loadAppleSignIn()

        // Start automations after initial app setup on the main actor
        await MainActor.run {
            Rownd.automationsCoordinator.start()
        }

        let store = Context.currentContext.store
        let launchUrl = launchOptions?[.url] as? URL
        if launchUrl != nil {
            SmartLinks.handleSmartLinkLaunchBehavior(launchOptions: launchOptions)
        }
        var handledDeferredSmartLink = false
        while true {
            smartLinkStateLock.lock()
            let deferredSmartLinkUrls = pendingSmartLinkUrls
            pendingSmartLinkUrls.removeAll()
            if deferredSmartLinkUrls.isEmpty {
                isConfigurationComplete = true
                smartLinkStateLock.unlock()
                break
            }
            smartLinkStateLock.unlock()

            handledDeferredSmartLink = true
            for deferredSmartLinkUrl in deferredSmartLinkUrls where deferredSmartLinkUrl != launchUrl {
                SmartLinks.handleSmartLink(url: deferredSmartLinkUrl)
            }
        }
        if store.state.isStateLoaded && !store.state.auth.isAuthenticated {
            if launchUrl == nil && !handledDeferredSmartLink {
                SmartLinks.handleSmartLinkLaunchBehavior(launchOptions: launchOptions)
            }

            if store.state.appConfig.config?.hub?.auth?.signInMethods?.google?.enabled == true {
                do {
                    _ = try await GIDSignIn.sharedInstance.restorePreviousSignIn()
                    logger.debug("Successfully restored previous Google Sign-in")
                } catch {
                    logger.warning(
                        "Failed to restore previous Google Sign-in: \(String(describing: error))")
                }
            }

            if store.state.auth.challengeId != nil || store.state.auth.userIdentifier != nil {
                var authState = store.state.auth
                authState.challengeId = nil
                authState.userIdentifier = nil
                store.dispatch(SetAuthState(payload: authState))
            }

        }

        Task {
            await fetchInitialForegroundProfileIfNeeded()
        }

        await MainActor.run {
            instantUsers = InstantUsers(context: Context.currentContext)
            instantUsers?.tmpForceInstantUserConversionIfRequested()
        }

        return Context.currentContext.store.state
    }

    @available(*, deprecated, renamed: "handleSmartLink")
    @discardableResult
    public static func handleSignInLink(url: URL?) -> Bool {
        return handleSmartLink(url: url)
    }

    @discardableResult
    public static func handleSmartLink(url: URL?) -> Bool {
        guard let url, SmartLinks.canHandleSmartLink(url: url) else { return false }
        smartLinkStateLock.lock()
        if !isConfigurationComplete {
            pendingSmartLinkUrls.append(url)
            smartLinkStateLock.unlock()
            return true
        }
        smartLinkStateLock.unlock()
        return SmartLinks.handleSmartLink(url: url)
    }

    public static func getInstance() -> Rownd {
        return inst
    }

    public static func requestSignIn() {
        requestSignIn(RowndSignInOptions())
    }

    public static func requestSignIn(with: RowndSignInHint, completion: (() -> Void)? = nil) {
        requestSignIn(with: with, signInOptions: RowndSignInOptions(), completion: completion)
    }

    public static func requestSignIn(
        with: RowndSignInHint, signInOptions: RowndSignInOptions?, completion: (() -> Void)? = nil
    ) {
        requestSignIn(with: with, signInOptions: signInOptions, initiatedByHub: false, completion: completion)
    }

    /// The Hub dispatches its own `signInStarted` before triggering native sign-in, so Hub-initiated calls skip the SDK's.
    internal static func requestSignIn(
        with: RowndSignInHint,
        signInOptions: RowndSignInOptions?,
        initiatedByHub: Bool,
        completion: (() -> Void)? = nil
    ) {
        let signInOptions = determineSignInOptions(signInOptions)
        switch with {
        case .phone:
            requestSignIn(determineSignInOptions(signInOptions, signInType: SignInType.phone))
        case .email:
            requestSignIn(determineSignInOptions(signInOptions, signInType: SignInType.email))
        case .appleId:
            appleSignUpCoordinator.signIn(signInOptions?.intent, emitsSignInStarted: !initiatedByHub)
        case .googleId:
            Task {
                await googleSignInCoordinator.signIn(
                    signInOptions?.intent,
                    hint: signInOptions?.hint,
                    emitsSignInStarted: !initiatedByHub
                )
                completion?()
            }
        case .guest, .anonymous:
            requestSignIn(determineSignInOptions(signInOptions, signInType: SignInType.anonymous))
        }

    }

    public static func requestSignIn(_ signInOptions: RowndSignInOptions?) {
        let signInOptions = determineSignInOptions(signInOptions)
        inst.displayHub(.signIn, jsFnOptions: signInOptions ?? RowndSignInOptions())
    }

    internal static func requestSignIn(jsFnOptions: Encodable?) {
        inst.displayHub(.signIn, jsFnOptions: jsFnOptions)
    }

    @MainActor internal static func requestSignInForNativeCompletion(
        jsFnOptions: Encodable?,
        requestID: UUID
    ) {
        inst.displayHubOnMainActor(.signIn, jsFnOptions: jsFnOptions, requestID: requestID)
    }

    @MainActor internal static func requestSignInForNativeCompletionFallback(
        jsFnOptions: Encodable?,
        replacing completedRequestID: UUID,
        requestID: UUID
    ) -> Bool {
        let activeRequestID = inst.activeHubRequestID
        guard activeRequestID == nil || activeRequestID == completedRequestID else {
            return false
        }
        inst.displayHubOnMainActor(.signIn, jsFnOptions: jsFnOptions, requestID: requestID)
        return true
    }

    @MainActor internal static func updateSignInForNativeCompletion(
        jsFnOptions: Encodable?,
        requestID: UUID
    ) {
        guard inst.activeHubRequestID == requestID else {
            return
        }
        inst.displayHubOnMainActor(.signIn, jsFnOptions: jsFnOptions, requestID: requestID)
    }

    @MainActor internal static func isNativeHubRequestActive(_ requestID: UUID) -> Bool {
        inst.activeHubRequestID == requestID
    }

    @MainActor internal static func canCommitAuthState(forNativeHubRequest requestID: UUID) -> Bool {
        let activeRequestID = inst.activeHubRequestID
        return activeRequestID == nil || activeRequestID == requestID
    }

    internal static func openHubDeepLink(_ url: URL) {
        logger.debug("Opening Hub deep link: \(Redact.urlForLogging(url))")
        config.pendingHubDeepLinkUrl = url
        inst.displayHub(.deepLink, jsFnOptions: nil, deepLinkURL: url)
    }

    public static func signOut(scope: RowndSignoutScope) throws {
        beginSignOut()
        Task {
            defer { endSignOut() }
            do {
                await prepareForSignOut()
                try await performSignOut(scope: scope)
            } catch {
                logger.error(
                    "Failed to sign out user from all sessions: \(String(describing: error))")
            }
        }
    }

    public static func signOut(scope: RowndSignoutScope) async throws {
        beginSignOut()
        defer { endSignOut() }
        await prepareForSignOut()
        try await performSignOut(scope: scope)
    }

    private static func performSignOut(scope: RowndSignoutScope) async throws {
        switch scope {
        case .all:
            try await Auth.signOutUser()
            await performLocalSignOut()
        }
    }

    public static func signOut() {
        beginSignOut()
        Task {
            defer { endSignOut() }
            await prepareForSignOut()
            await performLocalSignOut()
        }
    }

    public static func signOut() async {
        beginSignOut()
        defer { endSignOut() }
        await prepareForSignOut()
        await performLocalSignOut()
    }

    public static func signOut(completion: @escaping (Error?) -> Void) {
        beginSignOut()
        Task {
            defer { endSignOut() }
            await prepareForSignOut()
            await performLocalSignOut()
            completion(nil)
        }
    }

    @discardableResult
    @MainActor internal static func signOutForMigrationFailure(
        attempt: LegacyMigrationAttempt
    ) -> Bool {
        guard !Task.isCancelled, attempt.isCurrent,
              !AuthState.isSuperTokensAccessToken(attempt.auth.accessToken) else { return false }
        // Only discard the attempted legacy credentials. A concurrent native session is never signed out.
        let store = attempt.context.store
        let signedOut = AuthState(
            hasPreviouslySignedIn: store.state.auth.hasPreviouslySignedIn
        )
        store.dispatch(SetAuthState(payload: signedOut))
        store.dispatch(SetUserState(payload: UserState()))
        store.state.saveImmediately()
        RowndEventEmitter.emit(RowndEvent(event: .signOut))
        return true
    }

    private static func beginSignOut() {
        // Block immediate requestSignIn() calls before the async cleanup task starts.
        signOutLock.lock()
        pendingSignOutCount += 1
        signOutLock.unlock()
        SuperTokensSessionBridge.invalidateAuthOperationPermits()
    }

    private static func endSignOut() {
        signOutLock.lock()
        pendingSignOutCount -= 1
        signOutLock.unlock()
        Task { @MainActor in
            inst.presentPendingHubIfPossible()
        }
    }

    internal static var isSigningOut: Bool {
        signOutLock.lock()
        defer { signOutLock.unlock() }
        return pendingSignOutCount > 0
    }

    @MainActor private static func prepareForSignOut() async {
        appleSignUpCoordinator.cancelCurrentOperation()
        guard let hubController = inst._bottomSheetController?.controller as? HubViewController else { return }
        hubController.hubWebController.invalidate()
        await withCheckedContinuation { continuation in
            hubController.hide { continuation.resume() }
        }
    }

    private static func performLocalSignOut() async {
        UserDefaults.standard.removeObject(forKey: "userAppleSignInData")
        await UserData.profileHydrationRetryCoordinator.cancel()
        if isSuperTokensInitialized {
            // Keep the compatibility session from resurrecting Rownd auth on later syncs.
            await SuperTokensSessionBridge.signOut()
        }

        if !Bundle.main.bundlePath.hasSuffix(".appex") {
            do {
                try await HubWebsiteDataCleaner.clear(for: config.baseUrl)
            } catch {
                logger.error("Failed to clear Hub website data during sign-out: \(error)")
            }
        }

        await MainActor.run {
            let store = Context.currentContext.store
            store.dispatch(SetAuthState(payload: AuthState()))
            RowndEventEmitter.emit(RowndEvent(event: .signOut))
        }
    }

    public static func manageAccount() {
        inst.displayHub(.manageAccount)
    }

    /// Registers a `WKWebView` instance with Rownd, injecting JavaScript bindings and
    /// setting up a message handler to enable communication between the web content and native Swift code.
    ///
    /// This is useful when embedding Rownd's web UI inside a web view and needing native-to-web communication.
    ///
    /// - Parameter webView: The `WKWebView` to register and prepare for use with Rownd.
    /// - Returns: A closure that can be called later to deregister the web view
    public static func registerWebView(_ webView: WKWebView) -> () -> Void {
        return customerWebViews.register(webView)
    }

    @discardableResult public static func getAccessToken(throwIfMissing: Bool = false) async throws
        -> String?
    {
        let store = Context.currentContext.store
        return try await store.state.auth.getAccessToken(throwIfMissing: throwIfMissing)
    }

    public func state() -> Store<RowndState> {
        return Context.currentContext.store
    }

    public static func addEventHandler(_ handler: RowndEventHandlerDelegate) {
        Context.currentContext.eventListeners.append(handler)
    }

    internal static func determineSignInOptions(_ signInOptions: RowndSignInOptions?)
        -> RowndSignInOptions?
    {
        return determineSignInOptions(signInOptions, signInType: nil)
    }

    internal static func determineSignInOptions(
        _ signInOptions: RowndSignInOptions?, signInType: SignInType?
    ) -> RowndSignInOptions? {
        let store = Context.currentContext.store
        var signInOptions = signInOptions
        if signInOptions?.intent == RowndSignInIntent.signUp
            || signInOptions?.intent == RowndSignInIntent.signIn
        {
            if store.state.appConfig.config?.hub?.auth?.useExplicitSignUpFlow != true {
                signInOptions?.intent = nil
                logger.error(
                    "Explicit sign-in/sign-up intent is not enabled in the backend app config. Expected config.hub.auth.use_explicit_sign_up_flow=true."
                )
            }
        }

        if signInType != nil {
            signInOptions?.signInType = signInType
        }

        return signInOptions
    }

    internal static func validateSuperTokensConfig(_ config: RowndSuperTokensConfig) throws
        -> RowndSuperTokensConfig
    {
        var config = config
        if config.appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw RowndError("SuperTokens appName must not be empty")
        }

        if config.apiDomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw RowndError("SuperTokens apiDomain must not be empty")
        }

        if config.apiBasePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw RowndError("SuperTokens apiBasePath must not be empty")
        }

        var normalizedBasePath = config.apiBasePath.trimmingCharacters(in: .whitespacesAndNewlines)
        while normalizedBasePath.hasSuffix("/") && normalizedBasePath.count > 1 {
            normalizedBasePath.removeLast()
        }
        config.apiBasePath = normalizedBasePath

        return config
    }

    internal static func requireSuperTokensConfig() throws -> RowndSuperTokensConfig {
        try config.requireSuperTokensConfig()
    }

    @MainActor
    internal static func applyPreparedAuthState(
        _ preparedAuthState: AuthState,
        to store: Store<RowndState>
    ) -> RowndState? {
        guard preparedAuthState != store.state.auth else { return nil }
        store.dispatch(SetAuthState(payload: preparedAuthState))
        return store.state
    }

    @discardableResult
    internal static func reconcileStartupSession(
        persistState: @escaping @MainActor (RowndState) -> Bool = { $0.saveImmediately() }
    ) async -> Bool {
        for _ in 0..<3 {
            if let identity = await SuperTokensSessionBridge.currentSessionIdentity() {
                if await SuperTokensSessionBridge.syncRowndAuthStateFromSuperTokens(
                    afterTokenRead: {},
                    expectedSessionIdentity: identity,
                    persistState: persistState
                ) {
                    return true
                }
                continue
            }

            // getAccessToken() also returns nil when refresh fails temporarily.
            // The native SDK retains refresh credentials on those failures and
            // removes them on a definitive rejection; don't persist a logout yet.
            if SuperTokensSessionBridge.getRefreshToken()?.isEmpty == false {
                return false
            }

            let clearedPersistedSession = await MainActor.run {
                let store = Context.currentContext.store
                guard let state = store.state,
                      AuthState.isSuperTokensAccessToken(state.auth.accessToken) else {
                    return false
                }

                let hasPreviouslySignedIn = state.auth.hasPreviouslySignedIn
                let auth = AuthState(
                    hasPreviouslySignedIn: hasPreviouslySignedIn
                )
                let user = UserState()
                var candidate = state
                candidate.auth = auth
                candidate.user = user
                guard persistState(candidate) else { return false }
                store.dispatch(SetAuthState(payload: auth))
                store.dispatch(SetUserState(payload: user))
                return true
            }
            guard await SuperTokensSessionBridge.currentSessionIdentity() != nil else {
                return clearedPersistedSession
            }
        }
        return false
    }

    internal static func fetchInitialForegroundProfileIfNeeded(
        appIsActive: @escaping @MainActor () -> Bool = {
            UIApplication.shared.applicationState == .active
        },
        fetchUserData: @escaping (RowndState) async -> UserData.ForegroundFetchOutcome = {
            await UserData.fetchForegroundUserData($0)
        },
        scheduleRetry: @escaping (UserData.ForegroundFetchOutcome) async -> Void = {
            await UserData.scheduleProfileHydrationRetryIfPending($0)
        }
        ) async {
        guard let state = await MainActor.run(body: { () -> RowndState? in
            guard let state = Context.currentContext.store.state else { return nil }
            guard state.auth.isAuthenticated,
                  appIsActive(),
                  !isEmailVerificationHubRequestActiveOrPending() else {
                return nil
            }
            return state
        }) else {
            return
        }
        let outcome = await fetchUserData(state)
        await scheduleRetry(outcome)
    }

    @discardableResult
    internal static func initializeSuperTokensIfNeeded() throws -> Bool {
        guard !isSuperTokensInitialized else {
            return false
        }

        let supertokens = try requireSuperTokensConfig()
        let debugEventHandler: ((EventType) -> Void)? = config.enableDebugMode ? { event in
            logger.debug("SuperTokens event: \(String(describing: event))")
        } : nil
        let debugPreAPIHook: ((APIAction, URLRequest) -> URLRequest)? = config.enableDebugMode ? { action, request in
            logger.debug("SuperTokens request: \(String(describing: action)) \(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "")")
            return request
        } : nil
        let debugPostAPIHook: ((APIAction, URLRequest, URLResponse?) -> Void)? = config.enableDebugMode ? { action, request, response in
            let statusCode = (response as? HTTPURLResponse)?.statusCode
            logger.debug("SuperTokens response: \(String(describing: action)) \(request.url?.absoluteString ?? "") status=\(String(describing: statusCode))")
        } : nil

        try SuperTokens.initialize(
            apiDomain: supertokens.apiDomain,
            apiBasePath: supertokens.apiBasePath,
            tokenTransferMethod: .header,
            keychainAccessGroup: supertokens.keychainAccessGroup,
            eventHandler: debugEventHandler,
            preAPIHook: debugPreAPIHook,
            postAPIHook: debugPostAPIHook
        )

        URLProtocol.registerClass(SuperTokensURLProtocol.self)
        isSuperTokensInitialized = true
        return true
    }

    @MainActor internal var bottomSheetController: BottomSheetViewController {
        if let controller = _bottomSheetController {
            return controller
        }

        let controller = BottomSheetViewController()
        _bottomSheetController = controller
        return controller
    }

    // MARK: Internal methods
    private func loadAppleSignIn() {
        // If we want to check if the AppleId userIdentifier is still valid
    }

    private func loadAppConfig() async {
        let store = Context.currentContext.store
        let hasCachedAppConfig = await MainActor.run {
            store.state.appConfig.id != nil
        }
        if !hasCachedAppConfig {
            // Await the config if it wasn't already cached
            guard let appConfig = await AppConfig.fetch() else {
                return
            }

            await MainActor.run {
                store.dispatch(SetAppConfig(payload: appConfig.app))
            }
        } else {
            Task { @MainActor in
                // Refresh in background if already present
                store.dispatch(AppConfig.requestAppState())
            }
        }

    }

    @discardableResult
    private func inflateStoreCache() async -> RowndState {
        let store = Context.currentContext.store
        return await store.state.load()
    }

    private func displayHub(_ page: HubPageSelector) {
        displayHub(page, jsFnOptions: nil)
    }

    private func displayHub(
        _ page: HubPageSelector,
        jsFnOptions: Encodable?,
        deepLinkURL: URL? = nil
    ) {
        if let displayHubHandler = Rownd.displayHubHandler {
            displayHubHandler(page, jsFnOptions)
            return
        }

        let requestID = UUID()
        Task { @MainActor in
            displayHubOnMainActor(
                page,
                jsFnOptions: jsFnOptions,
                requestID: requestID,
                deepLinkURL: deepLinkURL
            )
        }
    }

    @MainActor private func displayHubOnMainActor(
        _ page: HubPageSelector,
        jsFnOptions: Encodable?,
        requestID: UUID,
        deepLinkURL: URL? = nil
    ) {
        activeHubRequestID = requestID
        if let displayHubHandler = Rownd.displayHubHandler {
            displayHubHandler(page, jsFnOptions)
            return
        }

        let request = HubPresentationRequest(
            page: page,
            jsFnOptions: jsFnOptions,
            requestID: requestID,
            deepLinkURL: deepLinkURL
        )
        guard !Self.isSigningOut, dismissingHubRequestID == nil else {
            pendingHubRequest = request
            return
        }

        presentHub(request)
    }

    @MainActor private func presentHub(_ request: HubPresentationRequest) {
        presentedHubRequestID = request.requestID
        presentedHubDeepLinkURL = request.deepLinkURL

        let hubController = getHubViewController()
        hubController.presentationRequestID = request.requestID
        hubController.onDismissalStarted = { [weak self] requestID in
            self?.hubDismissalStarted(requestID: requestID)
        }
        hubController.onDisappeared = { [weak self] requestID in
            self?.hubDidDisappear(requestID: requestID)
        }
        hubController.loadNewPage(targetPage: request.page, jsFnOptions: request.jsFnOptions)
        displayViewControllerOnTop(hubController)
    }

    @MainActor private func hubDismissalStarted(requestID: UUID) {
        guard presentedHubRequestID == requestID else {
            return
        }
        dismissingHubRequestID = requestID
    }

    @MainActor private func hubDidDisappear(requestID: UUID) {
        if activeHubRequestID == requestID {
            activeHubRequestID = nil
        }
        if presentedHubRequestID == requestID {
            presentedHubRequestID = nil
            presentedHubDeepLinkURL = nil
        }
        if dismissingHubRequestID == requestID {
            dismissingHubRequestID = nil
        }

        Task { @MainActor [weak self] in
            self?.presentPendingHubIfPossible()
        }
    }

    @MainActor private func presentPendingHubIfPossible() {
        guard !Self.isSigningOut, dismissingHubRequestID == nil,
              let pendingHubRequest,
              activeHubRequestID == pendingHubRequest.requestID else {
            return
        }
        self.pendingHubRequest = nil
        presentHub(pendingHubRequest)
    }

    @MainActor private func getHubViewController() -> HubViewController {
        if let hubViewController = bottomSheetController.controller as? HubViewController {
            return hubViewController
        }

        return HubViewController()
    }

    internal func getRootViewController() -> UIViewController? {
        return UIApplication.shared.connectedScenes
            .filter({ $0.activationState == .foregroundActive })
            .compactMap({ $0 as? UIWindowScene })
            .first?.windows
            .filter({ $0.isKeyWindow }).first?.rootViewController
    }

    @MainActor private func displayViewControllerOnTop(_ viewController: UIViewController) {
        let rootViewController = getRootViewController()

        // Don't try to present again if it's already presented
        guard bottomSheetController.presentingViewController == nil else {
            return
        }

        // TODO: Eventually, replace this with native iOS 15+ sheetPresentationController
        // But, we can't replace it yet (2022) since there are too many devices running iOS 14.
        bottomSheetController.controller = viewController
        bottomSheetController.modalPresentationStyle = .overFullScreen

        rootViewController?.present(self.bottomSheetController, animated: true, completion: nil)
    }

    @MainActor internal static func isDisplayingHub() -> Bool {
        return inst.bottomSheetController.controller != nil
            && inst.bottomSheetController.presentingViewController != nil
    }

    @MainActor private static func isEmailVerificationHubRequestActiveOrPending() -> Bool {
        let isVerificationURL: (URL?) -> Bool = { $0?.path == "/account/verify-email" }
        return isVerificationURL(config.pendingHubDeepLinkUrl)
            || isVerificationURL(inst.presentedHubDeepLinkURL)
            || isVerificationURL(inst.pendingHubRequest?.deepLinkURL)
    }

    @MainActor internal static func dismissHub(requestID: UUID) async {
        guard inst.activeHubRequestID == requestID,
              let hubViewController = inst.bottomSheetController.controller as? HubViewController,
              inst.bottomSheetController.presentingViewController != nil else {
            return
        }

        inst.hubDismissalStarted(requestID: requestID)

        await withCheckedContinuation { continuation in
            hubViewController.hide {
                continuation.resume()
            }
        }
    }

}

public class UserPropAccess {
    private var store: Store<RowndState> {
        return Context.currentContext.store
    }
    public func get() -> UserState {
        return store.state.user.get()
    }

    public func get(field: String) -> Any {
        return store.state.user.get(field: field)
    }

    public func get<T>(field: String) -> T? {
        let value: T? = store.state.user.get(field: field)
        return value
    }

    public func set(data: [String: AnyCodable]) {
        store.state.user.set(data: data)
    }

    public func set(field: String, value: AnyCodable) {
        store.state.user.set(field: field, value: value)
    }

    public func isEncryptionPossible() throws {
        throw RowndError(
            "Encryption is currently not enabled with this SDK. If you like to enable it, please reach out to support@rownd.io"
        )
    }

    public func encrypt(plaintext: String) throws {
        throw RowndError(
            "Encryption is currently not enabled with this SDK. If you like to enable it, please reach out to support@rownd.io"
        )
    }

    public func decrypt(ciphertext: String) throws {
        throw RowndError(
            "Encryption is currently not enabled with this SDK. If you like to enable it, please reach out to support@rownd.io"
        )
    }
}

public enum RowndStateType {
    case auth, user, app, none
}

public enum UserFieldAccessType {
    case string, int, float, dictionary, array
}

public enum RowndSignInHint {
    case appleId, googleId, email, phone,
        guest, anonymous  // these two do the same thing
}

public struct RowndSignInOptions: Encodable {
    public init(
        postSignInRedirect: String? = Rownd.config.postSignInRedirect,
        intent: RowndSignInIntent? = nil, hint: String? = nil
    ) {
        self.postSignInRedirect = postSignInRedirect
        self.intent = intent
        self.hint = hint
    }

    public var postSignInRedirect: String? = Rownd.config.postSignInRedirect
    public var intent: RowndSignInIntent?
    public var hint: String?
    internal var signInType: SignInType?

    public var title: String?
    public var subtitle: String?

    enum CodingKeys: String, CodingKey {
        case intent
        case hint
        case postSignInRedirect = "post_login_redirect"
        case signInType = "sign_in_type"
        case title, subtitle
    }
}

public enum RowndSignInIntent: String, Codable {
    case signIn = "sign_in"
    case signUp = "sign_up"
}

public enum SignInType: String, Codable {
    case email = "email"
    case phone = "phone"
    case apple = "apple"
    case google = "google"
    case anonymous = "anonymous"
}

internal enum RowndSignInLoginStep: String, Codable {
    case initialize = "init"
    case noAccount = "no_account"
    case success = "success"
    case completing = "completing"
    case error = "error"
}

internal struct RowndSignInJsOptions: Encodable {
    public var token: String?
    public var loginStep: RowndSignInLoginStep?
    public var intent: RowndSignInIntent?
    public var userType: UserType?
    public var appVariantUserType: UserType?
    public var signInType: SignInType?
    public var challengeId: String?
    public var userIdentifier: String?

    enum CodingKeys: String, CodingKey {
        case token, intent
        case loginStep = "login_step"
        case userType = "user_type"
        case appVariantUserType = "app_variant_user_type"
        case signInType = "sign_in_type"
        case challengeId = "request_id"
        case userIdentifier = "identifier"
    }
}

public enum Status: String, Codable {
    case loading
    case success
    case failed
}

struct RowndError: Error, CustomStringConvertible {
    var message: String

    init(_ message: String) {
        self.message = message
    }

    public var description: String {
        return message
    }
}

public enum RowndSignoutScope: String, Codable {
    case all
}
