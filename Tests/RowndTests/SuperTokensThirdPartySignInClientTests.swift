import Foundation
import Testing

@testable import Rownd

@Suite(.serialized) struct SuperTokensThirdPartySignInClientTests {
    private static let appleSessionHeaders = [
        "Content-Type": "application/json",
        "st-access-token": "apple-access-token",
        "st-refresh-token": "apple-refresh-token",
        "front-token": "apple-front-token",
        "anti-csrf": "apple-anti-csrf"
    ]

    @Test func googleExchangePostsSigninupPayload() async throws {
        try await withGlobalTestLock {
            let originalConfig = Rownd.config
            defer { Rownd.config = originalConfig }
            ThirdPartySignInURLProtocol.reset()
            ThirdPartySignInURLProtocol.responseBody = #"{"status":"OK","createdNewRecipeUser":true}"#.data(using: .utf8)!

            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ThirdPartySignInURLProtocol.self]
            let session = URLSession(configuration: configuration)
            let client = SuperTokensThirdPartySignInClient(
                apiDomain: "https://auth.example.com",
                apiBasePath: "/auth",
                session: session
            )

            let response = try await client.signInWithGoogle(idToken: "google-id-token")

            #expect(response.userType == .NewUser)
            let request = try #require(ThirdPartySignInURLProtocol.lastRequest)
            #expect(request.url?.absoluteString == "https://auth.example.com/auth/signinup")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            #expect(request.value(forHTTPHeaderField: "rid") == "thirdparty")
            #expect(request.value(forHTTPHeaderField: "fdi-version") == "4.1")

            let body = try #require(ThirdPartySignInURLProtocol.lastRequestBody)
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            #expect(json?["thirdPartyId"] as? String == "google")
            let tokens = json?["oAuthTokens"] as? [String: Any]
            #expect(tokens?["id_token"] as? String == "google-id-token")
            #expect(json?["redirectURIInfo"] == nil)
        }
    }

    @Test func googleExchangeIncludesAppVariantId() async throws {
        try await withGlobalTestLock {
            let originalConfig = Rownd.config
            defer { Rownd.config = originalConfig }
            Rownd.config.appVariantId = "variant_123"
            ThirdPartySignInURLProtocol.reset()
            ThirdPartySignInURLProtocol.responseBody = #"{"status":"OK","createdNewRecipeUser":true}"#.data(using: .utf8)!

            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ThirdPartySignInURLProtocol.self]
            let client = SuperTokensThirdPartySignInClient(
                apiDomain: "https://auth.example.com",
                apiBasePath: "/auth",
                session: URLSession(configuration: configuration)
            )

            _ = try await client.signInWithGoogle(idToken: "google-id-token")

            #expect(
                ThirdPartySignInURLProtocol.lastRequest?.url?.absoluteString
                    == "https://auth.example.com/auth/signinup?app_variant_id=variant_123"
            )
        }
    }

    @Test func appleExchangePostsAuthorizationCodeSigninupPayload() async throws {
        try await withGlobalTestLock {
            ThirdPartySignInURLProtocol.reset()
            ThirdPartySignInURLProtocol.responseBody = #"{"status":"OK","createdNewRecipeUser":true}"#.data(using: .utf8)!
            ThirdPartySignInURLProtocol.responseHeaders = Self.appleSessionHeaders

            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ThirdPartySignInURLProtocol.self]
            let session = URLSession(configuration: configuration)
            let client = SuperTokensThirdPartySignInClient(
                apiDomain: "https://auth.example.com",
                apiBasePath: "/auth",
                session: session,
                appleSession: session
            )
            let sessionBeforeExchange = await SuperTokensSessionBridge.currentSessionIdentity()

            let response = try await client.signInWithApple(
                authorizationCode: "apple-auth-code",
                clientType: "native-apple-client"
            )

            #expect(response.userType == .NewUser)
            let request = try #require(ThirdPartySignInURLProtocol.lastRequest)
            #expect(request.url?.absoluteString == "https://auth.example.com/auth/signinup")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "rid") == "thirdparty")
            #expect(request.value(forHTTPHeaderField: "st-auth-mode") == "header")
            #expect(response.sessionTokens == SuperTokensSessionTokens(
                accessToken: "apple-access-token",
                refreshToken: "apple-refresh-token",
                frontToken: "apple-front-token",
                antiCSRF: "apple-anti-csrf"
            ))
            #expect(await SuperTokensSessionBridge.currentSessionIdentity() == sessionBeforeExchange)

            let body = try #require(ThirdPartySignInURLProtocol.lastRequestBody)
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            #expect(json?["thirdPartyId"] as? String == "apple")
            #expect(json?["clientType"] as? String == "native-apple-client")
            #expect(json?["oAuthTokens"] == nil)

            let redirectURIInfo = json?["redirectURIInfo"] as? [String: Any]
            #expect(redirectURIInfo?["redirectURIOnProviderDashboard"] as? String == "")
            let queryParams = redirectURIInfo?["redirectURIQueryParams"] as? [String: Any]
            #expect(queryParams?["code"] as? String == "apple-auth-code")
        }
    }

    @Test func appleExchangeIncludesClientTypeWhenProvided() async throws {
        try await withGlobalTestLock {
            ThirdPartySignInURLProtocol.reset()
            ThirdPartySignInURLProtocol.responseBody = #"{"status":"OK","createdNewRecipeUser":false}"#.data(using: .utf8)!
            ThirdPartySignInURLProtocol.responseHeaders = Self.appleSessionHeaders

            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ThirdPartySignInURLProtocol.self]
            let session = URLSession(configuration: configuration)
            let client = SuperTokensThirdPartySignInClient(
                apiDomain: "https://auth.example.com",
                apiBasePath: "/auth",
                session: session,
                appleSession: session
            )

            _ = try await client.signInWithApple(authorizationCode: "apple-auth-code", clientType: "ios")

            let body = try #require(ThirdPartySignInURLProtocol.lastRequestBody)
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            #expect(json?["thirdPartyId"] as? String == "apple")
            #expect(json?["clientType"] as? String == "ios")
        }
    }

    @Test func appleExchangeRejectsEmptyClientTypeWithoutSendingRequest() async throws {
        try await withGlobalTestLock {
            ThirdPartySignInURLProtocol.reset()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ThirdPartySignInURLProtocol.self]
            let client = SuperTokensThirdPartySignInClient(
                apiDomain: "https://auth.example.com",
                apiBasePath: "/auth",
                session: URLSession(configuration: configuration),
                appleSession: URLSession(configuration: configuration)
            )

            do {
                _ = try await client.signInWithApple(
                    authorizationCode: "apple-auth-code",
                    clientType: "  "
                )
                Issue.record("Expected an empty Apple client type to fail")
            } catch let error as RowndError {
                #expect(error.description == "Apple sign-in requires a non-empty clientType")
            }

            #expect(ThirdPartySignInURLProtocol.lastRequest == nil)
        }
    }

    @Test(arguments: ["st-access-token", "st-refresh-token", "front-token"])
    func appleExchangeRejectsMissingRequiredSessionHeader(_ missingHeader: String) async throws {
        try await withGlobalTestLock {
            ThirdPartySignInURLProtocol.reset()
            ThirdPartySignInURLProtocol.responseBody = #"{"status":"OK","createdNewRecipeUser":false}"#.data(using: .utf8)!
            ThirdPartySignInURLProtocol.responseHeaders = Self.appleSessionHeaders.filter {
                $0.key.caseInsensitiveCompare(missingHeader) != .orderedSame
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ThirdPartySignInURLProtocol.self]
            let appleSession = URLSession(configuration: configuration)
            let client = SuperTokensThirdPartySignInClient(
                apiDomain: "https://auth.example.com",
                apiBasePath: "/auth",
                appleSession: appleSession
            )

            do {
                _ = try await client.signInWithApple(
                    authorizationCode: "apple-auth-code",
                    clientType: "ios"
                )
                Issue.record("Expected missing \(missingHeader) to fail")
            } catch let error as RowndError {
                #expect(error.description.contains(missingHeader))
            }
        }
    }

    @Test func productionAppleSessionExcludesRegisteredURLProtocols() {
        let session = SuperTokensThirdPartySignInClient.makeIsolatedAppleSession()

        #expect(session.configuration.identifier == nil)
        #expect(session.configuration.protocolClasses?.isEmpty == true)
    }

    @Test func googleExchangeMapsExistingUsers() async throws {
        try await withGlobalTestLock {
            ThirdPartySignInURLProtocol.reset()
            ThirdPartySignInURLProtocol.responseBody = #"{"status":"OK","createdNewRecipeUser":false}"#.data(using: .utf8)!

            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ThirdPartySignInURLProtocol.self]
            let session = URLSession(configuration: configuration)
            let client = SuperTokensThirdPartySignInClient(
                apiDomain: "https://auth.example.com",
                apiBasePath: "/auth",
                session: session
            )

            let response = try await client.signInWithGoogle(idToken: "google-id-token")

            #expect(response.userType == .ExistingUser)
        }
    }

    @Test func googleExchangeThrowsRefusalForNonOKStatus() async throws {
        try await withGlobalTestLock {
            ThirdPartySignInURLProtocol.reset()
            ThirdPartySignInURLProtocol.responseBody = #"{"status":"SIGN_IN_UP_NOT_ALLOWED","reason":"Cannot sign in / up due to security reasons."}"#.data(using: .utf8)!

            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ThirdPartySignInURLProtocol.self]
            let client = SuperTokensThirdPartySignInClient(
                apiDomain: "https://auth.example.com",
                apiBasePath: "/auth",
                session: URLSession(configuration: configuration)
            )

            do {
                _ = try await client.signInWithGoogle(idToken: "google-id-token")
                Issue.record("Expected SIGN_IN_UP_NOT_ALLOWED to fail")
            } catch let error as SuperTokensSignInUpRefusedError {
                #expect(error.status == "SIGN_IN_UP_NOT_ALLOWED")
                #expect(error.reason == "Cannot sign in / up due to security reasons.")
            }
        }
    }

    @Test func googleExchangeTreatsMissingStatusAsRefusal() async throws {
        try await withGlobalTestLock {
            ThirdPartySignInURLProtocol.reset()
            ThirdPartySignInURLProtocol.responseBody = #"{"createdNewRecipeUser":true}"#.data(using: .utf8)!

            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ThirdPartySignInURLProtocol.self]
            let client = SuperTokensThirdPartySignInClient(
                apiDomain: "https://auth.example.com",
                apiBasePath: "/auth",
                session: URLSession(configuration: configuration)
            )

            do {
                _ = try await client.signInWithGoogle(idToken: "google-id-token")
                Issue.record("Expected a missing status to fail")
            } catch let error as SuperTokensSignInUpRefusedError {
                #expect(error.status == nil)
                #expect(error.reason == nil)
            }
        }
    }

    @Test func appleExchangeThrowsRefusalBeforeReadingSessionHeaders() async throws {
        try await withGlobalTestLock {
            ThirdPartySignInURLProtocol.reset()
            ThirdPartySignInURLProtocol.responseBody = #"{"status":"SIGN_IN_UP_NOT_ALLOWED","reason":"Cannot sign in / up due to security reasons."}"#.data(using: .utf8)!
            ThirdPartySignInURLProtocol.responseHeaders = Self.appleSessionHeaders

            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ThirdPartySignInURLProtocol.self]
            let session = URLSession(configuration: configuration)
            let client = SuperTokensThirdPartySignInClient(
                apiDomain: "https://auth.example.com",
                apiBasePath: "/auth",
                session: session,
                appleSession: session
            )

            do {
                _ = try await client.signInWithApple(authorizationCode: "apple-auth-code", clientType: "ios")
                Issue.record("Expected SIGN_IN_UP_NOT_ALLOWED to fail even with session headers")
            } catch let error as SuperTokensSignInUpRefusedError {
                #expect(error.status == "SIGN_IN_UP_NOT_ALLOWED")
                #expect(error.reason == "Cannot sign in / up due to security reasons.")
            }
        }
    }

    @Test func exchangeNormalizesBasePathSlashes() async throws {
        try await withGlobalTestLock {
            ThirdPartySignInURLProtocol.reset()
            ThirdPartySignInURLProtocol.responseBody = #"{"status":"OK","createdNewRecipeUser":true}"#.data(using: .utf8)!

            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ThirdPartySignInURLProtocol.self]
            let session = URLSession(configuration: configuration)
            let client = SuperTokensThirdPartySignInClient(
                apiDomain: "https://auth.example.com",
                apiBasePath: "/custom-auth/",
                session: session
            )

            _ = try await client.signInWithGoogle(idToken: "google-id-token")

            let request = try #require(ThirdPartySignInURLProtocol.lastRequest)
            #expect(request.url?.absoluteString == "https://auth.example.com/custom-auth/signinup")
        }
    }

    @Test func exchangeHandlesRootBasePath() async throws {
        try await withGlobalTestLock {
            ThirdPartySignInURLProtocol.reset()
            ThirdPartySignInURLProtocol.responseBody = #"{"status":"OK","createdNewRecipeUser":true}"#.data(using: .utf8)!

            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ThirdPartySignInURLProtocol.self]
            let session = URLSession(configuration: configuration)
            let client = SuperTokensThirdPartySignInClient(
                apiDomain: "https://auth.example.com",
                apiBasePath: "/",
                session: session
            )

            _ = try await client.signInWithGoogle(idToken: "google-id-token")

            let request = try #require(ThirdPartySignInURLProtocol.lastRequest)
            #expect(request.url?.absoluteString == "https://auth.example.com/signinup")
        }
    }
}

private final class ThirdPartySignInURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var _lastRequest: URLRequest?
    private static var _lastRequestBody: Data?

    static var responseBody = Data()
    static var responseStatusCode = 200
    static var responseHeaders = ["Content-Type": "application/json"]

    static var lastRequest: URLRequest? {
        lock.withLock { _lastRequest }
    }

    static var lastRequestBody: Data? {
        lock.withLock { _lastRequestBody }
    }

    static func reset() {
        lock.withLock {
            _lastRequest = nil
            _lastRequestBody = nil
            responseBody = Data()
            responseStatusCode = 200
            responseHeaders = ["Content-Type": "application/json"]
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let body = request.httpBodyStream.flatMap { stream -> Data? in
            stream.open()
            defer { stream.close() }

            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 {
                    break
                }
                data.append(buffer, count: count)
            }
            return data
        } ?? request.httpBody

        Self.lock.withLock {
            Self._lastRequest = request
            Self._lastRequestBody = body
        }

        let statusCode = Self.lock.withLock { Self.responseStatusCode }
        let responseBody = Self.lock.withLock { Self.responseBody }
        let responseHeaders = Self.lock.withLock { Self.responseHeaders }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: responseHeaders
        )!

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
