import Foundation
import AnyCodable
import Testing

@testable import Rownd

@Suite(.serialized) struct GoogleSignInCoordinatorTests {
    private static let refusal = SuperTokensSignInUpRefusedError(
        status: "SIGN_IN_UP_NOT_ALLOWED",
        reason: "Cannot sign in / up due to security reasons."
    )
    private static let accessTokenJWT = [#"{"alg":"none"}"#, #"{"aud":["app:test-app"]}"#]
        .map {
            Data($0.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        .joined(separator: ".") + ".signature"

    @Test func refusedSigninupShowsErrorAndEmitsSignInFailedWithoutCompletion() async throws {
        try await withGoogleSignInHarness { coordinator, recorder in
            GoogleSigninupURLProtocol.responseBody = #"{"status":"SIGN_IN_UP_NOT_ALLOWED","reason":"Cannot sign in / up due to security reasons."}"#.data(using: .utf8)!
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [GoogleSigninupURLProtocol.self]
            let client = SuperTokensThirdPartySignInClient(
                apiDomain: "https://auth.example.com",
                apiBasePath: "/auth",
                session: URLSession(configuration: configuration)
            )
            coordinator.signInWithGoogle = { try await client.signInWithGoogle(idToken: $0) }
            coordinator.syncAuthState = {
                Issue.record("A refused signinup must not synchronize auth")
                return true
            }

            let attemptID = await coordinator.beginAttempt(emitsSignInStarted: false)
            await coordinator.completeSignIn(idToken: "google-id-token", intent: nil, attemptID: attemptID)

            #expect(recorder.hubSteps == ["completing", "error"])
            #expect(recorder.events.map(\.event) == [.signInFailed])
            let data = try #require(recorder.events.first?.data)
            #expect(data["reason"]??.value as? String == "SIGN_IN_UP_NOT_ALLOWED")
            #expect(data["message"]??.value as? String == "Cannot sign in / up due to security reasons.")
            #expect(data["method"]??.value as? String == SignInType.google.rawValue)
        }
    }

    @Test func okSigninupWithoutSessionFailsInsteadOfCompleting() async throws {
        try await withGoogleSignInHarness { coordinator, recorder in
            coordinator.syncAuthState = { true }
            coordinator.currentAccessToken = { nil }

            let attemptID = await coordinator.beginAttempt(emitsSignInStarted: false)
            await coordinator.completeSignIn(idToken: "google-id-token", intent: nil, attemptID: attemptID)

            #expect(recorder.hubSteps == ["completing", "error"])
            #expect(recorder.events.map(\.event) == [.signInFailed])
            #expect(recorder.events.first?.data?["method"]??.value as? String == SignInType.google.rawValue)
        }
    }

    @Test func failedAuthSyncFailsEvenWhenTokenExists() async throws {
        try await withGoogleSignInHarness { coordinator, recorder in
            coordinator.syncAuthState = { false }
            coordinator.currentAccessToken = { "google-access-token" }

            let attemptID = await coordinator.beginAttempt(emitsSignInStarted: false)
            await coordinator.completeSignIn(idToken: "google-id-token", intent: nil, attemptID: attemptID)

            #expect(recorder.hubSteps == ["completing", "error"])
            #expect(recorder.events.map(\.event) == [.signInFailed])
        }
    }

    @Test func successAfterHubRequestIsReplacedStillCompletesWithoutReopeningHub() async throws {
        try await withGoogleSignInHarness { coordinator, recorder in
            let releaseSigninup = GoogleSignInGate()
            let signinupStarted = GoogleSignInGate()
            coordinator.signInWithGoogle = { _ in
                await signinupStarted.open()
                await releaseSigninup.wait()
                return SuperTokensThirdPartySignInResponse(status: "OK", createdNewRecipeUser: false)
            }
            coordinator.currentAccessToken = { "google-access-token" }

            let attemptID = await coordinator.beginAttempt(emitsSignInStarted: false)
            let attempt = Task { @MainActor in
                await coordinator.completeSignIn(idToken: "google-id-token", intent: nil, attemptID: attemptID)
            }
            _ = await signinupStarted.waitUntilOpen()

            let newerRequestID = UUID()
            await MainActor.run {
                Rownd.requestSignInForNativeCompletion(
                    jsFnOptions: RowndSignInJsOptions(loginStep: .completing, signInType: .apple),
                    requestID: newerRequestID
                )
            }
            await releaseSigninup.open()
            await attempt.value

            #expect(recorder.hubSteps == ["completing", "completing"])
            #expect(recorder.events.map(\.event) == [.signInCompleted])
            #expect(recorder.signInActionDispatches == 1)
            #expect(await Rownd.isNativeHubRequestActive(newerRequestID))
        }
    }

    @Test func supersededAttemptSuccessStillCompletesWithoutTouchingNewerHubRequest() async throws {
        try await withGoogleSignInHarness { coordinator, recorder in
            let releaseSigninup = GoogleSignInGate()
            let signinupStarted = GoogleSignInGate()
            coordinator.signInWithGoogle = { _ in
                await signinupStarted.open()
                await releaseSigninup.wait()
                return SuperTokensThirdPartySignInResponse(status: "OK", createdNewRecipeUser: false)
            }
            coordinator.currentAccessToken = { "google-access-token" }

            let staleAttemptID = await coordinator.beginAttempt(emitsSignInStarted: false)
            let staleAttempt = Task { @MainActor in
                await coordinator.completeSignIn(idToken: "google-id-token", intent: nil, attemptID: staleAttemptID)
            }
            _ = await signinupStarted.waitUntilOpen()

            _ = await coordinator.beginAttempt(emitsSignInStarted: false)
            let newerRequestID = UUID()
            await MainActor.run {
                Rownd.requestSignInForNativeCompletion(
                    jsFnOptions: RowndSignInJsOptions(loginStep: .completing),
                    requestID: newerRequestID
                )
            }
            await releaseSigninup.open()
            await staleAttempt.value

            #expect(recorder.hubSteps == ["completing", "completing"])
            #expect(recorder.events.map(\.event) == [.signInCompleted])
            #expect(recorder.signInActionDispatches == 1)
            #expect(await Rownd.isNativeHubRequestActive(newerRequestID))
        }
    }

    @Test func currentWebViewSuccessReloadsWithRphInitAndLeavesCompletionToHub() async throws {
        try await withGoogleSignInHarness { coordinator, recorder in
            coordinator.signInWithGoogle = { _ in
                SuperTokensThirdPartySignInResponse(status: "OK", createdNewRecipeUser: false)
            }
            coordinator.currentAccessToken = { Self.accessTokenJWT }

            let attemptID = await coordinator.beginAttempt(emitsSignInStarted: false)
            await coordinator.completeSignIn(idToken: "google-id-token", webViewId: "web-view", attemptID: attemptID)

            #expect(recorder.webViewScripts.count == 2)
            #expect(recorder.webViewScripts.last?.contains("rph_init=") == true)
            #expect(recorder.events.isEmpty)
            #expect(recorder.signInActionDispatches == 0)
        }
    }

    @Test func supersededWebViewSuccessCompletesNativelyWithoutReload() async throws {
        try await withGoogleSignInHarness { coordinator, recorder in
            let releaseSigninup = GoogleSignInGate()
            let signinupStarted = GoogleSignInGate()
            coordinator.signInWithGoogle = { _ in
                await signinupStarted.open()
                await releaseSigninup.wait()
                return SuperTokensThirdPartySignInResponse(status: "OK", createdNewRecipeUser: true)
            }
            coordinator.currentAccessToken = { Self.accessTokenJWT }

            let staleAttemptID = await coordinator.beginAttempt(emitsSignInStarted: false)
            let staleAttempt = Task { @MainActor in
                await coordinator.completeSignIn(idToken: "google-id-token", webViewId: "web-view", attemptID: staleAttemptID)
            }
            _ = await signinupStarted.waitUntilOpen()
            _ = await coordinator.beginAttempt(emitsSignInStarted: false)
            await releaseSigninup.open()
            await staleAttempt.value

            #expect(recorder.webViewScripts.count == 1)
            #expect(recorder.webViewScripts.contains { $0.contains("rph_init=") } == false)
            #expect(recorder.events.map(\.event) == [.signInCompleted])
            #expect(recorder.events.first?.data?["user_type"]??.value as? String == UserType.NewUser.rawValue)
            #expect(recorder.signInActionDispatches == 1)
        }
    }

    @Test func delayedRefusalReportsFailureWithoutReplacingNewerHubRequest() async throws {
        try await withGoogleSignInHarness { coordinator, recorder in
            let releaseSigninup = GoogleSignInGate()
            let signinupStarted = GoogleSignInGate()
            coordinator.signInWithGoogle = { _ in
                await signinupStarted.open()
                await releaseSigninup.wait()
                throw Self.refusal
            }

            let attemptID = await coordinator.beginAttempt(emitsSignInStarted: false)
            let attempt = Task { @MainActor in
                await coordinator.completeSignIn(idToken: "google-id-token", intent: nil, attemptID: attemptID)
            }
            _ = await signinupStarted.waitUntilOpen()

            let newerRequestID = UUID()
            await MainActor.run {
                Rownd.requestSignInForNativeCompletion(
                    jsFnOptions: RowndSignInJsOptions(loginStep: .completing, signInType: .apple),
                    requestID: newerRequestID
                )
            }
            await releaseSigninup.open()
            await attempt.value

            #expect(recorder.hubSteps == ["completing", "completing"])
            #expect(recorder.events.map(\.event) == [.signInFailed])
            #expect(await Rownd.isNativeHubRequestActive(newerRequestID))
        }
    }

    @Test func delayedRefusalDoesNotReplaceNewerGoogleAttempt() async throws {
        try await withGoogleSignInHarness { coordinator, recorder in
            let releaseSigninup = GoogleSignInGate()
            let signinupStarted = GoogleSignInGate()
            coordinator.signInWithGoogle = { _ in
                await signinupStarted.open()
                await releaseSigninup.wait()
                throw Self.refusal
            }

            let staleAttemptID = await coordinator.beginAttempt(emitsSignInStarted: false)
            let staleAttempt = Task { @MainActor in
                await coordinator.completeSignIn(idToken: "google-id-token", intent: nil, attemptID: staleAttemptID)
            }
            _ = await signinupStarted.waitUntilOpen()
            _ = await coordinator.beginAttempt(emitsSignInStarted: false)
            await releaseSigninup.open()
            await staleAttempt.value

            #expect(recorder.hubSteps == ["completing"])
            #expect(recorder.events.isEmpty)
        }
    }

    @Test func refusalThenRequestSignInThenRetryCompletes() async throws {
        try await withGoogleSignInHarness { coordinator, recorder in
            let responses = GoogleSigninupResponses([
                .failure(Self.refusal),
                .success(SuperTokensThirdPartySignInResponse(status: "OK", createdNewRecipeUser: false))
            ])
            coordinator.signInWithGoogle = { _ in try responses.next() }
            coordinator.syncAuthState = { true }
            coordinator.currentAccessToken = { "google-access-token" }

            let refusedAttemptID = await coordinator.beginAttempt(emitsSignInStarted: false)
            await coordinator.completeSignIn(idToken: "google-id-token", intent: nil, attemptID: refusedAttemptID)
            Rownd.requestSignIn()
            let retryAttemptID = await coordinator.beginAttempt(emitsSignInStarted: false)
            await coordinator.completeSignIn(idToken: "google-id-token", intent: nil, attemptID: retryAttemptID)

            #expect(recorder.hubSteps == ["completing", "error", "sign-in", "completing", "success"])
            #expect(recorder.events.map(\.event) == [.signInFailed, .signInCompleted])
        }
    }

    @Test func onlyDirectAttemptsEmitSignInStarted() async throws {
        try await withGoogleSignInHarness { coordinator, recorder in
            _ = await coordinator.beginAttempt(emitsSignInStarted: false)
            #expect(recorder.events.isEmpty)

            _ = await coordinator.beginAttempt(emitsSignInStarted: true)
            #expect(recorder.events.map(\.event) == [.signInStarted])
            #expect(recorder.events.first?.data?["method"]??.value as? String == SignInType.google.rawValue)
        }
    }

    @Test(arguments: [false, true])
    func requestSignInEmitsStartOnlyWhenNotInitiatedByHub(_ initiatedByHub: Bool) async throws {
        try await withGlobalTestLock {
            let originalCoordinator = Rownd.googleSignInCoordinator
            defer { Rownd.googleSignInCoordinator = originalCoordinator }
            let coordinator = EntryPointRecordingGoogleCoordinator(Rownd.getInstance())
            Rownd.googleSignInCoordinator = coordinator

            await withCheckedContinuation { continuation in
                Rownd.requestSignIn(
                    with: .googleId,
                    signInOptions: RowndSignInOptions(),
                    initiatedByHub: initiatedByHub,
                    completion: { continuation.resume() }
                )
            }

            #expect(coordinator.emitsSignInStarted == [!initiatedByHub])
        }
    }

    private func withGoogleSignInHarness(
        _ body: @escaping @Sendable (GoogleSignInCoordinator, GoogleSignInRecorder) async throws -> Void
    ) async throws {
        try await withGlobalTestLock {
            let recorder = GoogleSignInRecorder()
            let originalDisplayHubHandler = Rownd.displayHubHandler
            defer { Rownd.displayHubHandler = originalDisplayHubHandler }
            Rownd.displayHubHandler = recorder.recordHubStep

            let coordinator = GoogleSignInCoordinator(Rownd.getInstance())
            coordinator.syncAuthState = { true }
            coordinator.currentAccessToken = { nil }
            coordinator.emitEvent = recorder.recordEvent
            coordinator.dispatchSignInActions = recorder.recordSignInActions
            coordinator.evaluateCustomerWebViewJavaScript = recorder.recordWebViewScript
            try await body(coordinator, recorder)
        }
    }
}

private final class EntryPointRecordingGoogleCoordinator: GoogleSignInCoordinator, @unchecked Sendable {
    private(set) var emitsSignInStarted: [Bool] = []

    override func signIn(_ intent: RowndSignInIntent?, hint: String?, emitsSignInStarted: Bool) async {
        self.emitsSignInStarted.append(emitsSignInStarted)
    }
}

private final class GoogleSignInRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedHubSteps: [String] = []
    private var recordedEvents: [RowndEvent] = []
    private var recordedSignInActionDispatches = 0
    private var recordedWebViewScripts: [String] = []

    var signInActionDispatches: Int {
        lock.withLock { recordedSignInActionDispatches }
    }

    var webViewScripts: [String] {
        lock.withLock { recordedWebViewScripts }
    }

    func recordSignInActions() {
        lock.withLock { recordedSignInActionDispatches += 1 }
    }

    func recordWebViewScript(_ webViewId: String, _ code: String) {
        lock.withLock { recordedWebViewScripts.append(code) }
    }

    var hubSteps: [String] {
        lock.withLock { recordedHubSteps }
    }

    var events: [RowndEvent] {
        lock.withLock { recordedEvents }
    }

    func recordHubStep(_ page: HubPageSelector, _ options: Encodable?) {
        let step = (options as? RowndSignInJsOptions)?.loginStep?.rawValue ?? "sign-in"
        lock.withLock { recordedHubSteps.append(step) }
    }

    func recordEvent(_ event: RowndEvent) {
        lock.withLock { recordedEvents.append(event) }
    }
}

private final class GoogleSigninupResponses: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: [Result<SuperTokensThirdPartySignInResponse, Error>]

    init(_ responses: [Result<SuperTokensThirdPartySignInResponse, Error>]) {
        remaining = responses
    }

    func next() throws -> SuperTokensThirdPartySignInResponse {
        try lock.withLock { remaining.removeFirst() }.get()
    }
}

private actor GoogleSignInGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitUntilOpen() async -> Bool {
        await wait()
        return isOpen
    }
}

private final class GoogleSigninupURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responseBody = Data()

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
