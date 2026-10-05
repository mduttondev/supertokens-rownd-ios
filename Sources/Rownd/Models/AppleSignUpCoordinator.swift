//
//  AppleSignUpCoordinator.swift
//  appleSignIn
//
//  Created by Michael Murray on 7/17/22.
//

import SwiftUI
import AuthenticationServices
import UIKit
import AnyCodable
import ReSwiftThunk
import Combine

struct AppleSignInData: Codable {
    var email: String
    var firstName: String?
    var lastName: String?
    var fullName: String?

    enum CodingKeys: String, CodingKey {
        case firstName = "first_name"
        case lastName = "last_name"
        case email = "email"
        case fullName = "full_name"
    }

    func toDictionary() -> Dictionary<String, AnyCodable> {
        var dictionary: Dictionary<String, AnyCodable> = [
            "email": AnyCodable(email)
        ]
        if let firstName = firstName {
            dictionary["first_name"] = AnyCodable(firstName)
        }
        if let lastName = lastName {
            dictionary["last_name"] = AnyCodable(lastName)
        }
        if let fullName = fullName {
            dictionary["full_name"] = AnyCodable(fullName)
        }
        return dictionary
    }
}

class AppleSignUpCoordinator: NSObject {
    @MainActor private var currentOperationID: UUID?
    @MainActor private var completionTask: Task<Void, Never>?
    @MainActor private var currentHubRequestID: UUID?
    @MainActor private var authorizationOperations: [ObjectIdentifier: UUID] = [:]
    @MainActor private var authOperationPermits: [UUID: SuperTokensSessionBridge.AuthOperationPermit] = [:]
    var parent: Rownd?
    var intent: RowndSignInIntent?
    var cancellables = Set<AnyCancellable>()
    var signInWithApple: (String, String) async throws -> SuperTokensAppleSignInResponse
    var captureAuthOperationPermit: () -> SuperTokensSessionBridge.AuthOperationPermit = {
        SuperTokensSessionBridge.captureAuthOperationPermit()
    }
    var invalidateAuthOperationPermits: () -> Void = {
        SuperTokensSessionBridge.invalidateAuthOperationPermits()
    }
    var isAuthOperationPermitCurrent: (SuperTokensSessionBridge.AuthOperationPermit) -> Bool = {
        $0 == SuperTokensSessionBridge.captureAuthOperationPermit()
    }
    var adoptResponseSession: (
        SuperTokensSessionTokens,
        SuperTokensSessionBridge.AuthOperationPermit
    ) async -> SuperTokensSessionBridge.SessionIdentity? = {
        await SuperTokensSessionBridge.adoptResponseSession($0, permit: $1)
    }
    var discardSessionIfCurrent: (SuperTokensSessionBridge.SessionIdentity) async -> Bool = {
        await SuperTokensSessionBridge.discardSessionIfCurrent($0)
    }
    var isCurrentSession: (SuperTokensSessionBridge.SessionIdentity) async -> Bool = {
        await SuperTokensSessionBridge.isCurrentSession($0)
    }
    var saveExpectedSession: (
        [String: AnyCodable],
        [String: AnyCodable],
        SuperTokensSessionBridge.SessionIdentity,
        UserProfileFetchCoordinator.Ticket
    ) async -> Bool = { data, expectedData, sessionIdentity, ticket in
        await UserData.saveExpectedSession(
            data,
            expectedData: expectedData,
            expectedSessionIdentity: sessionIdentity,
            ticket: ticket
        )
    }
    var signOutIfCurrentSession: (
        SuperTokensSessionBridge.SessionIdentity,
        String,
        () -> Bool
    ) async -> Bool = { identity, accessToken, condition in
        await SuperTokensSessionBridge.signOutIfCurrentSession(
            identity,
            expectedRowndAccessToken: accessToken,
            condition: condition
        )
    }
    var fetchAppConfig: () async -> AppConfigResponse? = {
        await AppConfig.fetch()
    }
    var syncAuthState: (
        SuperTokensSessionBridge.SessionIdentity,
        @MainActor () -> Bool
    ) async -> Bool = { sessionIdentity, commitIf in
        await SuperTokensSessionBridge.syncRowndAuthStateFromSuperTokens(
            afterTokenRead: {},
            commitIf: commitIf,
            expectedSessionIdentity: sessionIdentity
        )
    }
    var waitBeforeCompletion: () async -> Void = {
        try? await Task.sleep(nanoseconds: UInt64(2 * Double(NSEC_PER_SEC)))
    }
    var beforeHubPresentation: () async -> Void = {}
    var beforeFinalization: () async -> Void = {}
    var dismissHub: (UUID) async -> Void = { requestID in
        await Rownd.dismissHub(requestID: requestID)
    }
    var emitEvent: @MainActor (RowndEvent) -> Void = { event in
        RowndEventEmitter.emit(event)
    }
    @MainActor private lazy var authorizationDelegate = AppleAuthorizationDelegate(coordinator: self)

    init(_ parent: Rownd, signInClient: SuperTokensThirdPartySignInClient = SuperTokensThirdPartySignInClient()) {
        self.parent = parent
        self.signInWithApple = { authorizationCode, clientType in
            try await signInClient.signInWithApple(
                authorizationCode: authorizationCode,
                clientType: clientType
            )
        }
        super.init()
    }

    func signIn(_ intent: RowndSignInIntent?, emitsSignInStarted: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.signInOnMainActor(intent, emitsSignInStarted: emitsSignInStarted)
        }
    }

    @MainActor private func signInOnMainActor(_ intent: RowndSignInIntent?, emitsSignInStarted: Bool) {
        self.intent = intent
        // Create an object of the ASAuthorizationAppleIDProvider
        let appleIDProvider = ASAuthorizationAppleIDProvider()
        // Create a request
        let request = appleIDProvider.createRequest()
        // Define the scope of the request
        request.requestedScopes = [.fullName, .email]
        // Make the request
        let authorizationController = ASAuthorizationController(authorizationRequests: [request])

        // Assigning the delegates
        authorizationController.presentationContextProvider = authorizationDelegate
        authorizationController.delegate = authorizationDelegate
        registerAuthorizationOperation(
            controllerID: ObjectIdentifier(authorizationController),
            emitsSignInStarted: emitsSignInStarted
        )
        authorizationController.performRequests()
    }

    @MainActor fileprivate func completeAuthorization(
        controllerID: ObjectIdentifier,
        authorization: ASAuthorization
    ) {
        guard let operationID = consumeAuthorizationOperation(controllerID: controllerID) else { return }

        switch authorization.credential {
        case let appleIDCredential as ASAuthorizationAppleIDCredential:
            // Create an account in your system.
            // let userIdentifier = appleIDCredential.user
            let fullName = appleIDCredential.fullName
            let email = appleIDCredential.email
            let authorizationCode = appleIDCredential.authorizationCode

            if let authorizationCode = authorizationCode,
               let authCode = String(data: authorizationCode, encoding: .utf8) {

                let intent = self.intent
                let task = Task {
                    let hubRequestID = UUID()
                    guard await self.presentHubForNativeCompletion(
                        operationID: operationID,
                        hubRequestID: hubRequestID
                    ) else { return }
                    await self.completeSignIn(
                        authorizationCode: authCode,
                        fullName: fullName,
                        email: email,
                        intent: intent,
                        hubRequestID: hubRequestID,
                        operationID: operationID
                    )
                }
                setCompletionTask(task, for: operationID)
            } else {
                logger.error("Apple sign-in response did not include an authorization code")
                Rownd.requestSignIn(jsFnOptions: RowndSignInJsOptions(
                    loginStep: .error,
                    signInType: .apple
                ))
            }

        default:
            logger.error("Apple sign-in returned an unsupported credential type")
            Rownd.requestSignIn(jsFnOptions: RowndSignInJsOptions(
                loginStep: .error,
                signInType: .apple
            ))
            break
        }
    }

    func completeSignIn(
        authorizationCode: String,
        fullName: PersonNameComponents?,
        email: String?,
        intent: RowndSignInIntent?,
        hubRequestID: UUID
    ) async {
        let operationID = await beginOperation()
        guard await bindHubRequest(hubRequestID, to: operationID) else { return }
        await completeSignIn(
            authorizationCode: authorizationCode,
            fullName: fullName,
            email: email,
            intent: intent,
            hubRequestID: hubRequestID,
            operationID: operationID
        )
    }

    func presentHubForNativeCompletion(operationID: UUID, hubRequestID: UUID) async -> Bool {
        guard await bindHubRequest(hubRequestID, to: operationID) else { return false }
        await beforeHubPresentation()
        guard await isCurrentOperation(operationID) else { return false }
        return await MainActor.run {
            guard self.isCurrentOperation(operationID),
                  self.isHubRequestBound(hubRequestID, to: operationID) else {
                return false
            }
            Rownd.requestSignInForNativeCompletion(
                jsFnOptions: RowndSignInJsOptions(loginStep: .completing),
                requestID: hubRequestID
            )
            return true
        }
    }

    private func completeSignIn(
        authorizationCode: String,
        fullName: PersonNameComponents?,
        email: String?,
        intent: RowndSignInIntent?,
        hubRequestID: UUID,
        operationID: UUID
    ) async {
        let operationPermit = await MainActor.run { () -> SuperTokensSessionBridge.AuthOperationPermit? in
            guard let permit = self.authOperationPermits[operationID],
                  self.canCommitAuthState(
                    operationID: operationID,
                    hubRequestID: hubRequestID,
                    permit: permit
                  ) else {
                return nil
            }
            return permit
        }
        guard let operationPermit else { return }

        guard let clientType = await resolveAppleClientType() else {
            guard await canCommitAuthState(
                operationID: operationID,
                hubRequestID: hubRequestID,
                permit: operationPermit
            ) else { return }
            logger.error("Apple sign-in requires a non-empty ios_client_type in app config")
            await MainActor.run {
                guard self.canCommitAuthState(
                    operationID: operationID,
                    hubRequestID: hubRequestID,
                    permit: operationPermit
                ) else { return }
                Rownd.updateSignInForNativeCompletion(
                    jsFnOptions: RowndSignInJsOptions(
                        loginStep: .error,
                        signInType: .apple
                    ),
                    requestID: hubRequestID
                )
            }
            return
        }

        let signInResponse: SuperTokensAppleSignInResponse
        do {
            signInResponse = try await signInWithApple(authorizationCode, clientType)
        } catch {
            logger.error("Apple sign-in failed during SuperTokens signinup. Error: \(String(describing: error))")
            guard await canCommitAuthState(
                operationID: operationID,
                hubRequestID: hubRequestID,
                permit: operationPermit
            ) else { return }
            await MainActor.run {
                guard self.canCommitAuthState(
                    operationID: operationID,
                    hubRequestID: hubRequestID,
                    permit: operationPermit
                ) else { return }
                Rownd.updateSignInForNativeCompletion(
                    jsFnOptions: RowndSignInJsOptions(
                        loginStep: .error,
                        signInType: .apple
                    ),
                    requestID: hubRequestID
                )
                self.emitEvent(.signInFailed(method: .apple, error: error))
            }
            return
        }

        let didPresentSuccess = await MainActor.run {
            guard self.canCommitAuthState(
                    operationID: operationID,
                    hubRequestID: hubRequestID,
                    permit: operationPermit
                  ),
                  Rownd.isNativeHubRequestActive(hubRequestID) else {
                return false
            }
            Rownd.updateSignInForNativeCompletion(
                jsFnOptions: RowndSignInJsOptions(
                    loginStep: RowndSignInLoginStep.success,
                    intent: intent,
                    userType: signInResponse.userType,
                    appVariantUserType: signInResponse.userType
                ),
                requestID: hubRequestID
            )
            return true
        }
        if didPresentSuccess {
            // Prevent fast auth handshakes from feeling jarring to the user
            await waitBeforeCompletion()
            let shouldDismissHub = await MainActor.run {
                self.canCommitAuthState(
                    operationID: operationID,
                    hubRequestID: hubRequestID,
                    permit: operationPermit
                )
                    && Rownd.isNativeHubRequestActive(hubRequestID)
            }
            if shouldDismissHub {
                await dismissHub(hubRequestID)
                await clearHubRequest(hubRequestID, for: operationID)
            }
        }

        guard await canCommitAuthState(
            operationID: operationID,
            hubRequestID: hubRequestID,
            permit: operationPermit
        ) else { return }
        guard let sessionIdentity = await adoptResponseSession(
            signInResponse.sessionTokens,
            operationPermit
        ) else {
            guard await canCommitAuthState(
                operationID: operationID,
                hubRequestID: hubRequestID,
                permit: operationPermit
            ) else { return }
            await presentSyncFailure(
                replacing: hubRequestID,
                operationID: operationID,
                permit: operationPermit
            )
            return
        }
        guard await canCommitAuthState(
            operationID: operationID,
            hubRequestID: hubRequestID,
            permit: operationPermit
        ) else {
            _ = await discardSessionIfCurrent(sessionIdentity)
            return
        }
        let commitAuthState: @MainActor () -> Bool = {
            self.canCommitAuthState(
                operationID: operationID,
                hubRequestID: hubRequestID,
                permit: operationPermit
            )
        }
        guard await syncAuthState(sessionIdentity, commitAuthState) else {
            _ = await discardSessionIfCurrent(sessionIdentity)
            guard await canCommitAuthState(
                operationID: operationID,
                hubRequestID: hubRequestID,
                permit: operationPermit
            ) else { return }
            await presentSyncFailure(
                replacing: hubRequestID,
                operationID: operationID,
                permit: operationPermit
            )
            return
        }

        await beforeFinalization()
        guard await isCurrentSession(sessionIdentity) else { return }
        let completionEvent = RowndEvent(
            event: .signInCompleted,
            data: [
                "method": AnyCodable(SignInType.apple.rawValue),
                "user_type": AnyCodable(signInResponse.userType.rawValue),
                "app_variant_user_type": AnyCodable(signInResponse.userType.rawValue)
            ]
        )
        await MainActor.run {
            guard self.canCommitAuthState(
                operationID: operationID,
                hubRequestID: hubRequestID,
                permit: operationPermit
            ) else { return }
            Context.currentContext.store.dispatch(SetLastSignInMethod(payload: SignInMethodTypes.apple))
            guard self.canCommitAuthState(
                operationID: operationID,
                hubRequestID: hubRequestID,
                permit: operationPermit
            ) else { return }
            self.updateUserDataWithAppleData(
                fullName: fullName,
                email: email,
                sessionIdentity: sessionIdentity
            )
            guard self.canCommitAuthState(
                operationID: operationID,
                hubRequestID: hubRequestID,
                permit: operationPermit
            ) else { return }
            self.emitEvent(completionEvent)
        }
    }

    @MainActor private func canCommitAuthState(
        operationID: UUID,
        hubRequestID: UUID,
        permit: SuperTokensSessionBridge.AuthOperationPermit? = nil
    ) -> Bool {
        guard isCurrentOperation(operationID),
              Rownd.canCommitAuthState(forNativeHubRequest: hubRequestID) else {
            return false
        }
        guard let permit else { return true }
        return authOperationPermits[operationID] == permit
            && isAuthOperationPermitCurrent(permit)
    }

    private func presentSyncFailure(
        replacing completedRequestID: UUID,
        operationID: UUID,
        permit: SuperTokensSessionBridge.AuthOperationPermit
    ) async {
        let fallbackRequestID = UUID()
        guard await canCommitAuthState(
            operationID: operationID,
            hubRequestID: completedRequestID,
            permit: permit
        ) else { return }
        guard await bindHubRequest(fallbackRequestID, to: operationID) else { return }

        let didPresent = await MainActor.run {
            guard self.isCurrentOperation(operationID),
                  self.isHubRequestBound(fallbackRequestID, to: operationID),
                  self.authOperationPermits[operationID] == permit,
                  self.isAuthOperationPermitCurrent(permit) else {
                return false
            }
            return Rownd.requestSignInForNativeCompletionFallback(
                jsFnOptions: RowndSignInJsOptions(
                    loginStep: .error,
                    signInType: .apple
                ),
                replacing: completedRequestID,
                requestID: fallbackRequestID
            )
        }
        if !didPresent {
            await clearHubRequest(fallbackRequestID, for: operationID)
        }
    }

    @MainActor private func beginOperation() -> UUID {
        completionTask?.cancel()
        invalidateAuthOperationPermits()
        let previousHubRequestID = currentHubRequestID
        let operationID = UUID()
        currentOperationID = operationID
        completionTask = nil
        currentHubRequestID = nil
        authorizationOperations.removeAll()
        authOperationPermits.removeAll()
        authOperationPermits[operationID] = captureAuthOperationPermit()
        retireHubRequest(previousHubRequestID)
        return operationID
    }

    @discardableResult
    @MainActor func registerAuthorizationOperation(
        controllerID: ObjectIdentifier,
        emitsSignInStarted: Bool = false
    ) -> UUID {
        completionTask?.cancel()
        invalidateAuthOperationPermits()
        let previousHubRequestID = currentHubRequestID
        let operationID = UUID()
        currentOperationID = operationID
        completionTask = nil
        currentHubRequestID = nil
        authorizationOperations.removeAll()
        authOperationPermits.removeAll()
        authorizationOperations[controllerID] = operationID
        authOperationPermits[operationID] = captureAuthOperationPermit()
        retireHubRequest(previousHubRequestID)
        if emitsSignInStarted {
            emitEvent(.signInStarted(method: .apple))
        }
        return operationID
    }

    @MainActor func cancelCurrentOperation() {
        completionTask?.cancel()
        invalidateAuthOperationPermits()
        let previousHubRequestID = currentHubRequestID
        completionTask = nil
        currentOperationID = nil
        currentHubRequestID = nil
        authorizationOperations.removeAll()
        authOperationPermits.removeAll()
        retireHubRequest(previousHubRequestID)
    }

    @MainActor func consumeAuthorizationOperation(controllerID: ObjectIdentifier) -> UUID? {
        guard let operationID = authorizationOperations.removeValue(forKey: controllerID),
              currentOperationID == operationID else {
            return nil
        }
        return operationID
    }

    @MainActor private func bindHubRequest(_ hubRequestID: UUID, to operationID: UUID) -> Bool {
        guard currentOperationID == operationID else { return false }
        currentHubRequestID = hubRequestID
        return true
    }

    @MainActor private func isHubRequestBound(_ hubRequestID: UUID, to operationID: UUID) -> Bool {
        return currentOperationID == operationID && currentHubRequestID == hubRequestID
    }

    @MainActor private func clearHubRequest(_ hubRequestID: UUID, for operationID: UUID) {
        guard currentOperationID == operationID,
              currentHubRequestID == hubRequestID else { return }
        currentHubRequestID = nil
    }

    private func retireHubRequest(_ hubRequestID: UUID?) {
        guard let hubRequestID else { return }
        Task { await dismissHub(hubRequestID) }
    }

    @MainActor private func setCompletionTask(_ task: Task<Void, Never>, for operationID: UUID) {
        guard currentOperationID == operationID else {
            task.cancel()
            return
        }
        completionTask = task
    }

    @MainActor private func isCurrentOperation(_ operationID: UUID) -> Bool {
        let isCancelled = withUnsafeCurrentTask { $0?.isCancelled == true }
        return currentOperationID == operationID && !isCancelled
    }

    private func resolveAppleClientType() async -> String? {
        let appConfigBeforeFetch = await MainActor.run {
            Context.currentContext.store.state.appConfig
        }
        if let clientType = Self.configuredAppleClientType(in: appConfigBeforeFetch) {
            return clientType
        }

        guard let fetchedAppConfig = await fetchAppConfig() else {
            return nil
        }

        return await MainActor.run {
            let store = Context.currentContext.store
            let currentAppConfig = store.state.appConfig
            guard Self.appConfigStatesEqualIgnoringLoading(
                currentAppConfig,
                appConfigBeforeFetch
            ) else {
                return Self.configuredAppleClientType(in: currentAppConfig)
            }

            guard let clientType = Self.configuredAppleClientType(in: fetchedAppConfig.app) else {
                return nil
            }
            store.dispatch(SetAppConfig(payload: fetchedAppConfig.app))
            return clientType
        }
    }

    private static func appConfigStatesEqualIgnoringLoading(
        _ lhs: AppConfigState,
        _ rhs: AppConfigState
    ) -> Bool {
        var lhs = lhs
        var rhs = rhs
        lhs.isLoading = false
        rhs.isLoading = false
        return lhs == rhs
    }

    private static func configuredAppleClientType(in appConfig: AppConfigState) -> String? {
        guard let clientType = appConfig.config?.hub?.auth?.signInMethods?.apple?.iosClientType?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !clientType.isEmpty else {
            return nil
        }
        return clientType
    }

    @MainActor func updateUserDataWithAppleData(
        fullName: PersonNameComponents?,
        email: String?,
        sessionIdentity: SuperTokensSessionBridge.SessionIdentity
    ) {
        Context.currentContext.store.dispatch(Thunk<RowndState> { _, getState in
            guard let state = getState() else { return }
            Task {
                _ = await self.enrichUserDataWithAppleData(
                    fullName: fullName,
                    email: email,
                    state: state,
                    sessionIdentity: sessionIdentity
                )
            }
        })
    }

    @discardableResult
    internal func enrichUserDataWithAppleData(
        fullName: PersonNameComponents?,
        email: String?,
        state: RowndState,
        sessionIdentity: SuperTokensSessionBridge.SessionIdentity,
        fetchUserData: @escaping (RowndState) async throws -> UserData.FetchResult = UserData.fetchUserData,
        persistState: @escaping @MainActor (RowndState) -> Bool = { $0.saveImmediately() },
        scheduleProfileHydrationRetry: @escaping (
            SuperTokensSessionBridge.StableSessionIdentity
        ) async -> Void = { identity in
            await UserData.scheduleProfileHydrationRetry(for: identity)
        }
    ) async -> Bool {
        guard let accessToken = state.auth.accessToken,
              SuperTokensSessionBridge.tokensBelongToSameSession(
                accessToken,
                sessionIdentity.accessToken
              ),
              let ticket = UserData.fetchCoordinator.begin(
                accessToken: sessionIdentity.accessToken,
                purpose: .enrichment
              ) else {
            return false
        }

        await MainActor.run {
            Context.currentContext.store.dispatch(SetUserFetchLoading(
                operationId: ticket.id,
                isLoading: true
            ))
        }
        let didEnrich = await performAppleUserDataEnrichment(
            fullName: fullName,
            email: email,
            state: state,
            sessionIdentity: sessionIdentity,
            ticket: ticket,
            fetchUserData: fetchUserData,
            persistState: persistState,
            scheduleProfileHydrationRetry: scheduleProfileHydrationRetry
        )
        UserData.fetchCoordinator.finish(ticket)
        await MainActor.run {
            Context.currentContext.store.dispatch(SetUserFetchLoading(
                operationId: ticket.id,
                isLoading: false
            ))
        }
        return didEnrich
    }

    private func performAppleUserDataEnrichment(
        fullName: PersonNameComponents?,
        email: String?,
        state: RowndState,
        sessionIdentity: SuperTokensSessionBridge.SessionIdentity,
        ticket: UserProfileFetchCoordinator.Ticket,
        fetchUserData: @escaping (RowndState) async throws -> UserData.FetchResult,
        persistState: @escaping @MainActor (RowndState) -> Bool,
        scheduleProfileHydrationRetry: @escaping (
            SuperTokensSessionBridge.StableSessionIdentity
        ) async -> Void
    ) async -> Bool {
        do {
            var fetchState = state
            fetchState.auth.accessToken = sessionIdentity.accessToken
            switch try await fetchUserData(fetchState) {
            case .profile(let userResponse):
                guard await isCurrentSession(sessionIdentity),
                      UserData.fetchCoordinator.isCurrent(ticket),
                      await MainActor.run(body: {
                        UserData.fetchCoordinator.isCurrent(ticket)
                            && SuperTokensSessionBridge.tokensBelongToSameSession(
                                Context.currentContext.store.state.auth.accessToken,
                                sessionIdentity.accessToken
                            )
                      }) else {
                    return false
                }

                let appleUserData = Self.appleUserData(fullName: fullName, email: email)

                if !appleUserData.isEmpty {
                    guard await saveExpectedSession(
                        appleUserData,
                        state.user.data,
                        sessionIdentity,
                        ticket
                    ) else {
                        return false
                    }
                }
                guard await isCurrentSession(sessionIdentity),
                      UserData.fetchCoordinator.isCurrent(ticket) else {
                    return false
                }

                return await commitAppleProfileHydration(
                    userResponse: userResponse,
                    usesUpdatedUserData: !appleUserData.isEmpty,
                    sessionIdentity: sessionIdentity,
                    ticket: ticket,
                    persistState: persistState
                )
            case .notFound:
                guard await isCurrentSession(sessionIdentity),
                      UserData.fetchCoordinator.isCurrent(ticket) else {
                    return false
                }
                let retainsPendingHydration = await MainActor.run {
                    let auth = Context.currentContext.store.state.auth
                    return UserData.fetchCoordinator.isCurrent(ticket)
                        && auth.profileHydrationPendingSessionIdentity == sessionIdentity.stable
                        && SuperTokensSessionBridge.tokensBelongToSameSession(
                            auth.accessToken,
                            sessionIdentity.accessToken
                        )
                }
                if retainsPendingHydration {
                    await scheduleProfileHydrationRetry(sessionIdentity.stable)
                    return false
                }

                let didSignOut = await signOutIfCurrentSession(
                    sessionIdentity,
                    sessionIdentity.accessToken,
                    { UserData.fetchCoordinator.isCurrent(ticket) }
                )
                if didSignOut {
                    logger.warning("The Apple sign-in profile was not found, so the current session was signed out.")
                }
                return false
            }
        } catch {
            logger.error("Apple profile enrichment failed")
            return false
        }
    }

    @MainActor private func commitAppleProfileHydration(
        userResponse: UserStateResponse,
        usesUpdatedUserData: Bool,
        sessionIdentity: SuperTokensSessionBridge.SessionIdentity,
        ticket: UserProfileFetchCoordinator.Ticket,
        persistState: @escaping @MainActor (RowndState) -> Bool
    ) -> Bool {
        let store = Context.currentContext.store
        guard let state = store.state,
              UserData.fetchCoordinator.isCurrent(ticket),
              SuperTokensSessionBridge.tokensBelongToSameSession(
                state.auth.accessToken,
                sessionIdentity.accessToken
              ) else {
            return false
        }

        var auth = state.auth
        let clearsPendingHydration =
            auth.profileHydrationPendingSessionIdentity == sessionIdentity.stable
        if clearsPendingHydration {
            auth.profileHydrationPendingSessionIdentity = nil
        }

        var user = userResponse.toUserState()
        if usesUpdatedUserData {
            user.data = state.user.data
        }
        var candidate = state
        candidate.auth = auth
        candidate.user = user
        guard persistState(candidate) else { return false }

        if clearsPendingHydration {
            store.dispatch(SetAuthState(payload: auth))
        }
        store.dispatch(SetUserState(payload: user))
        return true
    }

    static func appleUserData(
        fullName: PersonNameComponents?,
        email: String?
    ) -> [String: AnyCodable] {
        guard let email else { return [:] }
        let name = [fullName?.givenName, fullName?.familyName]
            .compactMap { $0 }
            .joined(separator: " ")
        return AppleSignInData(
            email: email,
            firstName: fullName?.givenName,
            lastName: fullName?.familyName,
            fullName: name.isEmpty ? nil : name
        ).toDictionary()
    }

    @MainActor fileprivate func completeAuthorization(
        controllerID: ObjectIdentifier,
        error: Error
    ) {
        guard consumeAuthorizationOperation(controllerID: controllerID) != nil else { return }

        // If there is any error will get it here
        logger.error("Apple sign-in authorization failed")
        
        func defaultSignInFlow() {
            logger.error("Falling back to default sign flow")
            Rownd.requestSignIn(RowndSignInOptions(intent: intent))
        }

        guard let authorizationError = error as? ASAuthorizationError else {
            defaultSignInFlow()
            return
        }

        switch authorizationError.code {
        case .canceled:
            return
        default:
            defaultSignInFlow()
        }
    }
}

private final class AppleAuthorizationDelegate: NSObject,
                                                ASAuthorizationControllerDelegate,
                                                ASAuthorizationControllerPresentationContextProviding {
    private weak var coordinator: AppleSignUpCoordinator?

    init(coordinator: AppleSignUpCoordinator) {
        self.coordinator = coordinator
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        let viewController = UIApplication.shared.windows.last?.rootViewController
        return (viewController?.view.window!)!
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        let controllerID = ObjectIdentifier(controller)
        DispatchQueue.main.async { [weak coordinator] in
            coordinator?.completeAuthorization(
                controllerID: controllerID,
                authorization: authorization
            )
        }
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        let controllerID = ObjectIdentifier(controller)
        DispatchQueue.main.async { [weak coordinator] in
            coordinator?.completeAuthorization(controllerID: controllerID, error: error)
        }
    }
}
