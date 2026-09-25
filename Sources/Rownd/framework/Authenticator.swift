//
//  Authenticator.swift
//  Rownd
//
//  Created by Matt Hamann on 10/16/22.
//

import Foundation
import Get
import JWTDecode
import OSLog
import ReSwift

private let log = Logger(subsystem: "io.rownd.sdk", category: "authenticator")

protocol AuthenticatorProtocol {
    func getValidToken() async throws -> AuthState
    func refreshToken() async throws -> AuthState
}

public enum AuthenticationError: Error, LocalizedError, Equatable {
    case noAccessTokenPresent
    case invalidRefreshToken(details: String)
    case networkConnectionFailure(details: String)
    case serverError(details: String)

    public var errorDescription: String? {
        switch self {
        case .noAccessTokenPresent:
            return "No access token present"
        case .invalidRefreshToken(let details):
            return "Invalid refresh token: \(details)"
        case .networkConnectionFailure(let details):
            return "Network connection failure: \(details)"
        case .serverError(let details):
            return "Server error: \(details)"
        }
    }
}

internal let tokenApiConfig = APIClient.Configuration(
    baseURL: URL(string: Rownd.config.apiUrl),
    delegate: TokenApiClientDelegate()
)

internal func tokenApiFactory() -> APIClient {
    return Get.APIClient(configuration: tokenApiConfig)
}

private class TokenApiClientDelegate: APIClientDelegate {
    func client(_ client: APIClient, willSendRequest request: inout URLRequest) async throws {
        request.setValue(
            Constants.TIME_META_HEADER, forHTTPHeaderField: Constants.TIME_META_HEADER_NAME)
        request.setValue(Constants.DEFAULT_API_USER_AGENT, forHTTPHeaderField: "User-Agent")

        let localRequest = request
        log.info(
            "Making request to: \(String(describing: localRequest.httpMethod?.uppercased())) \(String(describing: localRequest.url))"
        )
    }

    // Handle refresh token non-400 response codes
    func client(_ client: APIClient, shouldRetry task: URLSessionTask, error: Error, attempts: Int)
        async throws -> Bool
    {
        if case .unacceptableStatusCode(let statusCode) = error as? APIError,
            statusCode != 400,
            attempts <= 5
        {
            return true
        }

        switch (error as? URLError)?.code {
        case .some(.timedOut),
            .some(.cannotFindHost),
            .some(.cannotConnectToHost),
            .some(.networkConnectionLost),
            .some(.notConnectedToInternet),
            .some(.cancelled),
            .some(.dnsLookupFailed):
            if attempts <= 5 {
                return true
            }
        default: break
        }

        return false
    }
}

// This class exists for the sole purpose of subscribing the Authenticator to the
// global state. Data races can occur when using subscribers within the actor itself,
// which leads to memmory corruption and weird app crashes.
class AuthenticatorSubscription: NSObject {
    private static let inst: AuthenticatorSubscription = AuthenticatorSubscription()
    internal static var currentAuthState: AuthState? = Context.currentContext.store.state.auth

    private override init() {}

    /// This checks the incoming action to determine whether it contains an AuthState payload and pushes that
    /// to the Authenticator if present. This prevents race conditions between the internal Rownd state and any
    /// external subscribers. The Authenticator MUST always reflect the correct state in order to prevent race conditions.
    internal static func createAuthenticatorMiddleware<State>() -> Middleware<State> {
        return { _, _ in
            return { next in
                return { action in
                    var authState: AuthState?

                    switch action {
                    case let action as SetAuthState:
                        authState = action.payload
                    case let action as InitializeRowndState:
                        authState = action.payload.auth
                    default:
                        break
                    }

                    guard let authState = authState else {
                        return next(action)
                    }
                    AuthenticatorSubscription.currentAuthState = authState
                    next(action)
                }
            }
        }
    }
}

actor Authenticator: AuthenticatorProtocol {
    private let sessionBridge: SuperTokensSessionBridgeClient
    private let persistState: @MainActor (RowndState) -> Bool
    private var refreshTask: Task<AuthState, Error>?

    init(
        sessionBridge: SuperTokensSessionBridgeClient = .live,
        persistState: @escaping @MainActor (RowndState) -> Bool = { $0.saveImmediately() }
    ) {
        self.sessionBridge = sessionBridge
        self.persistState = persistState
    }

    func getValidToken() async throws -> AuthState {
        if let handle = refreshTask {
            return try await handle.value
        }

        guard let accessToken = try await sessionBridge.getAccessToken() else {
            throw AuthenticationError.noAccessTokenPresent
        }

        guard isAccessTokenValid(accessToken) else {
            return try await refreshToken()
        }

        return try await syncCompatibilityAuthState(accessToken: accessToken)
    }

    func refreshToken() async throws -> AuthState {
        if let refreshTask = refreshTask {
            log.debug("Waiting for token refresh already in progress")
            return try await refreshTask.value
        }

        let task = Task { () throws -> AuthState in
            defer { refreshTask = nil }

            log.debug("Refreshing SuperTokens session...")

            let refreshed = await sessionBridge.attemptRefresh()
            let sessionExists = await sessionBridge.doesSessionExist()
            let accessToken = try await sessionBridge.getAccessToken()
            guard refreshed || sessionExists else {
                throw AuthenticationError.noAccessTokenPresent
            }

            guard let accessToken else {
                throw AuthenticationError.noAccessTokenPresent
            }
            guard isAccessTokenValid(accessToken) else {
                throw AuthenticationError.serverError(details: "Session refresh did not produce a usable access token")
            }

            log.debug("Successfully refreshed SuperTokens session.")
            return try await syncCompatibilityAuthState(accessToken: accessToken)
        }

        self.refreshTask = task

        return try await task.value
    }

    private func syncCompatibilityAuthState(accessToken: String) async throws -> AuthState {
        // Profile reducers can update userId without updating the authenticator cache.
        // Read, derive, persist and publish from the live store in one main-actor turn.
        return try await MainActor.run {
            let store = Context.currentContext.store
            guard var candidate = store.state else {
                throw AuthenticationError.serverError(details: "Rownd state is unavailable")
            }
            let currentAuthState = candidate.auth
            let isSameSession = SuperTokensSessionBridge.tokensBelongToSameSession(
                currentAuthState.accessToken,
                accessToken
            )
            var newAuthState = isSameSession ? currentAuthState : AuthState(
                hasPreviouslySignedIn: currentAuthState.hasPreviouslySignedIn
            )
            newAuthState.accessToken = accessToken
            newAuthState.refreshToken = nil
            let stableIdentity = SuperTokensSessionBridge.stableSessionIdentity(from: accessToken)
            if !isSameSession {
                newAuthState.profileHydrationPendingSessionIdentity = stableIdentity
            } else if newAuthState.profileHydrationPendingSessionIdentity != stableIdentity {
                newAuthState.profileHydrationPendingSessionIdentity = nil
            }
            newAuthState.hasPreviouslySignedIn = newAuthState.hasPreviouslySignedIn == true
                || newAuthState.isAuthenticated

            candidate.auth = newAuthState
            if !isSameSession {
                candidate.user = UserState()
            }
            guard persistState(candidate) else {
                throw AuthenticationError.serverError(
                    details: "Failed to persist compatibility state for the current SuperTokens session"
                )
            }
            store.dispatch(SetAuthState(payload: newAuthState))
            if !isSameSession {
                store.dispatch(SetUserState(payload: UserState()))
            }
            return newAuthState
        }
    }

    private func isAccessTokenValid(_ accessToken: String) -> Bool {
        guard let jwt = AccessTokenDecoder.decode(accessToken) else {
            return false
        }
        let currentDate = NetworkTimeManager.shared.currentTime ?? Date()
        guard let expiresAt = jwt.expiresAt,
            let currentDateWithMargin = Calendar.current.date(byAdding: .second, value: 60, to: currentDate)
        else {
            return false
        }

        return !jwt.ntpExpired && currentDateWithMargin < expiresAt
    }
}
