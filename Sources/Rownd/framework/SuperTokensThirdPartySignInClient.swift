import Foundation

struct SuperTokensThirdPartySignInRequest: Encodable {
    let thirdPartyId: String
    let clientType: String?
    let oAuthTokens: OAuthTokens?
    let redirectURIInfo: RedirectURIInfo?

    struct OAuthTokens: Encodable {
        let idToken: String

        enum CodingKeys: String, CodingKey {
            case idToken = "id_token"
        }
    }

    struct RedirectURIInfo: Encodable {
        let redirectURIOnProviderDashboard: String
        let redirectURIQueryParams: [String: String]
    }
}

struct SuperTokensThirdPartySignInResponse {
    let status: String?
    let createdNewRecipeUser: Bool?

    init(
        status: String?,
        createdNewRecipeUser: Bool?
    ) {
        self.status = status
        self.createdNewRecipeUser = createdNewRecipeUser
    }

    var userType: UserType {
        createdNewRecipeUser == true ? .NewUser : .ExistingUser
    }

    fileprivate struct Body: Decodable {
        let status: String?
        let reason: String?
        let createdNewRecipeUser: Bool?
    }
}

/// A signinup response that arrived with a 2xx code but a `status` other than `OK`.
struct SuperTokensSignInUpRefusedError: Error, CustomStringConvertible {
    let status: String?
    let reason: String?

    var description: String {
        "SuperTokens signinup returned status \(status ?? "<missing>")"
    }
}

struct SuperTokensAppleSignInResponse {
    let status: String?
    let createdNewRecipeUser: Bool?
    let sessionTokens: SuperTokensSessionTokens

    var userType: UserType {
        createdNewRecipeUser == true ? .NewUser : .ExistingUser
    }
}

struct SuperTokensThirdPartySignInClient {
    private let apiDomainOverride: String?
    private let apiBasePathOverride: String?
    private let session: URLSession
    private let appleSession: URLSession

    init(
        apiDomain: String? = nil,
        apiBasePath: String? = nil,
        session: URLSession = .shared,
        appleSession: URLSession? = nil
    ) {
        self.apiDomainOverride = apiDomain
        self.apiBasePathOverride = apiBasePath
        self.session = session
        self.appleSession = appleSession ?? Self.makeIsolatedAppleSession()
    }

    static func makeIsolatedAppleSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        // Defer session adoption until the owning Apple auth operation is revalidated.
        configuration.protocolClasses = []
        return URLSession(configuration: configuration)
    }

    func signInWithGoogle(idToken: String) async throws -> SuperTokensThirdPartySignInResponse {
        let result = try await signIn(
            SuperTokensThirdPartySignInRequest(
                thirdPartyId: "google",
                clientType: nil,
                oAuthTokens: .init(idToken: idToken),
                redirectURIInfo: nil
            ),
            using: session,
            usesHeaderAuthMode: false
        )
        return SuperTokensThirdPartySignInResponse(
            status: result.body.status,
            createdNewRecipeUser: result.body.createdNewRecipeUser
        )
    }

    func signInWithApple(authorizationCode: String, clientType: String) async throws -> SuperTokensAppleSignInResponse {
        let clientType = clientType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientType.isEmpty else {
            throw RowndError("Apple sign-in requires a non-empty clientType")
        }

        let result = try await signIn(
            SuperTokensThirdPartySignInRequest(
                thirdPartyId: "apple",
                clientType: clientType,
                oAuthTokens: nil,
                redirectURIInfo: .init(
                    redirectURIOnProviderDashboard: "",
                    redirectURIQueryParams: ["code": authorizationCode]
                )
            ),
            using: appleSession,
            usesHeaderAuthMode: true
        )
        return SuperTokensAppleSignInResponse(
            status: result.body.status,
            createdNewRecipeUser: result.body.createdNewRecipeUser,
            sessionTokens: try Self.sessionTokens(from: result.response)
        )
    }

    private func signIn(
        _ body: SuperTokensThirdPartySignInRequest,
        using session: URLSession,
        usesHeaderAuthMode: Bool
    ) async throws -> (body: SuperTokensThirdPartySignInResponse.Body, response: HTTPURLResponse) {
        let supertokens = apiDomainOverride == nil || apiBasePathOverride == nil ? try Rownd.requireSuperTokensConfig() : nil
        let apiDomain = apiDomainOverride ?? supertokens!.apiDomain
        let apiBasePath = apiBasePathOverride ?? supertokens!.apiBasePath

        guard var components = URLComponents(string: apiDomain) else {
            throw RowndError("Invalid SuperTokens apiDomain")
        }

        let normalizedBasePath = apiBasePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = normalizedBasePath.isEmpty ? "/signinup" : "/\(normalizedBasePath)/signinup"
        if let appVariantId = Rownd.config.appVariantId, !appVariantId.isEmpty {
            components.queryItems = [URLQueryItem(name: "app_variant_id", value: appVariantId)]
        }
        guard let url = components.url else {
            throw RowndError("Invalid SuperTokens signinup URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("thirdparty", forHTTPHeaderField: "rid")
        request.setValue("4.1", forHTTPHeaderField: "fdi-version")
        if usesHeaderAuthMode {
            request.setValue("header", forHTTPHeaderField: "st-auth-mode")
        }
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RowndError("SuperTokens signinup returned a non-HTTP response")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw RowndError("SuperTokens signinup failed with status code \(httpResponse.statusCode)")
        }

        let decodedBody = try JSONDecoder().decode(SuperTokensThirdPartySignInResponse.Body.self, from: data)
        // FDI reports refusals such as SIGN_IN_UP_NOT_ALLOWED with HTTP 200, and a missing status is treated the same way.
        guard decodedBody.status == "OK" else {
            throw SuperTokensSignInUpRefusedError(status: decodedBody.status, reason: decodedBody.reason)
        }

        return (decodedBody, httpResponse)
    }

    private static func sessionTokens(from response: HTTPURLResponse) throws -> SuperTokensSessionTokens {
        guard let accessToken = response.headerValue(named: "st-access-token"), !accessToken.isEmpty else {
            throw RowndError("SuperTokens signinup response did not include st-access-token")
        }
        guard let refreshToken = response.headerValue(named: "st-refresh-token"), !refreshToken.isEmpty else {
            throw RowndError("SuperTokens signinup response did not include st-refresh-token")
        }
        guard let frontToken = response.headerValue(named: "front-token"), !frontToken.isEmpty else {
            throw RowndError("SuperTokens signinup response did not include front-token")
        }

        return SuperTokensSessionTokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            frontToken: frontToken,
            antiCSRF: response.headerValue(named: "anti-csrf")
        )
    }
}
