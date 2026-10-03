import XCTest
import SuperTokensIOS
import UIKit
import ReSwift

@testable import Rownd

final class RowndExampleTests: XCTestCase {
    private let backendURL = URL(string: ProcessInfo.processInfo.environment["TEST_BACKEND_URL"] ?? "http://127.0.0.1:3100")!
    private let harnessSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = []
        return URLSession(configuration: configuration)
    }()

    func testSuperTokensConfigDefaultsToAuthBasePath() {
        let config = RowndSuperTokensConfig(
            appName: "Example App",
            apiDomain: "https://api.example.com"
        )

        XCTAssertEqual(config.appName, "Example App")
        XCTAssertEqual(config.apiDomain, "https://api.example.com")
        XCTAssertEqual(config.apiBasePath, "/auth")
    }

    func testExampleAppCanUseHarnessBackedSuperTokensSession() async throws {
        _ = try await request("POST", path: "/reset")
        let config = try await harnessConfig()

        Rownd.config.baseUrl = config.hubBaseUrl
        Rownd.config.enableSmartLinkPasteBehavior = false
        _ = await Rownd.configure(
            appKey: config.appKey,
            supertokens: RowndSuperTokensConfig(
                appName: "Rownd iOS Example E2E",
                apiDomain: config.supertokens.appInfo.apiDomain,
                apiBasePath: config.supertokens.appInfo.apiBasePath
            )
        )

        let accessToken = try await createSession(userId: "ios-example-e2e-user")
        XCTAssertFalse(accessToken.isEmpty)

        try await updateProfile(accessToken: accessToken)
        try await signOut(accessToken: accessToken)
        await Rownd.signOut()

        let didSignOut = await waitForCounter("signOut", toEqual: 1, timeout: 10)
        XCTAssertTrue(didSignOut)

        let counters = try await json("GET", path: "/counters") as? [String: Any]
        XCTAssertGreaterThanOrEqual(counters?["createSession"] as? Int ?? 0, 1)
        XCTAssertGreaterThanOrEqual(counters?["userUpdate"] as? Int ?? 0, 1)
        XCTAssertEqual(counters?["legacyRefresh"] as? Int, 0)
    }

    func testPostAppleCompletionDismissesRealBottomSheetBeforeRestoringOnboardingTouches() async throws {
        try await assertAppleCompletionIntentAuthPublicationOrdering(
            createdNewRecipeUser: true,
            intent: .signUp,
            expectedUserType: .NewUser
        )
    }

    func testAppleCompletionSignUpIntentExistingUserPublishesAuthAfterHubDismissal() async throws {
        try await assertAppleCompletionIntentAuthPublicationOrdering(
            createdNewRecipeUser: false,
            intent: .signUp,
            expectedUserType: .ExistingUser
        )
    }

    func testAppleCompletionSignInIntentPublishesAuthAfterHubDismissal() async throws {
        try await assertAppleCompletionIntentAuthPublicationOrdering(
            createdNewRecipeUser: false,
            intent: .signIn,
            expectedUserType: .ExistingUser
        )
    }

    private func assertAppleCompletionIntentAuthPublicationOrdering(
        createdNewRecipeUser: Bool,
        intent: RowndSignInIntent,
        expectedUserType: UserType
    ) async throws {
        let fixture = try await acquirePostAppleUIKitFixture()
        let gateReached = PostAppleGate()
        let releaseCompletion = PostAppleGate()
        let recorder = await MainActor.run { PostAppleCompletionRecorder() }
        let authStore = Store<AuthState>(reducer: authReducer, state: AuthState())
        let (store, originalAppConfig, originalDisplayHubHandler) = await MainActor.run {
            let store = Context.currentContext.store
            return (store, store.state.appConfig, Rownd.displayHubHandler)
        }
        let onboardingObserver = await MainActor.run {
            let observer = PostAppleOnboardingObserver {
                recorder.recordAuthPublication(
                    rootHasModal: fixture.rootViewController.presentedViewController != nil,
                    hubIsDisplayed: Rownd.isDisplayingHub(),
                    onboardingButtonWinsHitTest: fixture.onboardingButtonReceivesWindowHitTest()
                )
            }
            authStore.subscribe(observer) {
                $0.select { $0.isAuthenticated }
            }
            return observer
        }

        let cleanup: () async -> Void = {
            await releaseCompletion.open()
            await MainActor.run {
                authStore.unsubscribe(onboardingObserver)
                Rownd.displayHubHandler = originalDisplayHubHandler
                store.dispatch(SetAppConfig(payload: originalAppConfig))
                fixture.tearDown()
            }
        }

        do {
            let coordinator = await MainActor.run { () -> PostAppleCoordinator in
                Rownd.displayHubHandler = nil
                store.dispatch(SetAppConfig(payload: Self.appleAppConfig()))
                let coordinator = PostAppleCoordinator(Rownd.getInstance())
                coordinator.signInWithApple = { authorizationCode, clientType in
                    XCTAssertEqual(authorizationCode, "fake-apple-auth-code")
                    XCTAssertEqual(clientType, "native-apple-client")
                    return SuperTokensAppleSignInResponse(
                        status: "OK",
                        createdNewRecipeUser: createdNewRecipeUser,
                        sessionTokens: SuperTokensSessionTokens(
                            accessToken: "test-apple-access-token",
                            refreshToken: "test-apple-refresh-token",
                            frontToken: "test-apple-front-token",
                            antiCSRF: nil
                        )
                    )
                }
                coordinator.adoptResponseSession = { tokens, _ in
                    SuperTokensSessionBridge.SessionIdentity(
                        accessToken: tokens.accessToken,
                        generation: 1,
                        stable: SuperTokensSessionBridge.StableSessionIdentity(
                            sessionHandle: "test-apple-session",
                            userId: "test-apple-user",
                            tenantId: nil
                        )
                    )
                }
                coordinator.isCurrentSession = { _ in true }
                coordinator.syncAuthState = { _, commitIf in
                    await MainActor.run {
                        guard commitIf() else { return false }
                        authStore.dispatch(SetAuthState(payload: Self.authenticatedTestState()))
                        return true
                    }
                }
                coordinator.waitBeforeCompletion = {
                    await gateReached.open()
                    await releaseCompletion.wait()
                }
                coordinator.emitEvent = { event in
                    recorder.record(
                        event,
                        rootHasModal: fixture.rootViewController.presentedViewController != nil,
                        hubIsDisplayed: Rownd.isDisplayingHub()
                    )
                }
                return coordinator
            }

            try await exercisePostAppleDismissal(
                fixture: fixture,
                coordinator: coordinator,
                gateReached: gateReached,
                releaseCompletion: releaseCompletion,
                recorder: recorder,
                intent: intent,
                captureHubSuccessOptions: true
            )

            let recordedState = await MainActor.run {
                (
                    recorder.authPublicationStates,
                    recorder.hubSuccessOptions,
                    recorder.events.first?.data?["user_type"]??.value as? String
                )
            }
            XCTAssertEqual(recordedState.0.count, 1)
            let authPublicationState = try XCTUnwrap(recordedState.0.first)
            XCTAssertFalse(authPublicationState.rootHasModal)
            XCTAssertFalse(authPublicationState.hubIsDisplayed)
            XCTAssertTrue(authPublicationState.onboardingButtonWinsHitTest)
            XCTAssertEqual(recordedState.1.count, 1)
            XCTAssertEqual(recordedState.1.first?.intent, intent)
            XCTAssertEqual(recordedState.2, expectedUserType.rawValue)
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }

    func testHarnessBackedAppleCompletionCreatesUsableSessionAndDismissesRealHub() async throws {
        let fixture = try await acquirePostAppleUIKitFixture()
        let originalConfig = Rownd.config
        let gateReached = PostAppleGate()
        let releaseCompletion = PostAppleGate()
        let recorder = await MainActor.run { PostAppleCompletionRecorder() }
        let eventHandler = PostAppleEventHandler()
        var didMutateRowndConfiguration = false
        let (store, originalAppConfig, originalDisplayHubHandler, originalListeners) = await MainActor.run {
            let context = Context.currentContext
            return (context.store, context.store.state.appConfig, Rownd.displayHubHandler, context.eventListeners)
        }

        let cleanup: () async -> Void = {
            await releaseCompletion.open()
            if didMutateRowndConfiguration {
                await Rownd.signOut()
            }
            await MainActor.run {
                Rownd.config = originalConfig
                Rownd.displayHubHandler = originalDisplayHubHandler
                Context.currentContext.eventListeners = originalListeners
                store.dispatch(SetAppConfig(payload: originalAppConfig))
                fixture.tearDown()
            }
        }

        do {
            _ = try await request("POST", path: "/reset")
            let config = try await harnessConfig()
            didMutateRowndConfiguration = true
            Rownd.config.baseUrl = config.hubBaseUrl
            Rownd.config.enableSmartLinkPasteBehavior = false
            _ = await Rownd.configure(
                appKey: config.appKey,
                supertokens: RowndSuperTokensConfig(
                    appName: "Rownd iOS Example E2E",
                    apiDomain: config.supertokens.appInfo.apiDomain,
                    apiBasePath: config.supertokens.appInfo.apiBasePath
                )
            )
            await Rownd.signOut()
            await MainActor.run {
                Rownd.displayHubHandler = nil
                Context.currentContext.eventListeners = [eventHandler]
                store.dispatch(SetAppConfig(payload: AppConfigState()))
            }

            let coordinator = await MainActor.run { () -> PostAppleCoordinator in
                let coordinator = PostAppleCoordinator(Rownd.getInstance())
                coordinator.waitBeforeCompletion = {
                    await gateReached.open()
                    await releaseCompletion.wait()
                }
                coordinator.emitEvent = { event in
                    recorder.record(
                        event,
                        rootHasModal: fixture.rootViewController.presentedViewController != nil,
                        hubIsDisplayed: Rownd.isDisplayingHub()
                    )
                    RowndEventEmitter.emit(event)
                }
                return coordinator
            }

            try await exercisePostAppleDismissal(
                fixture: fixture,
                coordinator: coordinator,
                gateReached: gateReached,
                releaseCompletion: releaseCompletion,
                recorder: recorder,
                whileCompletionVisible: {
                    let sessionExists = await SuperTokensSessionBridge.doesSessionExist()
                    let isAuthenticated = await MainActor.run {
                        Context.currentContext.store.state.auth.isAuthenticated
                    }
                    XCTAssertFalse(sessionExists)
                    XCTAssertFalse(isAuthenticated)
                }
            )

            let resolvedClientType = await MainActor.run {
                store.state.appConfig.config?.hub?.auth?.signInMethods?.apple?.iosClientType
            }
            XCTAssertEqual(resolvedClientType, "native-apple-client")
            XCTAssertEqual(eventHandler.signInCompletedCount, 1)
            let sessionExists = await SuperTokensSessionBridge.doesSessionExist()
            let sessionAccessToken = await SuperTokensSessionBridge.getAccessToken()
            XCTAssertTrue(sessionExists)
            XCTAssertFalse(try XCTUnwrap(sessionAccessToken).isEmpty)

            let protected = try await protectedResource()
            XCTAssertEqual(protected["status"] as? String, "OK")
            let counters = try await json("GET", path: "/counters") as? [String: Any]
            XCTAssertEqual(counters?["appleSignIn"] as? Int, 1)
            XCTAssertEqual(counters?["protected"] as? Int, 1)
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }

    private func exercisePostAppleDismissal(
        fixture: PostAppleUIKitFixture,
        coordinator: PostAppleCoordinator,
        gateReached: PostAppleGate,
        releaseCompletion: PostAppleGate,
        recorder: PostAppleCompletionRecorder,
        intent: RowndSignInIntent = .signUp,
        captureHubSuccessOptions: Bool = false,
        whileCompletionVisible: (() async -> Void)? = nil
    ) async throws {
        let requestID = UUID()
        await MainActor.run {
            Rownd.requestSignInForNativeCompletion(
                jsFnOptions: RowndSignInJsOptions(loginStep: .completing),
                requestID: requestID
            )
            fixture.presentIfNeeded(Rownd.getInstance().bottomSheetController)
        }
        let presentedBothLayers = await waitForPostAppleCondition {
            fixture.rootViewController.presentedViewController is BottomSheetViewController
                && Rownd.getInstance().bottomSheetController.presentedViewController != nil
                && Rownd.isDisplayingHub()
                && fixture.presentedModalIsAttached
                && !fixture.onboardingButtonReceivesWindowHitTest()
        }
        XCTAssertTrue(presentedBothLayers)
        if captureHubSuccessOptions {
            await MainActor.run {
                Rownd.displayHubHandler = { _, options in
                    guard let options = options as? RowndSignInJsOptions,
                          options.loginStep == .success else {
                        return
                    }
                    recorder.recordHubSuccess(options)
                }
            }
        }

        let signInTask = Task {
            await coordinator.completeSignIn(
                authorizationCode: "fake-apple-auth-code",
                fullName: nil,
                email: nil,
                intent: intent,
                hubRequestID: requestID
            )
        }
        // This gate includes app config, Apple sign-in HTTP, and the Hub update, not just UIKit presentation.
        let completionTimeoutNanoseconds: UInt64 = 15_000_000_000
        let didReachCompletionDelay = await gateReached.waitUntilOpen(timeoutNanoseconds: completionTimeoutNanoseconds)
        let completionIsBlocked = await MainActor.run { recorder.events.isEmpty && Rownd.isDisplayingHub() }
        XCTAssertTrue(
            didReachCompletionDelay,
            "Apple sign-in did not reach the completion-delay gate within \(completionTimeoutNanoseconds / 1_000_000_000)s; check app config, Apple sign-in HTTP, and Hub update logs."
        )
        XCTAssertTrue(completionIsBlocked)
        await whileCompletionVisible?()
        await releaseCompletion.open()

        await signInTask.value
        let fullyDismissed = await waitForPostAppleCondition {
            fixture.rootViewController.presentedViewController == nil && !Rownd.isDisplayingHub()
        }
        XCTAssertTrue(fullyDismissed)

        await MainActor.run {
            XCTAssertEqual(recorder.events.map(\.event), [.signInCompleted])
            XCTAssertEqual(recorder.presentationStates.count, 1)
            XCTAssertEqual(recorder.presentationStates.first?.0, false)
            XCTAssertEqual(recorder.presentationStates.first?.1, false)
            XCTAssertTrue(fixture.onboardingButtonReceivesWindowHitTest())
            fixture.activateOnboardingButton()
            XCTAssertEqual(fixture.tapCount, 1)
        }
    }

    private func acquirePostAppleUIKitFixture(
        timeoutNanoseconds: UInt64 = 5_000_000_000
    ) async throws -> PostAppleUIKitFixture {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            do {
                let fixture = try await MainActor.run(body: { try PostAppleUIKitFixture() })
                await nextPostAppleMainRunLoop()
                if await MainActor.run(body: { fixture.rootIsAttached }) {
                    return fixture
                }
                await MainActor.run { fixture.tearDown() }
            } catch E2ETestError.missingForegroundWindowScene {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        throw E2ETestError.missingForegroundWindowScene
    }

    private func nextPostAppleMainRunLoop() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    private func protectedResource() async throws -> [String: Any] {
        let url = backendURL.appendingPathComponent("test/protected")
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw E2ETestError.unexpectedResponse
        }
        return body
    }

    private static func appleAppConfig() -> AppConfigState {
        AppConfigState(config: AppConfigConfig(
            hub: AppHubConfigState(auth: AppHubAuthConfigState(
                signInMethods: SignInMethods(
                    apple: AppleSignInMethodConfig(iosClientType: "native-apple-client")
                )
            ))
        ))
    }

    private static func authenticatedTestState() -> AuthState {
        AuthState(
            accessToken: "eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0.eyJzdWIiOiJwb3N0LWFwcGxlLXRlc3QtdXNlciIsImV4cCI6NDEwMjQ0NDgwMH0.",
            refreshToken: "post-apple-test-refresh-token",
            isVerifiedUser: true,
            userId: "post-apple-test-user"
        )
    }

    private func harnessConfig() async throws -> E2EHarnessConfig {
        let data = try await request("GET", path: "/config")
        return try JSONDecoder().decode(E2EHarnessConfig.self, from: data)
    }

    private func createSession(userId: String) async throws -> String {
        let (_, response) = try await response("POST", path: "/test/session", body: ["userId": userId])
        let accessToken = try requiredHeader("st-access-token", in: response)
        let refreshToken = try requiredHeader("st-refresh-token", in: response)
        let frontToken = try requiredHeader("front-token", in: response)
        let antiCSRF = header("anti-csrf", in: response)

        await Task.detached {
            _ = SuperTokensSessionBridge.bootstrapSession(
                accessToken: accessToken,
                refreshToken: refreshToken,
                frontToken: frontToken,
                antiCSRF: antiCSRF
            )
        }.value

        return accessToken
    }

    private func updateProfile(accessToken: String) async throws {
        _ = try await response("PUT", path: "/auth/plugin/rownd/user", body: [
            "data": [
                "first_name": "E2E"
            ]
        ], session: harnessSession, headers: authorizationHeaders(accessToken))
    }

    private func signOut(accessToken: String) async throws {
        _ = try await response(
            "POST",
            path: "/auth/plugin/rownd/signout",
            session: harnessSession,
            headers: authorizationHeaders(accessToken)
        )
    }

    private func waitForCounter(_ name: String, toEqual expected: Int, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if let counters = try? await json("GET", path: "/counters") as? [String: Any],
               counters[name] as? Int == expected {
                return true
            }

            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        return false
    }

    private func request(_ method: String, path: String, body: Any? = nil) async throws -> Data {
        let (data, _) = try await response(method, path: path, body: body)
        return data
    }

    private func response(_ method: String, path: String, body: Any? = nil) async throws -> (Data, HTTPURLResponse) {
        URLProtocol.unregisterClass(SuperTokensURLProtocol.self)
        defer { URLProtocol.registerClass(SuperTokensURLProtocol.self) }

        return try await response(method, path: path, body: body, session: harnessSession)
    }

    private func json(_ method: String, path: String, body: Any? = nil) async throws -> Any {
        let data = try await request(method, path: path, body: body)
        return try JSONSerialization.jsonObject(with: data)
    }

    private func response(
        _ method: String,
        path: String,
        body: Any? = nil,
        session: URLSession,
        headers: [String: String] = [:]
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: backendURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))))
        request.httpMethod = method
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        if let body = body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw E2ETestError.unexpectedResponse
        }

        return (data, response)
    }

    private func authorizationHeaders(_ accessToken: String) -> [String: String] {
        [
            "Authorization": "Bearer \(accessToken)",
            "rid": "session",
            "fdi-version": "1.18",
            "st-auth-mode": "header"
        ]
    }

    private func requiredHeader(_ name: String, in response: HTTPURLResponse) throws -> String {
        guard let value = header(name, in: response) else {
            throw E2ETestError.missingHeader(name)
        }

        return value
    }

    private func header(_ name: String, in response: HTTPURLResponse) -> String? {
        response.allHeaderFields.first { key, _ in
            (key as? String)?.lowercased() == name.lowercased()
        }?.value as? String
    }
}

private struct E2EHarnessConfig: Decodable {
    struct SuperTokens: Decodable {
        struct AppInfo: Decodable {
            let apiDomain: String
            let apiBasePath: String
        }

        let appInfo: AppInfo
    }

    let apiUrl: String
    let appKey: String
    let hubBaseUrl: String
    let supertokens: SuperTokens
}

private enum E2ETestError: Error {
    case unexpectedResponse
    case missingHeader(String)
    case missingForegroundWindowScene
}

@MainActor
private final class PostAppleCoordinator: AppleSignUpCoordinator {
    override func updateUserDataWithAppleData(
        fullName: PersonNameComponents?,
        email: String?,
        sessionIdentity: SuperTokensSessionBridge.SessionIdentity
    ) {}
}

private actor PostAppleGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func open() {
        isOpen = true
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }

    func waitUntilOpen(timeoutNanoseconds: UInt64) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while !isOpen && DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return isOpen
    }
}

@MainActor
private final class PostAppleUIKitFixture {
    let rootViewController = UIViewController()
    let button = UIButton(type: .system)
    private let window: UIWindow
    private let previousKeyWindow: UIWindow?
    private let animationsWereEnabled: Bool
    private(set) var tapCount = 0

    init() throws {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive })
            ?? scenes.first(where: { $0.activationState != .unattached }) else {
            throw E2ETestError.missingForegroundWindowScene
        }
        let window = UIWindow(windowScene: scene)
        self.window = window
        self.previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        self.animationsWereEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        rootViewController.view.frame = scene.coordinateSpace.bounds
        rootViewController.view.backgroundColor = .systemBackground
        button.setTitle("Continue onboarding", for: .normal)
        button.frame = CGRect(x: 40, y: 120, width: 220, height: 60)
        button.addTarget(self, action: #selector(didTapButton), for: .touchUpInside)
        rootViewController.view.addSubview(button)
        window.rootViewController = rootViewController
        window.makeKeyAndVisible()
    }

    func tearDown() {
        rootViewController.dismiss(animated: false)
        window.isHidden = true
        previousKeyWindow?.makeKey()
        UIView.setAnimationsEnabled(animationsWereEnabled)
    }

    func presentIfNeeded(_ viewController: UIViewController) {
        guard viewController.presentingViewController == nil else { return }
        rootViewController.present(viewController, animated: false)
    }

    var presentedModalIsAttached: Bool {
        rootViewController.presentedViewController?.viewIfLoaded?.window === window
    }

    var rootIsAttached: Bool {
        window.rootViewController === rootViewController
            && rootViewController.viewIfLoaded?.window === window
    }

    func onboardingButtonReceivesWindowHitTest() -> Bool {
        let point = button.convert(
            CGPoint(x: button.bounds.midX, y: button.bounds.midY),
            to: window
        )
        return window.isKeyWindow
            && !window.isHidden
            && window.isUserInteractionEnabled
            && window.hitTest(point, with: nil) === button
    }

    func activateOnboardingButton() {
        button.sendActions(for: .touchUpInside)
    }

    @objc private func didTapButton() { tapCount += 1 }
}

private struct PostAppleAuthPublicationState {
    let rootHasModal: Bool
    let hubIsDisplayed: Bool
    let onboardingButtonWinsHitTest: Bool
}

@MainActor
private final class PostAppleOnboardingObserver: @preconcurrency StoreSubscriber {
    typealias StoreSubscriberStateType = Bool

    private let onAuthenticated: () -> Void
    private var hasObservedAuthentication = false

    init(onAuthenticated: @escaping () -> Void) {
        self.onAuthenticated = onAuthenticated
    }

    func newState(state isAuthenticated: Bool) {
        guard isAuthenticated, !hasObservedAuthentication else { return }
        hasObservedAuthentication = true
        onAuthenticated()
    }
}

@MainActor
private final class PostAppleCompletionRecorder {
    private(set) var events: [RowndEvent] = []
    private(set) var presentationStates: [(Bool, Bool)] = []
    private(set) var authPublicationStates: [PostAppleAuthPublicationState] = []
    private(set) var hubSuccessOptions: [RowndSignInJsOptions] = []

    func recordAuthPublication(
        rootHasModal: Bool,
        hubIsDisplayed: Bool,
        onboardingButtonWinsHitTest: Bool
    ) {
        authPublicationStates.append(PostAppleAuthPublicationState(
            rootHasModal: rootHasModal,
            hubIsDisplayed: hubIsDisplayed,
            onboardingButtonWinsHitTest: onboardingButtonWinsHitTest
        ))
    }

    func recordHubSuccess(_ options: RowndSignInJsOptions) {
        hubSuccessOptions.append(options)
    }

    func record(_ event: RowndEvent, rootHasModal: Bool, hubIsDisplayed: Bool) {
        events.append(event)
        presentationStates.append((rootHasModal, hubIsDisplayed))
    }
}

private final class PostAppleEventHandler: RowndEventHandlerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var signInCompletedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func handleRowndEvent(_ event: RowndEvent) {
        guard event.event == .signInCompleted else { return }
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private func waitForPostAppleCondition(
    timeoutNanoseconds: UInt64 = 4_000_000_000,
    condition: @escaping @MainActor @Sendable () -> Bool
) async -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if await MainActor.run(body: condition) { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return await MainActor.run(body: condition)
}
