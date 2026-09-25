import AnyCodable
import Foundation
import Testing
@testable import Rownd

@Suite(.serialized)
@MainActor
struct AuthIdentityPersistenceTests {
    @Test(arguments: [false, true])
    func profileIdentitySurvivesTokenReadAndRefresh(refresh: Bool) async throws {
        let originalContext = Context.currentContext
        let originalCache = AuthenticatorSubscription.currentAuthState
        let store = createStore()
        _ = Context(store)
        defer {
            Context.currentContext = originalContext
            AuthenticatorSubscription.currentAuthState = originalCache
        }
        let token = generateJwt(expires: Date().addingTimeInterval(3600).timeIntervalSince1970,
                                sessionHandle: "same-session", userId: "user-a")
        let rotated = generateJwt(expires: Date().addingTimeInterval(7200).timeIntervalSince1970,
                                  sessionHandle: "same-session", userId: "user-a")
        store.dispatch(SetAuthState(payload: AuthState(accessToken: token)))
        // Profile hydration changes the store, but the authenticator cache does not observe it.
        store.dispatch(SetUserData(data: ["user_id": AnyCodable("user-a")]))
        #expect(store.state.auth.userId == "user-a")
        #expect(AuthenticatorSubscription.currentAuthState?.userId == nil)
        let bridge = TestSessionBridge(accessToken: token, refreshSucceeds: true, refreshedAccessToken: rotated)
        var persistedUserId: String?
        let auth = Authenticator(sessionBridge: bridge.client, persistState: {
            persistedUserId = $0.auth.userId
            return true
        })
        let result = try await (refresh ? auth.refreshToken() : auth.getValidToken())
        #expect(result.userId == "user-a")
        #expect(store.state.auth.userId == "user-a")
        #expect(AuthenticatorSubscription.currentAuthState?.userId == "user-a")
        #expect(persistedUserId == "user-a")
        #expect(result.accessToken == (refresh ? rotated : token))
    }

    @Test
    func persistedIdentitySurvivesReloadWithoutRestoringSignedOutIdentity() throws {
        let originalContext = Context.currentContext
        let originalCache = AuthenticatorSubscription.currentAuthState
        let store = createStore()
        _ = Context(store)
        defer {
            Context.currentContext = originalContext
            AuthenticatorSubscription.currentAuthState = originalCache
        }
        let token = generateJwt(expires: Date().addingTimeInterval(3600).timeIntervalSince1970,
                                sessionHandle: "persisted-session", userId: "user-a")
        store.dispatch(SetAuthState(payload: AuthState(accessToken: token)))
        store.dispatch(SetUserData(data: ["user_id": AnyCodable("user-a")]))
        let encoded = try JSONEncoder().encode(store.state!)
        let restored = try JSONDecoder().decode(RowndState.self, from: encoded)
        store.dispatch(ReloadRowndState(payload: restored))
        #expect(store.state.auth.userId == "user-a")
        #expect(store.state.auth.isAuthenticated)
        store.dispatch(SetAuthState(payload: AuthState()))
        let signedOut = try JSONDecoder().decode(RowndState.self,
            from: JSONEncoder().encode(store.state!))
        #expect(signedOut.auth.userId == nil)
        #expect(!signedOut.auth.isAuthenticated)
        // Previously persisted states do not contain the new optional field.
        let old = try JSONDecoder().decode(AuthState.self, from: Data("{}".utf8))
        #expect(old.userId == nil)
    }

    @Test
    func replacementSessionClearsPreviousProfile() async throws {
        let originalContext = Context.currentContext
        let originalCache = AuthenticatorSubscription.currentAuthState
        let store = createStore()
        _ = Context(store)
        defer {
            Context.currentContext = originalContext
            AuthenticatorSubscription.currentAuthState = originalCache
        }
        let token = generateJwt(expires: Date().addingTimeInterval(3600).timeIntervalSince1970,
                                sessionHandle: "old-session", userId: "user-a")
        let replacement = generateJwt(expires: Date().addingTimeInterval(3600).timeIntervalSince1970,
                                      sessionHandle: "new-session", userId: "user-b")
        store.dispatch(SetAuthState(payload: AuthState(accessToken: token)))
        store.dispatch(SetUserData(data: ["user_id": AnyCodable("user-a")]))
        let bridge = TestSessionBridge(accessToken: replacement)
        let auth = Authenticator(sessionBridge: bridge.client, persistState: { _ in true })
        let result = try await auth.getValidToken()
        #expect(result.userId == nil)
        #expect(store.state.auth.userId == nil)
        #expect(store.state.user.data.isEmpty)
        #expect(result.accessToken == replacement)
    }

    @Test
    func failedPersistenceDoesNotOverwriteHydratedIdentity() async throws {
        let originalContext = Context.currentContext
        let originalCache = AuthenticatorSubscription.currentAuthState
        let store = createStore()
        _ = Context(store)
        defer {
            Context.currentContext = originalContext
            AuthenticatorSubscription.currentAuthState = originalCache
        }
        let token = generateJwt(expires: Date().addingTimeInterval(3600).timeIntervalSince1970,
                                sessionHandle: "same-session", userId: "user-a")
        store.dispatch(SetAuthState(payload: AuthState(accessToken: token)))
        store.dispatch(SetUserData(data: ["user_id": AnyCodable("user-a")]))
        let bridge = TestSessionBridge(accessToken: token)
        let auth = Authenticator(sessionBridge: bridge.client, persistState: { _ in false })
        await #expect(throws: AuthenticationError.serverError(
            details: "Failed to persist compatibility state for the current SuperTokens session"
        )) { try await auth.getValidToken() }
        #expect(store.state.auth.userId == "user-a")
        #expect(store.state.auth.accessToken == token)
    }

    @Test
    func signedOutSessionDoesNotRestoreCachedIdentity() async throws {
        let originalContext = Context.currentContext
        let originalCache = AuthenticatorSubscription.currentAuthState
        let store = createStore()
        _ = Context(store)
        defer {
            Context.currentContext = originalContext
            AuthenticatorSubscription.currentAuthState = originalCache
        }
        AuthenticatorSubscription.currentAuthState = AuthState(accessToken: "old-token", userId: "user-a")
        let bridge = TestSessionBridge(accessToken: nil, sessionExists: false)
        let auth = Authenticator(sessionBridge: bridge.client, persistState: { _ in true })
        await #expect(throws: AuthenticationError.noAccessTokenPresent) { try await auth.getValidToken() }
        #expect(store.state.auth.userId == nil)
        #expect(!store.state.auth.isAuthenticated)
    }
}
