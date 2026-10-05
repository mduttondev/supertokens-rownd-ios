import Foundation
import AnyCodable
import Testing

@testable import Rownd

@Suite(.serialized) struct GoogleSignInCoordinatorTests {
    @Test func refusedSigninupShowsErrorAndEmitsSignInFailedWithoutCompletion() async throws {
        try await withGlobalTestLock {
            GoogleSigninupURLProtocol.responseBody = #"{"status":"SIGN_IN_UP_NOT_ALLOWED","reason":"Cannot sign in / up due to security reasons."}"#.data(using: .utf8)!
            let recorder = GoogleSignInRecorder()
            let originalDisplayHubHandler = Rownd.displayHubHandler
            defer { Rownd.displayHubHandler = originalDisplayHubHandler }
            Rownd.displayHubHandler = recorder.recordHubStep

            let coordinator = Self.makeCoordinator(recorder: recorder)
            coordinator.syncAuthState = { Issue.record("A refused signinup must not synchronize auth") }

            await coordinator.completeSignIn(idToken: "google-id-token", intent: nil)

            #expect(recorder.hubSteps == [.completing, .error])
            #expect(recorder.events.map(\.event) == [.signInFailed])
            let data = try #require(recorder.events.first?.data)
            #expect(data["reason"]??.value as? String == "SIGN_IN_UP_NOT_ALLOWED")
            #expect(data["message"]??.value as? String == "Cannot sign in / up due to security reasons.")
            #expect(data["method"]??.value as? String == SignInType.google.rawValue)
        }
    }

    @Test func okSigninupWithoutSessionFailsInsteadOfCompleting() async throws {
        try await withGlobalTestLock {
            GoogleSigninupURLProtocol.responseBody = #"{"status":"OK","createdNewRecipeUser":false}"#.data(using: .utf8)!
            let recorder = GoogleSignInRecorder()
            let originalDisplayHubHandler = Rownd.displayHubHandler
            defer { Rownd.displayHubHandler = originalDisplayHubHandler }
            Rownd.displayHubHandler = recorder.recordHubStep

            let coordinator = Self.makeCoordinator(recorder: recorder)
            coordinator.currentAccessToken = { nil }

            await coordinator.completeSignIn(idToken: "google-id-token", intent: nil)

            #expect(recorder.hubSteps == [.completing, .error])
            #expect(recorder.events.map(\.event) == [.signInFailed])
            #expect(recorder.events.first?.data?["method"]??.value as? String == SignInType.google.rawValue)
        }
    }

    private static func makeCoordinator(recorder: GoogleSignInRecorder) -> GoogleSignInCoordinator {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GoogleSigninupURLProtocol.self]
        let coordinator = GoogleSignInCoordinator(Rownd.getInstance())
        coordinator.signInClient = SuperTokensThirdPartySignInClient(
            apiDomain: "https://auth.example.com",
            apiBasePath: "/auth",
            session: URLSession(configuration: configuration)
        )
        coordinator.syncAuthState = {}
        coordinator.currentAccessToken = { nil }
        coordinator.emitEvent = recorder.recordEvent
        return coordinator
    }
}

private final class GoogleSignInRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedHubSteps: [RowndSignInLoginStep] = []
    private var recordedEvents: [RowndEvent] = []

    var hubSteps: [RowndSignInLoginStep] {
        lock.withLock { recordedHubSteps }
    }

    var events: [RowndEvent] {
        lock.withLock { recordedEvents }
    }

    func recordHubStep(_ page: HubPageSelector, _ options: Encodable?) {
        guard let loginStep = (options as? RowndSignInJsOptions)?.loginStep else { return }
        lock.withLock { recordedHubSteps.append(loginStep) }
    }

    func recordEvent(_ event: RowndEvent) {
        lock.withLock { recordedEvents.append(event) }
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
