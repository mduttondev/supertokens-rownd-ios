//
//  Auth.swift
//  framework
//
//  Created by Matt Hamann on 6/25/22.
//

import Foundation
import UIKit
import ReSwift
import ReSwiftThunk
import JWTDecode
import Get
import AnyCodable

public struct AuthState: Hashable, CustomStringConvertible {
    public var isLoading: Bool = false
    public var accessToken: String?
    public var refreshToken: String?
    public var isVerifiedUser: Bool?
    public var hasPreviouslySignedIn: Bool? = false
    public var userId: String?
    public var challengeId: String?
    public var userIdentifier: String?
    internal var profileHydrationPendingSessionIdentity: SuperTokensSessionBridge.StableSessionIdentity? = nil

    public var description: String {
        return "AuthState(isLoading: \(isLoading), isAuthenticated: \(isAuthenticated), accessToken: \(isAuthenticated ? "[REDACTED]" : "nil"), refreshToken: \(isAuthenticated ? "[REDACTED]" : "nil"), userId: \(userId ?? "nil"), challengeId: \(challengeId ?? "nil"), userIdentifier: \(userIdentifier ?? "nil"))"
    }
}

extension AuthState: Codable {
    public var isAuthenticated: Bool {
        return accessToken != nil
    }

    public var isAuthenticatedWithUserData: Bool {
        if (!isAuthenticated) {
            return false
        }

        let userId = Context.currentContext.store.state.user.data["user_id"]

        return userId != nil
    }

    public var isAccessTokenValid: Bool {
        guard let accessToken = accessToken, !isLoading, Context.currentContext.store.state.clockSyncState != .waiting else {
            return false
        }

        do {
            let jwt = try decode(jwt: accessToken)

            let currentDate = NetworkTimeManager.shared.currentTime ?? Date()
            guard let expiresAt = jwt.expiresAt, let currentDateWithMargin = Calendar.current.date(byAdding: .second, value: 60, to: currentDate) else {
                return false
            }

            if (try? Rownd.config.requireSuperTokensConfig()) != nil,
               !Self.isSuperTokensAccessToken(jwt),
               Self.isLegacyRowndAccessToken(jwt) {
                return false
            }

            return !jwt.ntpExpired && (currentDateWithMargin < expiresAt)
        } catch {
            return false
        }
    }

    static func isSuperTokensAccessToken(_ accessToken: String?) -> Bool {
        guard let accessToken, let jwt = try? decode(jwt: accessToken) else { return false }
        return isSuperTokensAccessToken(jwt)
    }

    private static func isSuperTokensAccessToken(_ jwt: JWT) -> Bool {
        jwt.claim(name: "sessionHandle").string != nil
            || jwt.claim(name: "tId").string != nil
    }

    private static func isLegacyRowndAccessToken(_ jwt: JWT) -> Bool {
        jwt.claim(name: "https://auth.rownd.io/app_user_id").string != nil
            || jwt.claim(name: "app_user_id").string != nil
    }

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case isVerifiedUser = "is_verified_user"
        case hasPreviouslySignedIn = "has_previously_signed_in"
        case userId = "user_id"
        case challengeId = "challenge_id"
        case userIdentifier = "user_identifier"
        case profileHydrationPendingSessionIdentity = "profile_hydration_pending_session_identity"
    }

    func toRphInitHash() -> String? {
        guard let accessToken = self.accessToken, !accessToken.isEmpty,
              let refreshToken = self.refreshToken ?? SuperTokensSessionBridge.getRefreshToken(), !refreshToken.isEmpty else {
            return nil
        }

        let jwt = try? decode(jwt: accessToken)
        let signedAppUserId = [
            jwt?.claim(name: "https://auth.rownd.io/app_user_id").string,
            jwt?.claim(name: "app_user_id").string
        ].compactMap { $0 }.first { !$0.isEmpty }
        let cachedUserId = Context.currentContext.store.state.user.get(field: "user_id") as String?
        let signedSubject = jwt?.subject ?? jwt?.claim(name: "userId").string
        let cachedUserIdMatchesSubject = signedSubject?.isEmpty == false
            && cachedUserId?.isEmpty == false
            && signedSubject == cachedUserId
        let userId = signedAppUserId
            ?? (cachedUserIdMatchesSubject ? cachedUserId : nil)

        let rphInit = RphInit(
            accessToken: accessToken,
            refreshToken: refreshToken,
            frontToken: SuperTokensSessionBridge.getFrontToken(),
            antiCSRF: SuperTokensSessionBridge.getAntiCSRF(),
            appId: Context.currentContext.store.state.appConfig.id,
            appUserId: userId
        )
        
        do {
            return try rphInit.valueForURLFragment()
        } catch {
            logger.error("Failed to build rph_init hash string: \(String(describing: error))")
            return nil
        }
    }

    func getAccessToken(throwIfMissing: Bool) async throws -> String? {
        do {
            let authState = try await Context.currentContext.authenticator.getValidToken()
            return authState.accessToken
        } catch {
            logger.warning("Failed to retrieve access token: \(String(describing: error))")

            if throwIfMissing {
                throw error
            }

            switch error as? AuthenticationError {
            case
                .networkConnectionFailure,
                .serverError:
                throw error

            default: break
            }

            return nil
        }
    }

func onReceiveAuthTokens(_ newAuthState: AuthState) -> Thunk<RowndState> {
        return Thunk<RowndState> { dispatch, getState in
            guard let _ = getState() else { return }

            Task {
                // This is a special case to get the new auth state over
                // to the authenticator as quickly as possible without
                // waiting for the store update flow to complete

                DispatchQueue.main.async {
                    dispatch(SetAuthState(payload: newAuthState))
                    dispatch(UserData.fetch())
                }
            }

        }
    }

    func onReceiveAppleAuthTokens(_ newAuthState: AuthState) -> Thunk<RowndState> {
        return Thunk<RowndState> { dispatch, getState in
            guard let _ = getState() else { return }

            Task {
                // This is a special case to get the new auth state over
                // to the authenticator as quickly as possible without
                // waiting for the store update flow to complete

                DispatchQueue.main.async {
                    dispatch(SetAuthState(payload: newAuthState))
                }
            }

        }
    }
}

// MARK: Reducers

struct SetAuthState: Action {
    var payload = AuthState()
}

func authReducer(action: Action, state: AuthState?) -> AuthState {
    var state = state ?? AuthState()

    let hasPreviouslySignedIn = state.hasPreviouslySignedIn

    switch action {
    case let action as SetAuthState:
        state = action.payload
    case let action as SetUserData:
        state.userId = action.data["user_id"]?.value as? String
    case let action as SetUserState:
        state.userId = action.payload.data["user_id"]?.value as? String
    default:
        break
    }

    if hasPreviouslySignedIn ?? false || state.isAuthenticated {
        state.hasPreviouslySignedIn = true
    }

    return state
}

// MARK: Token / auth API calls

public enum UserType: String, Codable {
    case NewUser = "new_user"
    case ExistingUser = "existing_user"
    case Unknown = "unknown"

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = UserType(rawValue: rawValue) ?? .Unknown
    }
}

struct TokenRequest: Codable {
    var refreshToken: String?
    var idToken: String?
    var appId: String?
    var intent: RowndSignInIntent?
    var intentMismatchBehavior: String?
    var userData: [String: AnyCodable?]?
    var instantUserId: String?

    enum CodingKeys: String, CodingKey {
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case appId = "app_id"
        case intentMismatchBehavior = "intent_mismatch_behavior"
        case intent
        case userData = "user_data"
        case instantUserId = "instant_user_id"
    }
}

struct TokenResponse: Codable {
    var refreshToken: String?
    var accessToken: String?
    var userType: UserType?
    var appVariantUserType: UserType?

    enum CodingKeys: String, CodingKey {
        case refreshToken = "refresh_token"
        case accessToken = "access_token"
        case userType = "user_type"
        case appVariantUserType = "app_variant_user_type"
    }
}

class Auth {
    static func signOutUser() async throws {
        let supertokens = try Rownd.requireSuperTokensConfig()

        guard var components = URLComponents(string: supertokens.apiDomain) else {
            throw RowndError("Invalid SuperTokens apiDomain")
        }
        components.path = supertokens.apiBasePath + "/plugin/rownd/signout"

        guard let url = components.url else {
            throw RowndError("Invalid SuperTokens signout URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        guard let accessToken = await SuperTokensSessionBridge.getAccessToken(), !accessToken.isEmpty else {
            throw RowndError("Cannot sign out all sessions without a SuperTokens access token")
        }
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("session", forHTTPHeaderField: "rid")
        request.setValue("1.18", forHTTPHeaderField: "fdi-version")
        request.setValue("header", forHTTPHeaderField: "st-auth-mode")

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RowndError("SuperTokens signout returned a non-HTTP response")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw RowndError("SuperTokens signout failed with status code \(httpResponse.statusCode)")
        }
    }
}

extension JWT {
    var ntpExpired: Bool {
        guard let date = self.expiresAt else {
            return false
        }

        let ntpDate = NetworkTimeManager.shared.currentTime

        guard let ntpDate = ntpDate else {
            return self.expired
        }

        // Token is expired if the token expiration timestamp is less than the current timestamp (minus a 60 second buffer)

        return date.compare(ntpDate) != ComparisonResult.orderedDescending
    }
}
