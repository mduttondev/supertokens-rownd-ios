import Foundation
import Testing
import Network
import AnyCodable
@testable import SuperTokensIOS

@testable import Rownd

@Suite(.serialized) struct SuperTokensSessionBridgeTests {
    private static let supertokensConfig = RowndSuperTokensConfig(
        appName: "Example App",
        apiDomain: "https://api.example.com",
        apiBasePath: "/auth"
    )

    // Every SuperTokens session artifact key, so setup/teardown can guarantee a
    // known-empty starting state. UserDefaults.standard persists on the simulator
    // across test processes, so without this a cold run inherits a prior run's
    // session and the first bootstrap sees a stale "session already exists".
    private static let allSessionKeys = [
        "st-storage-item-st-access-token",
        "st-storage-item-st-refresh-token",
        "supertokens-ios-fronttoken-key",
        "st-storage-item-st-last-access-token-update",
        "st-storage-item-sIRTFrontend",
        "supertokens-ios-anticsrf-key",
    ]

    // The single in-memory store that each harness installs as both the core
    // TokenStorage seam and the bridge storageOverride. Assertions read session
    // artifacts through this rather than UserDefaults.standard, which core purges
    // after every write.
    private static var activeStore = InMemorySessionStore()

    private static func resetToKnownState() {
        SuperTokensSessionBridge.storageOverride = nil
        SuperTokens.resetForTests()
        FrontToken.clearInMemoryCache()
        activeStore.reset()
        for key in allSessionKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    @Test func bootstrapSessionCreatesVisibleSession() async throws {
        try await withMockedSuperTokensSession {
            let accessToken = makeSuperTokensTestJWT(expiresIn: 3600)
            let refreshToken = makeSuperTokensTestJWT(expiresIn: 7200)
            let succeeded = await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: accessToken,
                    refreshToken: refreshToken
                )
            }.value

            #expect(succeeded)
            #expect(await SuperTokensSessionBridge.getAccessToken() == accessToken)
            #expect(Self.activeStore.get("st-storage-item-st-refresh-token") == refreshToken)
            #expect(Self.activeStore.get("supertokens-ios-fronttoken-key") != nil)
            #expect(Self.activeStore.get("st-storage-item-st-last-access-token-update") != nil)
        }
    }

    @Test func hubBootstrapRejectsPermitInvalidatedByLogout() async throws {
        try await withMockedSuperTokensSession {
            let permit = SuperTokensSessionBridge.captureAuthOperationPermit()
            SuperTokensSessionBridge.invalidateAuthOperationPermits()
            let succeeded = await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: makeSuperTokensTestJWT(expiresIn: 3600),
                    refreshToken: makeSuperTokensTestJWT(expiresIn: 7200),
                    permit: permit
                )
            }.value

            #expect(!succeeded)
            #expect(!(await SuperTokensSessionBridge.doesSessionExist()))
            #expect(SuperTokensSessionBridge.getRefreshToken() == nil)
        }
    }

    @Test func hubBootstrapDiscardsSessionWhenLogoutStartsDuringRefresh() async throws {
        try await withMockedSuperTokensSession {
            let original = makeSuperTokensTestJWT(expiresIn: 3600)
            let replacement = makeSuperTokensTestJWT(expiresIn: 1800)
            let permit = SuperTokensSessionBridge.captureAuthOperationPermit()
            let installed = await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: original,
                    refreshToken: makeSuperTokensTestJWT(expiresIn: 7200)
                )
            }.value
            #expect(installed)

            let succeeded = await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: replacement,
                    refreshToken: makeSuperTokensTestJWT(expiresIn: 5400),
                    permit: permit,
                    refreshSession: {
                        SuperTokensSessionBridge.invalidateAuthOperationPermits()
                        return SDKStorage.set("st-storage-item-st-access-token", value: replacement)
                            && FrontToken.setItem(frontToken: SuperTokensSessionBridge.buildFrontToken(from: replacement))
                    }
                )
            }.value

            #expect(!succeeded)
            #expect(!(await SuperTokensSessionBridge.doesSessionExist()))
            #expect(SuperTokensSessionBridge.getRefreshToken() == nil)
        }
    }

    @Test @MainActor func adoptResponseSessionInstallsCompleteSessionAndReturnsExactIdentity() async throws {
        try await withMockedSuperTokensSession {
            let accessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
                sessionHandle: "direct-adoption"
            )
            let refreshToken = makeSuperTokensTestJWT(expiresIn: 7200)
            let frontToken = SuperTokensSessionBridge.buildFrontToken(from: accessToken)

            let permit = SuperTokensSessionBridge.captureAuthOperationPermit()
            let identity = try #require(await SuperTokensSessionBridge.adoptResponseSession(
                SuperTokensSessionTokens(
                    accessToken: accessToken,
                    refreshToken: refreshToken,
                    frontToken: frontToken,
                    antiCSRF: "anti-csrf-token"
                ),
                permit: permit
            ))

            #expect(identity.accessToken == accessToken)
            #expect(identity.stable.sessionHandle == "direct-adoption")
            #expect(await SuperTokensSessionBridge.currentSessionIdentity() == identity)
            #expect(SuperTokensSessionBridge.getRefreshToken() == refreshToken)
            #expect(SuperTokensSessionBridge.getFrontToken() == frontToken)
            #expect(SuperTokensSessionBridge.getAntiCSRF() == "anti-csrf-token")
        }
    }

    @Test func case1StaleQueuedWorkFinishesBeforeS1AndCannotDefeatTheLastInstallation() async throws {
        try await withMockedSuperTokensSession {
            let s0AccessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 1800).timeIntervalSince1970,
                sessionHandle: "case-1-s0"
            )
            let rotatedS0AccessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
                sessionHandle: "case-1-s0"
            )
            let s1AccessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
                sessionHandle: "case-1-s1"
            )
            _ = try #require(await SuperTokensSessionBridge.adoptResponseSession(
                SuperTokensSessionTokens(
                    accessToken: s0AccessToken,
                    refreshToken: "s0-refresh-token",
                    frontToken: SuperTokensSessionBridge.buildFrontToken(from: s0AccessToken),
                    antiCSRF: nil
                ),
                permit: SuperTokensSessionBridge.captureAuthOperationPermit()
            ))
            let staleWorkStarted = DispatchSemaphore(value: 0)
            let releaseStaleWork = DispatchSemaphore(value: 0)

            let staleWork = Task {
                await SuperTokensSessionBridge.attemptRefresh {
                    staleWorkStarted.signal()
                    guard releaseStaleWork.wait(timeout: .now() + 2) == .success else {
                        Issue.record("Timed out releasing stale S0 work")
                        return false
                    }
                    return SDKStorage.set(
                        "st-storage-item-st-access-token",
                        value: rotatedS0AccessToken
                    ) && FrontToken.setItem(
                        frontToken: SuperTokensSessionBridge.buildFrontToken(
                            from: rotatedS0AccessToken
                        )
                    )
                }
            }
            guard await waitForSignal(staleWorkStarted, timeout: 2) else {
                releaseStaleWork.signal()
                _ = await staleWork.value
                Issue.record("Stale S0 work did not start")
                return
            }

            let s1Installation = Task {
                await SuperTokensSessionBridge.adoptResponseSession(
                    SuperTokensSessionTokens(
                        accessToken: s1AccessToken,
                        refreshToken: "s1-refresh-token",
                        frontToken: SuperTokensSessionBridge.buildFrontToken(from: s1AccessToken),
                        antiCSRF: "s1-anti-csrf"
                    ),
                    permit: SuperTokensSessionBridge.captureAuthOperationPermit()
                )
            }
            releaseStaleWork.signal()

            #expect(await staleWork.value)
            let s1Identity = try #require(await s1Installation.value)
            #expect(s1Identity.stable.sessionHandle == "case-1-s1")
            #expect(await SuperTokensSessionBridge.getAccessToken() == s1AccessToken)
            #expect(SuperTokensSessionBridge.getRefreshToken() == "s1-refresh-token")
            #expect(SuperTokensSessionBridge.getAntiCSRF() == "s1-anti-csrf")
        }
    }

    @Test func invalidatedPermitRejectsAdoptionBeforeInstall() async throws {
        try await withMockedSuperTokensSession {
            let accessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
                sessionHandle: "invalidated-before-install"
            )
            let permit = SuperTokensSessionBridge.captureAuthOperationPermit()
            SuperTokensSessionBridge.invalidateAuthOperationPermits()
            var attemptedInstall = false

            let identity = await SuperTokensSessionBridge.adoptResponseSession(
                SuperTokensSessionTokens(
                    accessToken: accessToken,
                    refreshToken: "refresh-token",
                    frontToken: SuperTokensSessionBridge.buildFrontToken(from: accessToken),
                    antiCSRF: nil
                ),
                permit: permit,
                installSession: { _ in
                    attemptedInstall = true
                    return true
                }
            )

            #expect(identity == nil)
            #expect(!attemptedInstall)
            #expect(await !SuperTokensSessionBridge.doesSessionExist())
        }
    }

    @Test func invalidationDuringInstallClearsOnlyInstalledSession() async throws {
        try await withMockedSuperTokensSession {
            let accessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
                sessionHandle: "invalidated-during-install"
            )
            let tokens = SuperTokensSessionTokens(
                accessToken: accessToken,
                refreshToken: "refresh-token",
                frontToken: SuperTokensSessionBridge.buildFrontToken(from: accessToken),
                antiCSRF: nil
            )
            let permit = SuperTokensSessionBridge.captureAuthOperationPermit()

            let identity = await SuperTokensSessionBridge.adoptResponseSession(
                tokens,
                permit: permit,
                installSession: { tokens in
                    let installed = SuperTokens.installSession(
                        accessToken: tokens.accessToken,
                        refreshToken: tokens.refreshToken,
                        frontToken: tokens.frontToken,
                        antiCSRFToken: tokens.antiCSRF
                    )
                    SuperTokensSessionBridge.invalidateAuthOperationPermits()
                    return installed
                }
            )

            #expect(identity == nil)
            #expect(await !SuperTokensSessionBridge.doesSessionExist())
        }
    }

    @Test func discardSessionIfCurrentCannotClearNewerSession() async throws {
        try await withMockedSuperTokensSession {
            let firstAccessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
                sessionHandle: "discard-first"
            )
            let secondAccessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
                sessionHandle: "discard-second"
            )
            let firstIdentity = try #require(await SuperTokensSessionBridge.adoptResponseSession(
                SuperTokensSessionTokens(
                    accessToken: firstAccessToken,
                    refreshToken: "first-refresh-token",
                    frontToken: SuperTokensSessionBridge.buildFrontToken(from: firstAccessToken),
                    antiCSRF: nil
                ),
                permit: SuperTokensSessionBridge.captureAuthOperationPermit()
            ))
            let secondIdentity = try #require(await SuperTokensSessionBridge.adoptResponseSession(
                SuperTokensSessionTokens(
                    accessToken: secondAccessToken,
                    refreshToken: "second-refresh-token",
                    frontToken: SuperTokensSessionBridge.buildFrontToken(from: secondAccessToken),
                    antiCSRF: nil
                ),
                permit: SuperTokensSessionBridge.captureAuthOperationPermit()
            ))

            #expect(await !SuperTokensSessionBridge.discardSessionIfCurrent(firstIdentity))
            #expect(await SuperTokensSessionBridge.getAccessToken() == secondAccessToken)
            #expect(await SuperTokensSessionBridge.discardSessionIfCurrent(secondIdentity))
            #expect(await !SuperTokensSessionBridge.doesSessionExist())
        }
    }

    @Test func discardSessionIfCurrentClearsSameGenerationRotatedToken() async throws {
        try await withMockedSuperTokensSession {
            let originalAccessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 1800).timeIntervalSince1970,
                sessionHandle: "discard-rotated-session"
            )
            let rotatedAccessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
                sessionHandle: "discard-rotated-session"
            )
            let identity = try #require(await SuperTokensSessionBridge.adoptResponseSession(
                SuperTokensSessionTokens(
                    accessToken: originalAccessToken,
                    refreshToken: "refresh-token",
                    frontToken: SuperTokensSessionBridge.buildFrontToken(from: originalAccessToken),
                    antiCSRF: nil
                ),
                permit: SuperTokensSessionBridge.captureAuthOperationPermit()
            ))
            #expect(await SuperTokensSessionBridge.attemptRefresh {
                SDKStorage.set("st-storage-item-st-access-token", value: rotatedAccessToken)
                    && FrontToken.setItem(frontToken: SuperTokensSessionBridge.buildFrontToken(
                        from: rotatedAccessToken
                    ))
            })

            #expect(await SuperTokensSessionBridge.discardSessionIfCurrent(identity))
            #expect(await !SuperTokensSessionBridge.doesSessionExist())
        }
    }

    @Test func discardSessionIfCurrentCannotClearNewerGenerationOfSameStableSession() async throws {
        try await withMockedSuperTokensSession {
            let firstAccessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 1800).timeIntervalSince1970,
                sessionHandle: "discard-same-stable-session"
            )
            let secondAccessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
                sessionHandle: "discard-same-stable-session"
            )
            let firstIdentity = try #require(await SuperTokensSessionBridge.adoptResponseSession(
                SuperTokensSessionTokens(
                    accessToken: firstAccessToken,
                    refreshToken: "first-refresh-token",
                    frontToken: SuperTokensSessionBridge.buildFrontToken(from: firstAccessToken),
                    antiCSRF: nil
                ),
                permit: SuperTokensSessionBridge.captureAuthOperationPermit()
            ))
            let secondIdentity = try #require(await SuperTokensSessionBridge.adoptResponseSession(
                SuperTokensSessionTokens(
                    accessToken: secondAccessToken,
                    refreshToken: "second-refresh-token",
                    frontToken: SuperTokensSessionBridge.buildFrontToken(from: secondAccessToken),
                    antiCSRF: nil
                ),
                permit: SuperTokensSessionBridge.captureAuthOperationPermit()
            ))
            #expect(firstIdentity.stable == secondIdentity.stable)
            #expect(firstIdentity.generation != secondIdentity.generation)

            #expect(await !SuperTokensSessionBridge.discardSessionIfCurrent(firstIdentity))
            #expect(await SuperTokensSessionBridge.getAccessToken() == secondAccessToken)
            #expect(await SuperTokensSessionBridge.discardSessionIfCurrent(secondIdentity))
        }
    }

    @Test func adoptResponseSessionRejectsInvalidIdentityWithoutMutatingSession() async throws {
        try await withMockedSuperTokensSession {
            let originalAccessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
                sessionHandle: "original-adoption",
                userId: "original-user"
            )
            let originalTokens = SuperTokensSessionTokens(
                accessToken: originalAccessToken,
                refreshToken: "original-refresh-token",
                frontToken: SuperTokensSessionBridge.buildFrontToken(from: originalAccessToken),
                antiCSRF: "original-anti-csrf"
            )
            let originalIdentity = try #require(await SuperTokensSessionBridge.adoptResponseSession(
                originalTokens,
                permit: SuperTokensSessionBridge.captureAuthOperationPermit()
            ))
            let differentUserToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
                sessionHandle: "invalid-adoption",
                userId: "different-user"
            )

            let rejected = await SuperTokensSessionBridge.adoptResponseSession(
                SuperTokensSessionTokens(
                    accessToken: differentUserToken,
                    refreshToken: "replacement-refresh-token",
                    frontToken: originalTokens.frontToken,
                    antiCSRF: "replacement-anti-csrf"
                ),
                permit: SuperTokensSessionBridge.captureAuthOperationPermit()
            )

            #expect(rejected == nil)
            #expect(await SuperTokensSessionBridge.currentSessionIdentity() == originalIdentity)
            #expect(SuperTokensSessionBridge.getRefreshToken() == originalTokens.refreshToken)
            #expect(SuperTokensSessionBridge.getFrontToken() == originalTokens.frontToken)
            #expect(SuperTokensSessionBridge.getAntiCSRF() == originalTokens.antiCSRF)
        }
    }

    @Test func authSyncClearsAndPersistsProfileWhenStableSessionChanges() async throws {
        try await withMockedSuperTokensSession {
            let originalContext = Context.currentContext
            let isolatedStore = createStore()
            _ = Context(isolatedStore)
            defer { Context.currentContext = originalContext }

            let oldAccessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
                sessionHandle: "persisted-session"
            )
            let liveAccessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
                sessionHandle: "live-session"
            )
            await MainActor.run {
                isolatedStore.dispatch(SetAuthState(payload: AuthState(accessToken: oldAccessToken)))
                isolatedStore.dispatch(SetUserState(payload: UserState(data: [
                    "email": AnyCodable("stale@example.com")
                ])))
            }
            let liveIdentity = try #require(await SuperTokensSessionBridge.adoptResponseSession(
                SuperTokensSessionTokens(
                    accessToken: liveAccessToken,
                    refreshToken: "live-refresh-token",
                    frontToken: SuperTokensSessionBridge.buildFrontToken(from: liveAccessToken),
                    antiCSRF: nil
                ),
                permit: SuperTokensSessionBridge.captureAuthOperationPermit()
            ))
            let persistedStates = StatePersistenceRecorder()

            let synchronized = await SuperTokensSessionBridge.syncRowndAuthStateFromSuperTokens(
                afterTokenRead: {},
                expectedSessionIdentity: liveIdentity,
                persistState: persistedStates.persist
            )

            #expect(synchronized)
            let snapshots = persistedStates.snapshots
            try #require(snapshots.count == 1)
            #expect(snapshots[0].auth.accessToken == liveAccessToken)
            #expect(snapshots[0].auth.profileHydrationPendingSessionIdentity == liveIdentity.stable)
            #expect(snapshots[0].user.data.isEmpty)
        }
    }

    @Test func authSyncPersistenceFailureLeavesPreviousStateForRetry() async throws {
        try await withMockedSuperTokensSession {
            let originalContext = Context.currentContext
            let isolatedStore = createStore()
            _ = Context(isolatedStore)
            defer { Context.currentContext = originalContext }

            let oldAccessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
                sessionHandle: "failed-persist-old-session"
            )
            let liveAccessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
                sessionHandle: "failed-persist-live-session"
            )
            await MainActor.run {
                isolatedStore.dispatch(SetAuthState(payload: AuthState(accessToken: oldAccessToken)))
                isolatedStore.dispatch(SetUserState(payload: UserState(data: [
                    "email": AnyCodable("preserved@example.com")
                ])))
            }
            #expect(await SuperTokensSessionBridge.adoptResponseSession(
                SuperTokensSessionTokens(
                    accessToken: liveAccessToken,
                    refreshToken: "live-refresh-token",
                    frontToken: SuperTokensSessionBridge.buildFrontToken(from: liveAccessToken),
                    antiCSRF: nil
                ),
                permit: SuperTokensSessionBridge.captureAuthOperationPermit()
            ) != nil)

            #expect(await !SuperTokensSessionBridge.syncRowndAuthStateFromSuperTokens(
                afterTokenRead: {},
                persistState: { _ in false }
            ))
            await MainActor.run {
                #expect(isolatedStore.state.auth.accessToken == oldAccessToken)
                #expect(isolatedStore.state.auth.profileHydrationPendingSessionIdentity == nil)
                #expect(isolatedStore.state.user.data["email"]?.value as? String == "preserved@example.com")
            }

            #expect(await SuperTokensSessionBridge.syncRowndAuthStateFromSuperTokens(
                afterTokenRead: {},
                persistState: { _ in true }
            ))
            await MainActor.run {
                #expect(isolatedStore.state.auth.accessToken == liveAccessToken)
                #expect(isolatedStore.state.auth.profileHydrationPendingSessionIdentity != nil)
                #expect(isolatedStore.state.user.data.isEmpty)
            }
        }
    }

    @Test func coldStartupPreservesProfileForSameStableSessionRotation() async throws {
        try await withMockedSuperTokensSession {
            let originalContext = Context.currentContext
            let isolatedStore = createStore()
            _ = Context(isolatedStore)
            defer { Context.currentContext = originalContext }

            let originalAccessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 1800).timeIntervalSince1970,
                sessionHandle: "rotating-session"
            )
            let rotatedAccessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
                sessionHandle: "rotating-session"
            )
            #expect(await SuperTokensSessionBridge.adoptResponseSession(SuperTokensSessionTokens(
                accessToken: originalAccessToken,
                refreshToken: "refresh-token",
                frontToken: SuperTokensSessionBridge.buildFrontToken(from: originalAccessToken),
                antiCSRF: nil
            ), permit: SuperTokensSessionBridge.captureAuthOperationPermit()) != nil)
            await MainActor.run {
                isolatedStore.dispatch(SetAuthState(payload: AuthState(accessToken: originalAccessToken)))
                isolatedStore.dispatch(SetUserState(payload: UserState(data: [
                    "email": AnyCodable("preserved@example.com")
                ])))
            }
            #expect(await SuperTokensSessionBridge.attemptRefresh {
                SDKStorage.set("st-storage-item-st-access-token", value: rotatedAccessToken)
                    && FrontToken.setItem(frontToken: SuperTokensSessionBridge.buildFrontToken(
                        from: rotatedAccessToken
                    ))
            })

            let persistedStates = StatePersistenceRecorder()
            #expect(await Rownd.reconcileStartupSession(
                persistState: persistedStates.persist
            ))

            let snapshot = try #require(persistedStates.snapshots.first)
            #expect(snapshot.auth.accessToken == rotatedAccessToken)
            #expect(snapshot.auth.profileHydrationPendingSessionIdentity == nil)
            #expect(snapshot.user.data["email"]?.value as? String == "preserved@example.com")
        }
    }

    @Test func coldStartupReplacesPersistedSessionBeforeProfileFetch() async throws {
        try await withMockedSuperTokensSession {
            let originalContext = Context.currentContext
            let isolatedStore = createStore()
            _ = Context(isolatedStore)
            defer { Context.currentContext = originalContext }

            let persistedAccessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
                sessionHandle: "cold-persisted-session"
            )
            let liveAccessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
                sessionHandle: "cold-live-session"
            )
            await MainActor.run {
                isolatedStore.dispatch(SetAuthState(payload: AuthState(
                    accessToken: persistedAccessToken,
                    hasPreviouslySignedIn: true
                )))
                isolatedStore.dispatch(SetUserState(payload: UserState(data: [
                    "email": AnyCodable("persisted@example.com")
                ])))
            }
            #expect(await SuperTokensSessionBridge.adoptResponseSession(SuperTokensSessionTokens(
                accessToken: liveAccessToken,
                refreshToken: "live-refresh-token",
                frontToken: SuperTokensSessionBridge.buildFrontToken(from: liveAccessToken),
                antiCSRF: nil
            ), permit: SuperTokensSessionBridge.captureAuthOperationPermit()) != nil)
            let persistedStates = StatePersistenceRecorder()

            #expect(await Rownd.reconcileStartupSession(
                persistState: persistedStates.persist
            ))

            let durableState = try #require(persistedStates.snapshots.first)
            let liveStableIdentity = try #require(
                SuperTokensSessionBridge.stableSessionIdentity(from: liveAccessToken)
            )
            #expect(durableState.auth.accessToken == liveAccessToken)
            #expect(durableState.auth.profileHydrationPendingSessionIdentity == liveStableIdentity)
            #expect(durableState.auth.hasPreviouslySignedIn == true)
            #expect(durableState.user.data.isEmpty)
        }
    }

    @Test func coldStartupResumesPendingProfileHydration() async throws {
        try await withMockedSuperTokensSession {
            let originalContext = Context.currentContext
            let isolatedStore = createStore()
            _ = Context(isolatedStore)
            defer { Context.currentContext = originalContext }

            let accessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
                sessionHandle: "cold-start-pending-session"
            )
            let stableIdentity = try #require(
                SuperTokensSessionBridge.stableSessionIdentity(from: accessToken)
            )
            await MainActor.run {
                var auth = AuthState(accessToken: accessToken)
                auth.profileHydrationPendingSessionIdentity = stableIdentity
                isolatedStore.dispatch(SetAuthState(payload: auth))
            }
            let recorder = InitialForegroundProfileRecorder()

            await Rownd.fetchInitialForegroundProfileIfNeeded(
                appIsActive: { true },
                fetchUserData: { state in
                    await recorder.recordFetch(state.auth.profileHydrationPendingSessionIdentity)
                    return .profileHydrationStillPending
                },
                scheduleRetry: { outcome in
                    await recorder.recordScheduledOutcome(outcome)
                }
            )

            #expect(await recorder.fetchedIdentity == stableIdentity)
            #expect(await recorder.scheduledOutcome == .profileHydrationStillPending)
        }
    }

    @Test func emailVerificationHubSuppressesAutomaticForegroundProfileHydrationUntilDismissal() async throws {
        try await withGlobalTestLock {
            let originalContext = Context.currentContext
            let originalConfig = Rownd.config
            let originalDisplayHubHandler = Rownd.displayHubHandler
            let isolatedStore = createStore()
            _ = Context(isolatedStore)
            defer {
                Context.currentContext = originalContext
                Rownd.config = originalConfig
                Rownd.displayHubHandler = originalDisplayHubHandler
            }

            let accessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
                sessionHandle: "verification-hub-session"
            )
            let stableIdentity = try #require(
                SuperTokensSessionBridge.stableSessionIdentity(from: accessToken)
            )
            let verificationURL = try #require(URL(
                string: "https://hub.example.com/account/verify-email?token=email-token"
            ))
            await MainActor.run {
                var auth = AuthState(accessToken: accessToken)
                auth.profileHydrationPendingSessionIdentity = stableIdentity
                isolatedStore.dispatch(SetAuthState(payload: auth))
                Rownd.config.pendingHubDeepLinkUrl = verificationURL
            }
            let recorder = InitialForegroundProfileRecorder()

            await fetchInitialForegroundProfile(recorder: recorder)

            #expect(await recorder.fetchCount == 0)
            #expect(await recorder.scheduleCount == 0)

            await MainActor.run {
                Rownd.config.pendingHubDeepLinkUrl = nil
                Rownd.displayHubHandler = nil
                Rownd.openHubDeepLink(verificationURL)
            }
            #expect(await waitUntil {
                await MainActor.run {
                    Rownd.getInstance().bottomSheetController.controller is HubViewController
                }
            })
            await MainActor.run {
                #expect(Rownd.config.consumePendingHubDeepLinkUrl() == verificationURL)
            }

            await fetchInitialForegroundProfile(recorder: recorder)

            #expect(await recorder.fetchCount == 0)
            #expect(await recorder.scheduleCount == 0)

            await MainActor.run {
                Rownd.getInstance().bottomSheetController.viewDidDisappear(false)
            }
            await fetchInitialForegroundProfile(recorder: recorder)

            #expect(await recorder.fetchCount == 1)
            #expect(await recorder.scheduleCount == 1)
        }
    }

    @Test func coldStartNetworkFailureRetriesUntilPendingProfileHydrates() async throws {
        try await withMockedSuperTokensSession {
            let originalContext = Context.currentContext
            let isolatedStore = createStore()
            _ = Context(isolatedStore)
            defer { Context.currentContext = originalContext }

            let accessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
                sessionHandle: "cold-start-network-retry"
            )
            let identity = try #require(await SuperTokensSessionBridge.adoptResponseSession(
                SuperTokensSessionTokens(
                    accessToken: accessToken,
                    refreshToken: "refresh-token",
                    frontToken: SuperTokensSessionBridge.buildFrontToken(from: accessToken),
                    antiCSRF: nil
                ),
                permit: SuperTokensSessionBridge.captureAuthOperationPermit()
            ))
            await MainActor.run {
                var auth = AuthState(accessToken: accessToken)
                auth.profileHydrationPendingSessionIdentity = identity.stable
                isolatedStore.dispatch(SetAuthState(payload: auth))
            }
            let responses = FailingThenSuccessfulProfileSequence()
            let coordinator = ProfileHydrationRetryCoordinator(
                delays: [0, 0, 0],
                sleep: { _ in }
            )

            await Rownd.fetchInitialForegroundProfileIfNeeded(
                appIsActive: { true },
                fetchUserData: { _ in .failed },
                scheduleRetry: { outcome in
                    await UserData.scheduleProfileHydrationRetryIfPending(
                        outcome,
                        coordinator: coordinator,
                        appIsActive: { true },
                        fetchUserData: { _ in try await responses.next() },
                        persistState: { _ in true }
                    )
                }
            )

            await coordinator.waitForCurrentTaskToFinish()
            #expect(await responses.count == 2)
            #expect(await !coordinator.isScheduled(for: identity.stable))
            await MainActor.run {
                #expect(
                    isolatedStore.state.user.data["email"]?.value as? String
                        == "retried@example.com"
                )
                #expect(
                    isolatedStore.state.auth.profileHydrationPendingSessionIdentity == nil
                )
            }
        }
    }

    @Test func ignoredInitialProfileOutcomeDoesNotScheduleDuplicateRetry() async throws {
        try await withMockedSuperTokensSession {
            let originalContext = Context.currentContext
            let isolatedStore = createStore()
            _ = Context(isolatedStore)
            defer { Context.currentContext = originalContext }

            let accessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
                sessionHandle: "ignored-initial-profile"
            )
            let identity = try #require(await SuperTokensSessionBridge.adoptResponseSession(
                SuperTokensSessionTokens(
                    accessToken: accessToken,
                    refreshToken: "refresh-token",
                    frontToken: SuperTokensSessionBridge.buildFrontToken(from: accessToken),
                    antiCSRF: nil
                ),
                permit: SuperTokensSessionBridge.captureAuthOperationPermit()
            ))
            await MainActor.run {
                var auth = AuthState(accessToken: accessToken)
                auth.profileHydrationPendingSessionIdentity = identity.stable
                isolatedStore.dispatch(SetAuthState(payload: auth))
            }
            let coordinator = ProfileHydrationRetryCoordinator(
                delays: [0],
                sleep: { _ in }
            )

            await UserData.scheduleProfileHydrationRetryIfPending(
                .ignored,
                coordinator: coordinator,
                appIsActive: { true },
                fetchUserData: { _ in
                    Issue.record("Ignored foreground work must not schedule another retry")
                    return .notFound
                },
                persistState: { _ in true }
            )

            #expect(await !coordinator.isScheduled(for: identity.stable))
        }
    }

    @Test func coldStartupWithoutLiveSessionClearsPersistedSuperTokensState() async throws {
        try await withMockedSuperTokensSession {
            let originalContext = Context.currentContext
            let isolatedStore = createStore()
            _ = Context(isolatedStore)
            defer { Context.currentContext = originalContext }

            let persistedAccessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
                sessionHandle: "orphaned-session"
            )
            await MainActor.run {
                isolatedStore.dispatch(SetAuthState(payload: AuthState(
                    accessToken: persistedAccessToken,
                    hasPreviouslySignedIn: true
                )))
                isolatedStore.dispatch(SetUserState(payload: UserState(data: [
                    "email": AnyCodable("orphaned@example.com")
                ])))
            }
            let persistedStates = StatePersistenceRecorder()

            #expect(await Rownd.reconcileStartupSession(
                persistState: persistedStates.persist
            ))

            let durableState = try #require(persistedStates.snapshots.first)
            #expect(!durableState.auth.isAuthenticated)
            #expect(durableState.auth.hasPreviouslySignedIn == true)
            #expect(durableState.user.data.isEmpty)
        }
    }

    @Test func coldStartupWithoutLiveSessionPreservesLegacyRowndState() async throws {
        try await withMockedSuperTokensSession {
            let originalContext = Context.currentContext
            let isolatedStore = createStore()
            _ = Context(isolatedStore)
            defer { Context.currentContext = originalContext }

            let legacyAccessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
                appUserId: "legacy-user"
            )
            await MainActor.run {
                isolatedStore.dispatch(SetAuthState(payload: AuthState(
                    accessToken: legacyAccessToken,
                    refreshToken: "legacy-refresh-token"
                )))
                isolatedStore.dispatch(SetUserState(payload: UserState(data: [
                    "email": AnyCodable("legacy@example.com")
                ])))
            }
            let persistedStates = StatePersistenceRecorder()

            #expect(await !Rownd.reconcileStartupSession(
                persistState: persistedStates.persist
            ))

            #expect(persistedStates.snapshots.isEmpty)
            await MainActor.run {
                #expect(isolatedStore.state.auth.accessToken == legacyAccessToken)
                #expect(isolatedStore.state.auth.refreshToken == "legacy-refresh-token")
                #expect(isolatedStore.state.user.data["email"]?.value as? String == "legacy@example.com")
            }
        }
    }

    @Test func bootstrapSessionWithoutRefreshTokenDoesNotCreateSession() async throws {
        try await withMockedSuperTokensSession {
            let accessToken = makeSuperTokensTestJWT(expiresIn: 3600)

            let succeeded = await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(accessToken: accessToken, refreshToken: nil)
            }.value

            #expect(!succeeded)
            #expect(await !SuperTokensSessionBridge.doesSessionExist())
            #expect(await SuperTokensSessionBridge.getAccessToken() == nil)
            #expect(Self.activeStore.get("st-storage-item-st-refresh-token") == nil)
            #expect(Self.activeStore.get("supertokens-ios-fronttoken-key") == nil)
            #expect(Self.activeStore.get("st-storage-item-st-last-access-token-update") == nil)
        }
    }

    @Test func bootstrapSessionRejectsMalformedTokens() async throws {
        try await withMockedSuperTokensSession {
            let succeeded = await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: "not-a-jwt",
                    refreshToken: "refresh-token",
                    frontToken: "not-base64"
                )
            }.value

            #expect(!succeeded)
            #expect(await !SuperTokensSessionBridge.doesSessionExist())
        }
    }

    @Test func bootstrapSessionDoesNotPersistAntiCSRFWithoutRefreshToken() async throws {
        try await withMockedSuperTokensSession {
            let accessToken = makeSuperTokensTestJWT(expiresIn: 3600)

            await Task.detached {
                _ = SuperTokensSessionBridge.bootstrapSession(
                    accessToken: accessToken,
                    refreshToken: nil,
                    antiCSRF: "anti-csrf-token"
                )
            }.value

            #expect(await !SuperTokensSessionBridge.doesSessionExist())
            #expect(Self.activeStore.get("supertokens-ios-anticsrf-key") == nil)
        }
    }

    @Test func localArtifactGettersReturnPersistedSessionValues() async throws {
        try await withMockedSuperTokensSession {
            let accessToken = makeSuperTokensTestJWT(expiresIn: 3600)
            let refreshToken = makeSuperTokensTestJWT(expiresIn: 7200)
            let frontToken = SuperTokensSessionBridge.buildFrontToken(from: accessToken)

            await Task.detached {
                _ = SuperTokensSessionBridge.bootstrapSession(
                    accessToken: accessToken,
                    refreshToken: refreshToken,
                    frontToken: frontToken,
                    antiCSRF: "anti-csrf-token"
                )
            }.value

            #expect(SuperTokensSessionBridge.getRefreshToken() == refreshToken)
            #expect(SuperTokensSessionBridge.getFrontToken() == frontToken)
            #expect(SuperTokensSessionBridge.getAntiCSRF() == "anti-csrf-token")
        }
    }

    @Test func bootstrapSessionReplacesExistingSession() async throws {
        try await withMockedSuperTokensSession {
            let originalAccessToken = makeSuperTokensTestJWT(expiresIn: 3600)
            let originalRefreshToken = makeSuperTokensTestJWT(expiresIn: 7200)
            let replacementAccessToken = makeSuperTokensTestJWT(expiresIn: 1800)
            let replacementRefreshToken = makeSuperTokensTestJWT(expiresIn: 5400)
            let replacementFrontToken = SuperTokensSessionBridge.buildFrontToken(from: replacementAccessToken)

            await Task.detached {
                _ = SuperTokensSessionBridge.bootstrapSession(
                    accessToken: originalAccessToken,
                    refreshToken: originalRefreshToken
                )
            }.value

            let originalFrontToken = Self.activeStore.get("supertokens-ios-fronttoken-key")

            let succeeded = await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: replacementAccessToken,
                    refreshToken: replacementRefreshToken,
                    refreshSession: {
                        guard SDKStorage.set("st-storage-item-st-access-token", value: replacementAccessToken),
                              FrontToken.setItem(frontToken: replacementFrontToken) else {
                            return false
                        }
                        return true
                    }
                )
            }.value

            #expect(succeeded)
            #expect(await SuperTokensSessionBridge.getAccessToken() == replacementAccessToken)
            #expect(Self.activeStore.get("st-storage-item-st-refresh-token") == replacementRefreshToken)
            #expect(Self.activeStore.get("supertokens-ios-fronttoken-key") != originalFrontToken)
        }
    }

    @Test func bootstrapSessionCanRejectReplacingExistingSession() async throws {
        try await withMockedSuperTokensSession {
            let originalAccessToken = makeSuperTokensTestJWT(expiresIn: 3600)
            let originalRefreshToken = makeSuperTokensTestJWT(expiresIn: 7200)

            let initialSucceeded = await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: originalAccessToken,
                    refreshToken: originalRefreshToken
                )
            }.value
            let replacementSucceeded = await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: makeSuperTokensTestJWT(expiresIn: 1800),
                    refreshToken: makeSuperTokensTestJWT(expiresIn: 5400),
                    allowReplacingExistingSession: false,
                    refreshSession: {
                        Issue.record("Replacement must not refresh the existing session")
                        return true
                    }
                )
            }.value

            #expect(initialSucceeded)
            #expect(!replacementSucceeded)
            #expect(await SuperTokensSessionBridge.getAccessToken() == originalAccessToken)
            #expect(SuperTokensSessionBridge.getRefreshToken() == originalRefreshToken)
        }
    }

    @Test func bootstrapSessionWithSameAccessTokenIsIdempotentSuccess() async throws {
        try await withMockedSuperTokensSession {
            let accessToken = makeSuperTokensTestJWT(expiresIn: 3600)
            let refreshToken = makeSuperTokensTestJWT(expiresIn: 7200)

            let firstSucceeded = await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: accessToken,
                    refreshToken: refreshToken,
                    antiCSRF: "original-anti-csrf"
                )
            }.value
            let secondSucceeded = await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: accessToken,
                    refreshToken: "different-refresh-token",
                    antiCSRF: "different-anti-csrf"
                )
            }.value

            #expect(firstSucceeded)
            #expect(secondSucceeded)
            #expect(Self.activeStore.get("st-storage-item-st-refresh-token") == refreshToken)
            #expect(Self.activeStore.get("supertokens-ios-anticsrf-key") == "original-anti-csrf")
        }
    }

    @Test func bootstrapSessionFailureRestoresExistingSession() async throws {
        try await withMockedSuperTokensSession {
            let storage = FailingSessionStorage()
            let previousStorage = SuperTokensSessionBridge.storageOverride
            SDKStorage.setTokenStorageForTests(storage)
            SuperTokensSessionBridge.storageOverride = storage
            defer {
                SuperTokensSessionBridge.storageOverride = previousStorage
            }

            let originalAccessToken = makeSuperTokensTestJWT(expiresIn: 3600)
            let originalRefreshToken = makeSuperTokensTestJWT(expiresIn: 7200)
            let initialSucceeded = await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: originalAccessToken,
                    refreshToken: originalRefreshToken
                )
            }.value
            storage.failingKey = "st-storage-item-st-refresh-token"

            let replacementSucceeded = await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: makeSuperTokensTestJWT(expiresIn: 1800),
                    refreshToken: makeSuperTokensTestJWT(expiresIn: 5400)
                )
            }.value

            #expect(initialSucceeded)
            #expect(!replacementSucceeded)
            #expect(await SuperTokensSessionBridge.getAccessToken() == originalAccessToken)
            #expect(storage.get("st-storage-item-st-refresh-token") == originalRefreshToken)
        }
    }

    @Test func attemptRefreshReturnsFalseWhenNoSessionExists() async throws {
        try await withMockedSuperTokensSession {
            #expect(await !SuperTokensSessionBridge.doesSessionExist())
            #expect(await !SuperTokensSessionBridge.attemptRefresh())
        }
    }

    @Test func bridgeMethodsCanBeCalledFromMainActorWithoutDeadlock() async throws {
        try await withMockedSuperTokensSession {
            try await expectCompletesWithinOneSecond {
                await callBlockingBridgeMethodsFromMainActor()
            }
        }
    }

    @Test func buildFrontTokenEncodesExpectedClaims() async throws {
        try await withGlobalTestLock {
            let accessToken = makeSuperTokensTestJWT(expiresIn: 3600)
            let frontToken = SuperTokensSessionBridge.buildFrontToken(from: accessToken)
            let decodedData = try #require(Data(base64Encoded: frontToken))
            let decodedObject = try #require(
                try JSONSerialization.jsonObject(with: decodedData) as? [String: Any]
            )

            #expect(decodedObject["uid"] as? String == "1234567890")
            #expect((decodedObject["ate"] as? Int64 ?? 0) > 0)
            #expect(decodedObject["up"] as? [String: Any] != nil)
        }
    }

    @Test func bridgeSignOutClearsLocalSessionStateBeforeReturning() async throws {
        try await withMockedSuperTokensSession {
            let accessToken = makeSuperTokensTestJWT(expiresIn: 3600)
            let refreshToken = makeSuperTokensTestJWT(expiresIn: 7200)

            await Task.detached {
                _ = SuperTokensSessionBridge.bootstrapSession(
                    accessToken: accessToken,
                    refreshToken: refreshToken
                )
            }.value

            #expect(await SuperTokensSessionBridge.getAccessToken() == accessToken)
            #expect(Self.activeStore.get("st-storage-item-st-refresh-token") == refreshToken)

            await SuperTokensSessionBridge.signOut()

            #expect(await !SuperTokensSessionBridge.doesSessionExist())
            #expect(await SuperTokensSessionBridge.getAccessToken() == nil)
            #expect(Self.activeStore.get("supertokens-ios-fronttoken-key") == nil)
        }
    }

    @Test func conditionalSignOutCannotClearReplacementInstalledAfterSuperTokensClear() async throws {
        try await withMockedSuperTokensSession {
            let originalContext = Context.currentContext
            let isolatedStore = createStore()
            _ = Context(isolatedStore)
            defer { Context.currentContext = originalContext }

            let originalAccessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
                sessionHandle: "profile-404-session"
            )
            let replacementAccessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
                sessionHandle: "replacement-session"
            )
            #expect(await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: originalAccessToken,
                    refreshToken: makeSuperTokensTestJWT(expiresIn: 7200)
                )
            }.value)
            await MainActor.run {
                isolatedStore.dispatch(SetAuthState(payload: AuthState(
                    accessToken: originalAccessToken
                )))
            }
            let originalIdentity = try #require(
                await SuperTokensSessionBridge.currentSessionIdentity(matching: originalAccessToken)
            )

            let didClearRowndState = await SuperTokensSessionBridge.signOutIfCurrentSession(
                originalIdentity,
                expectedRowndAccessToken: originalAccessToken,
                afterSuperTokensSignOut: {
                    #expect(await Task.detached {
                        SuperTokensSessionBridge.bootstrapSession(
                            accessToken: replacementAccessToken,
                            refreshToken: makeSuperTokensTestJWT(expiresIn: 7200)
                        )
                    }.value)
                    await MainActor.run {
                        isolatedStore.dispatch(SetAuthState(payload: AuthState(
                            accessToken: replacementAccessToken
                        )))
                        isolatedStore.dispatch(SetUserState(payload: UserState(data: [
                            "email": AnyCodable("replacement@example.com")
                        ])))
                    }
                }
            )

            #expect(!didClearRowndState)
            #expect(await SuperTokensSessionBridge.getAccessToken() == replacementAccessToken)
            await MainActor.run {
                #expect(isolatedStore.state.auth.accessToken == replacementAccessToken)
                #expect(isolatedStore.state.user.data["email"]?.value as? String == "replacement@example.com")
            }
        }
    }

    @Test func replacementStateSyncPersistsClearedCacheBeforeCanonicalProfile() async throws {
        try await withMockedSuperTokensSession {
            let originalContext = Context.currentContext
            let isolatedStore = createStore()
            _ = Context(isolatedStore)
            defer { Context.currentContext = originalContext }

            let oldAccessToken = makeSuperTokensTestJWT(expiresIn: 3600)
            let replacementAccessToken = makeSuperTokensTestJWT(expiresIn: 1800)
            await MainActor.run {
                isolatedStore.dispatch(SetAuthState(payload: AuthState(accessToken: oldAccessToken)))
                isolatedStore.dispatch(SetUserState(payload: UserState(data: [
                    "email": AnyCodable("stale@example.com")
                ])))
            }
            #expect(await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: replacementAccessToken,
                    refreshToken: makeSuperTokensTestJWT(expiresIn: 5400)
                )
            }.value)

            let persistedStates = StatePersistenceRecorder()
            let outcome = try await SuperTokensSessionBridge.syncReplacementRowndStateFromSuperTokens(
                expectedAccessToken: replacementAccessToken,
                expectedPreviousRowndAccessToken: oldAccessToken,
                fetchUserData: { state in
                    #expect(state.auth.accessToken == replacementAccessToken)
                    #expect(state.user.data.isEmpty)
                    return UserStateResponse(data: [
                        "email": AnyCodable("verified@example.com")
                    ])
                },
                persistState: persistedStates.persist
            )

            #expect(outcome == .profileSynchronized)
            let snapshots = persistedStates.snapshots
            try #require(snapshots.count == 2)
            #expect(snapshots[0].auth.accessToken == replacementAccessToken)
            #expect(snapshots[0].user.data.isEmpty)
            #expect(snapshots[1].auth.accessToken == replacementAccessToken)
            #expect(snapshots[1].user.data["email"]?.value as? String == "verified@example.com")
        }
    }

    @Test func alreadySynchronizedReplacementAuthMetadataSurvivesProfileCommit() async throws {
        try await withMockedSuperTokensSession {
            let originalContext = Context.currentContext
            let isolatedStore = createStore()
            _ = Context(isolatedStore)
            defer { Context.currentContext = originalContext }

            let replacementAccessToken = makeSuperTokensTestJWT(expiresIn: 1800)
            #expect(await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: replacementAccessToken,
                    refreshToken: makeSuperTokensTestJWT(expiresIn: 5400)
                )
            }.value)
            await MainActor.run {
                isolatedStore.dispatch(SetAuthState(payload: AuthState(
                    accessToken: replacementAccessToken,
                    isVerifiedUser: true,
                    challengeId: "preserved-challenge",
                    userIdentifier: "preserved@example.com"
                )))
            }

            let outcome = try await SuperTokensSessionBridge.syncReplacementRowndStateFromSuperTokens(
                expectedAccessToken: replacementAccessToken,
                expectedPreviousRowndAccessToken: "old-access-token",
                fetchUserData: { _ in
                    UserStateResponse(data: ["email": AnyCodable("verified@example.com")])
                }
            )

            #expect(outcome == .profileSynchronized)
            await MainActor.run {
                #expect(isolatedStore.state.auth.accessToken == replacementAccessToken)
                #expect(isolatedStore.state.auth.isVerifiedUser == true)
                #expect(isolatedStore.state.auth.challengeId == "preserved-challenge")
                #expect(isolatedStore.state.auth.userIdentifier == "preserved@example.com")
            }
        }
    }

    @Test func replacementStateSyncKeepsDurableAuthAndInvalidatesProfileWhenFetchFails() async throws {
        try await withMockedSuperTokensSession {
            let originalContext = Context.currentContext
            let isolatedStore = createStore()
            _ = Context(isolatedStore)
            defer { Context.currentContext = originalContext }

            let replacementAccessToken = makeSuperTokensTestJWT(expiresIn: 1800)
            await MainActor.run {
                isolatedStore.dispatch(SetAuthState(payload: AuthState(accessToken: "old-access-token")))
                isolatedStore.dispatch(SetUserState(payload: UserState(data: [
                    "email": AnyCodable("stale@example.com")
                ])))
            }
            #expect(await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: replacementAccessToken,
                    refreshToken: makeSuperTokensTestJWT(expiresIn: 5400)
                )
            }.value)

            let persistedStates = StatePersistenceRecorder()
            let outcome = try await SuperTokensSessionBridge.syncReplacementRowndStateFromSuperTokens(
                expectedAccessToken: replacementAccessToken,
                expectedPreviousRowndAccessToken: "old-access-token",
                fetchUserData: { _ in throw ReplacementProfileTestError.unavailable },
                persistState: persistedStates.persist
            )

            #expect(outcome == .profileUnavailable)
            let snapshots = persistedStates.snapshots
            try #require(snapshots.count == 1)
            #expect(snapshots[0].auth.accessToken == replacementAccessToken)
            #expect(snapshots[0].user.data.isEmpty)
            await MainActor.run {
                #expect(isolatedStore.state.auth.accessToken == replacementAccessToken)
                #expect(isolatedStore.state.user.data.isEmpty)
            }
        }
    }

    @Test func replacementStateSyncTreatsAuthPersistenceFailureAsHardError() async throws {
        try await withMockedSuperTokensSession {
            let originalContext = Context.currentContext
            let isolatedStore = createStore()
            _ = Context(isolatedStore)
            defer { Context.currentContext = originalContext }

            let replacementAccessToken = makeSuperTokensTestJWT(expiresIn: 1800)
            #expect(await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: replacementAccessToken,
                    refreshToken: makeSuperTokensTestJWT(expiresIn: 5400)
                )
            }.value)

            await #expect(throws: (any Error).self) {
                try await SuperTokensSessionBridge.syncReplacementRowndStateFromSuperTokens(
                    expectedAccessToken: replacementAccessToken,
                    expectedPreviousRowndAccessToken: nil,
                    fetchUserData: { _ in
                        Issue.record("Profile fetch must not start before replacement auth is durable")
                        return UserStateResponse()
                    },
                    persistState: { _ in false }
                )
            }
        }
    }

    @Test func staleReplacementSyncCannotMutateNewerSignedInAccount() async throws {
        try await withMockedSuperTokensSession {
            let originalContext = Context.currentContext
            let isolatedStore = createStore()
            _ = Context(isolatedStore)
            defer { Context.currentContext = originalContext }

            let staleAccessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 1800).timeIntervalSince1970,
                sessionHandle: "stale-verification-session"
            )
            let newerAccessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 1200).timeIntervalSince1970,
                sessionHandle: "newer-sign-in-session"
            )
            #expect(await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: newerAccessToken,
                    refreshToken: makeSuperTokensTestJWT(expiresIn: 5400)
                )
            }.value)
            await MainActor.run {
                isolatedStore.dispatch(SetAuthState(payload: AuthState(accessToken: newerAccessToken)))
                isolatedStore.dispatch(SetUserState(payload: UserState(data: [
                    "email": AnyCodable("newer@example.com")
                ])))
            }

            let persistedStates = StatePersistenceRecorder()
            await #expect(throws: (any Error).self) {
                try await SuperTokensSessionBridge.syncReplacementRowndStateFromSuperTokens(
                    expectedAccessToken: staleAccessToken,
                    expectedPreviousRowndAccessToken: "old-access-token",
                    fetchUserData: { _ in
                        Issue.record("A superseded verification must not fetch a profile")
                        return UserStateResponse()
                    },
                    persistState: persistedStates.persist
                )
            }

            #expect(persistedStates.snapshots.isEmpty)
            await MainActor.run {
                #expect(isolatedStore.state.auth.accessToken == newerAccessToken)
                #expect(isolatedStore.state.user.data["email"]?.value as? String == "newer@example.com")
            }
        }
    }

    @Test func replacementSyncRejectsUnexpectedRowndAccountBeforeMutation() async throws {
        try await withMockedSuperTokensSession {
            let originalContext = Context.currentContext
            let isolatedStore = createStore()
            _ = Context(isolatedStore)
            defer { Context.currentContext = originalContext }

            let replacementAccessToken = makeSuperTokensTestJWT(expiresIn: 1800)
            #expect(await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: replacementAccessToken,
                    refreshToken: makeSuperTokensTestJWT(expiresIn: 5400)
                )
            }.value)
            await MainActor.run {
                isolatedStore.dispatch(SetAuthState(payload: AuthState(accessToken: "newer-rownd-token")))
                isolatedStore.dispatch(SetUserState(payload: UserState(data: [
                    "email": AnyCodable("newer@example.com")
                ])))
            }

            let persistedStates = StatePersistenceRecorder()
            await #expect(throws: (any Error).self) {
                try await SuperTokensSessionBridge.syncReplacementRowndStateFromSuperTokens(
                    expectedAccessToken: replacementAccessToken,
                    expectedPreviousRowndAccessToken: "old-access-token",
                    fetchUserData: { _ in
                        Issue.record("An unexpected Rownd account must prevent profile fetch")
                        return UserStateResponse()
                    },
                    persistState: persistedStates.persist
                )
            }

            #expect(persistedStates.snapshots.isEmpty)
            await MainActor.run {
                #expect(isolatedStore.state.auth.accessToken == "newer-rownd-token")
                #expect(isolatedStore.state.user.data["email"]?.value as? String == "newer@example.com")
            }
        }
    }

    @Test func replacementSyncAcceptsPreviousSessionTokenRotation() async throws {
        try await withMockedSuperTokensSession {
            let originalContext = Context.currentContext
            let isolatedStore = createStore()
            _ = Context(isolatedStore)
            defer { Context.currentContext = originalContext }

            let previousAccessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
                sessionHandle: "previous-session"
            )
            let rotatedPreviousAccessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 3500).timeIntervalSince1970,
                sessionHandle: "previous-session"
            )
            let replacementAccessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 1800).timeIntervalSince1970,
                sessionHandle: "replacement-session"
            )
            await MainActor.run {
                isolatedStore.dispatch(SetAuthState(payload: AuthState(
                    accessToken: rotatedPreviousAccessToken
                )))
            }
            #expect(await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: replacementAccessToken,
                    refreshToken: makeSuperTokensTestJWT(expiresIn: 5400)
                )
            }.value)

            let outcome = try await SuperTokensSessionBridge.syncReplacementRowndStateFromSuperTokens(
                expectedAccessToken: replacementAccessToken,
                expectedPreviousRowndAccessToken: previousAccessToken,
                fetchUserData: { _ in
                    UserStateResponse(data: ["email": AnyCodable("verified@example.com")])
                }
            )

            #expect(outcome == .profileSynchronized)
            await MainActor.run {
                #expect(isolatedStore.state.auth.accessToken == replacementAccessToken)
                #expect(isolatedStore.state.user.data["email"]?.value as? String == "verified@example.com")
            }
        }
    }

    @Test func replacementSyncRejectsDifferentSessionForSameUser() async throws {
        try await withMockedSuperTokensSession {
            let originalContext = Context.currentContext
            let isolatedStore = createStore()
            _ = Context(isolatedStore)
            defer { Context.currentContext = originalContext }

            let previousAccessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
                sessionHandle: "previous-session"
            )
            let newerAccessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 3500).timeIntervalSince1970,
                sessionHandle: "newer-session"
            )
            let replacementAccessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 1800).timeIntervalSince1970,
                sessionHandle: "replacement-session"
            )
            await MainActor.run {
                isolatedStore.dispatch(SetAuthState(payload: AuthState(accessToken: newerAccessToken)))
            }
            #expect(await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: replacementAccessToken,
                    refreshToken: makeSuperTokensTestJWT(expiresIn: 5400)
                )
            }.value)

            await #expect(throws: (any Error).self) {
                try await SuperTokensSessionBridge.syncReplacementRowndStateFromSuperTokens(
                    expectedAccessToken: replacementAccessToken,
                    expectedPreviousRowndAccessToken: previousAccessToken,
                    fetchUserData: { _ in
                        Issue.record("A newer session must prevent profile fetch")
                        return UserStateResponse()
                    }
                )
            }

            await MainActor.run {
                #expect(isolatedStore.state.auth.accessToken == newerAccessToken)
            }
        }
    }

    @Test func newSignInDuringReplacementProfileFetchCannotBeOverwritten() async throws {
        try await withMockedSuperTokensSession {
            let originalContext = Context.currentContext
            let isolatedStore = createStore()
            _ = Context(isolatedStore)
            defer { Context.currentContext = originalContext }

            let replacementAccessToken = makeSuperTokensTestJWT(expiresIn: 1800)
            let newerAccessToken = makeSuperTokensTestJWT(expiresIn: 1200)
            await MainActor.run {
                isolatedStore.dispatch(SetAuthState(payload: AuthState(accessToken: "old-access-token")))
            }
            #expect(await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: replacementAccessToken,
                    refreshToken: makeSuperTokensTestJWT(expiresIn: 5400)
                )
            }.value)

            let persistedStates = StatePersistenceRecorder()
            await #expect(throws: (any Error).self) {
                try await SuperTokensSessionBridge.syncReplacementRowndStateFromSuperTokens(
                    expectedAccessToken: replacementAccessToken,
                    expectedPreviousRowndAccessToken: "old-access-token",
                    fetchUserData: { _ in
                        let replaced = await Task.detached {
                            SuperTokensSessionBridge.bootstrapSession(
                                accessToken: newerAccessToken,
                                refreshToken: makeSuperTokensTestJWT(expiresIn: 4800),
                                refreshSession: {
                                    SDKStorage.set(
                                        "st-storage-item-st-access-token",
                                        value: newerAccessToken
                                    ) && FrontToken.setItem(
                                        frontToken: SuperTokensSessionBridge.buildFrontToken(
                                            from: newerAccessToken
                                        )
                                    )
                                }
                            )
                        }.value
                        #expect(replaced)
                        await MainActor.run {
                            isolatedStore.dispatch(SetAuthState(payload: AuthState(
                                accessToken: newerAccessToken
                            )))
                            isolatedStore.dispatch(SetUserState(payload: UserState(data: [
                                "email": AnyCodable("newer@example.com")
                            ])))
                        }
                        return UserStateResponse(data: [
                            "email": AnyCodable("stale-verification@example.com")
                        ])
                    },
                    persistState: persistedStates.persist
                )
            }

            let snapshots = persistedStates.snapshots
            try #require(snapshots.count == 1)
            #expect(snapshots[0].auth.accessToken == replacementAccessToken)
            #expect(snapshots[0].user.data.isEmpty)
            await MainActor.run {
                #expect(isolatedStore.state.auth.accessToken == newerAccessToken)
                #expect(isolatedStore.state.user.data["email"]?.value as? String == "newer@example.com")
            }
        }
    }

    @Test func signOutDuringReplacementProfileFetchCannotRestoreVerifiedSession() async throws {
        try await withMockedSuperTokensSession {
            let originalContext = Context.currentContext
            let isolatedStore = createStore()
            _ = Context(isolatedStore)
            defer { Context.currentContext = originalContext }

            let replacementAccessToken = makeSuperTokensTestJWT(expiresIn: 1800)
            await MainActor.run {
                isolatedStore.dispatch(SetAuthState(payload: AuthState(accessToken: "old-access-token")))
            }
            #expect(await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: replacementAccessToken,
                    refreshToken: makeSuperTokensTestJWT(expiresIn: 5400)
                )
            }.value)

            await #expect(throws: (any Error).self) {
                try await SuperTokensSessionBridge.syncReplacementRowndStateFromSuperTokens(
                    expectedAccessToken: replacementAccessToken,
                    expectedPreviousRowndAccessToken: "old-access-token",
                    fetchUserData: { _ in
                        await SuperTokensSessionBridge.signOut()
                        await MainActor.run {
                            isolatedStore.dispatch(SetAuthState(payload: AuthState()))
                        }
                        return UserStateResponse(data: [
                            "email": AnyCodable("stale-verification@example.com")
                        ])
                    }
                )
            }

            #expect(await !SuperTokensSessionBridge.doesSessionExist())
            await MainActor.run {
                #expect(!isolatedStore.state.auth.isAuthenticated)
                #expect(isolatedStore.state.user.data.isEmpty)
            }
        }
    }

    @Test func replacementProfileNotFoundRetainsExactReplacementSession() async throws {
        try await withMockedSuperTokensSession {
            let originalContext = Context.currentContext
            let isolatedStore = createStore()
            _ = Context(isolatedStore)
            defer { Context.currentContext = originalContext }

            let replacementAccessToken = makeSuperTokensTestJWT(expiresIn: 1800)
            await MainActor.run {
                isolatedStore.dispatch(SetAuthState(payload: AuthState(accessToken: "old-access-token")))
                isolatedStore.dispatch(SetUserState(payload: UserState(data: [
                    "email": AnyCodable("stale@example.com")
                ])))
            }
            #expect(await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: replacementAccessToken,
                    refreshToken: makeSuperTokensTestJWT(expiresIn: 5400)
                )
            }.value)

            let outcome = try await SuperTokensSessionBridge.syncReplacementRowndStateFromSuperTokens(
                expectedAccessToken: replacementAccessToken,
                expectedPreviousRowndAccessToken: "old-access-token",
                fetchUserData: { _ in nil }
            )

            #expect(outcome == .profileUnavailable)
            #expect(await SuperTokensSessionBridge.getAccessToken() == replacementAccessToken)
            await MainActor.run {
                #expect(isolatedStore.state.auth.accessToken == replacementAccessToken)
                #expect(isolatedStore.state.user.data.isEmpty)
            }
        }
    }

    @Test func pendingReplacementProfileSurvivesRestartAndForeground404UntilCanonicalHydration() async throws {
        try await withMockedSuperTokensSession {
            let originalContext = Context.currentContext
            let initialStore = createStore()
            _ = Context(initialStore)
            defer { Context.currentContext = originalContext }

            let replacementAccessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 1800).timeIntervalSince1970,
                sessionHandle: "pending-replacement-session"
            )
            await MainActor.run {
                initialStore.dispatch(SetAuthState(payload: AuthState(accessToken: "old-access-token")))
                initialStore.dispatch(SetUserState(payload: UserState(data: [
                    "email": AnyCodable("stale@example.com")
                ])))
            }
            #expect(await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: replacementAccessToken,
                    refreshToken: makeSuperTokensTestJWT(expiresIn: 5400)
                )
            }.value)

            let replacementOutcome = try await SuperTokensSessionBridge
                .syncReplacementRowndStateFromSuperTokens(
                    expectedAccessToken: replacementAccessToken,
                    expectedPreviousRowndAccessToken: "old-access-token",
                    fetchUserData: { _ in nil },
                    persistState: { _ in true }
                )
            #expect(replacementOutcome == .profileUnavailable)

            let encodedState = try #require(try initialStore.state.toJson()?.data(using: .utf8))
            let restartedState = try JSONDecoder().decode(RowndState.self, from: encodedState)
            let restartedStore = createStore()
            _ = Context(restartedStore)
            await MainActor.run {
                restartedStore.dispatch(InitializeRowndState(payload: restartedState))
            }
            let stableIdentity = try #require(
                SuperTokensSessionBridge.stableSessionIdentity(from: replacementAccessToken)
            )
            await MainActor.run {
                #expect(
                    restartedStore.state.auth.profileHydrationPendingSessionIdentity
                        == stableIdentity
                )
                #expect(restartedStore.state.user.data.isEmpty)
            }

            let unavailableOutcome = await UserData.fetchForegroundUserData(
                restartedStore.state,
                fetchUserData: { _ in .notFound },
                persistState: { _ in true }
            )
            #expect(unavailableOutcome == .profileHydrationStillPending)
            #expect(await SuperTokensSessionBridge.getAccessToken() == replacementAccessToken)
            await MainActor.run {
                #expect(restartedStore.state.auth.isAuthenticated)
                #expect(
                    restartedStore.state.auth.profileHydrationPendingSessionIdentity
                        == stableIdentity
                )
            }

            let failedPersistenceOutcome = await UserData.fetchForegroundUserData(
                restartedStore.state,
                fetchUserData: { _ in
                    .profile(UserStateResponse(data: [
                        "email": AnyCodable("not-durable@example.com")
                    ]))
                },
                persistState: { _ in false }
            )
            #expect(failedPersistenceOutcome == .failed)
            await MainActor.run {
                #expect(
                    restartedStore.state.auth.profileHydrationPendingSessionIdentity
                        == stableIdentity
                )
                #expect(restartedStore.state.user.data.isEmpty)
            }

            let hydratedOutcome = await UserData.fetchForegroundUserData(
                restartedStore.state,
                fetchUserData: { state in
                    #expect(state.auth.accessToken == replacementAccessToken)
                    return .profile(UserStateResponse(data: [
                        "email": AnyCodable("canonical@example.com")
                    ]))
                },
                persistState: { _ in true }
            )
            #expect(hydratedOutcome == .profileSynchronized)
            await MainActor.run {
                #expect(restartedStore.state.auth.accessToken == replacementAccessToken)
                #expect(
                    restartedStore.state.auth.profileHydrationPendingSessionIdentity == nil
                )
                #expect(
                    restartedStore.state.user.data["email"]?.value as? String
                        == "canonical@example.com"
                )
            }
        }
    }

    @Test func foregroundFetchSynchronizesSameSessionTokenRotationBeforeFetchAndCommit() async throws {
        try await withMockedSuperTokensSession {
            let originalContext = Context.currentContext
            let isolatedStore = createStore()
            _ = Context(isolatedStore)
            defer { Context.currentContext = originalContext }

            let originalAccessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 1800).timeIntervalSince1970,
                sessionHandle: "foreground-rotation-session"
            )
            let rotatedAccessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
                sessionHandle: "foreground-rotation-session"
            )
            #expect(await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: originalAccessToken,
                    refreshToken: makeSuperTokensTestJWT(expiresIn: 5400)
                )
            }.value)
            await MainActor.run {
                isolatedStore.dispatch(SetAuthState(payload: AuthState(
                    accessToken: originalAccessToken
                )))
            }
            let staleState = try #require(isolatedStore.state)
            #expect(await SuperTokensSessionBridge.attemptRefresh {
                SDKStorage.set("st-storage-item-st-access-token", value: rotatedAccessToken)
                    && FrontToken.setItem(frontToken: SuperTokensSessionBridge.buildFrontToken(
                        from: rotatedAccessToken
                    ))
            })

            let persistedStates = StatePersistenceRecorder()
            let outcome = await UserData.fetchForegroundUserData(
                staleState,
                fetchUserData: { state in
                    #expect(state.auth.accessToken == rotatedAccessToken)
                    return .profile(UserStateResponse(data: [
                        "email": AnyCodable("rotated@example.com")
                    ]))
                },
                persistState: persistedStates.persist
            )

            #expect(outcome == .profileSynchronized)
            let snapshots = persistedStates.snapshots
            try #require(snapshots.count == 2)
            #expect(snapshots[0].auth.accessToken == rotatedAccessToken)
            #expect(snapshots[1].auth.accessToken == rotatedAccessToken)
            #expect(
                snapshots[1].user.data["email"]?.value as? String
                    == "rotated@example.com"
            )
            await MainActor.run {
                #expect(isolatedStore.state.auth.accessToken == rotatedAccessToken)
                #expect(
                    isolatedStore.state.user.data["email"]?.value as? String
                        == "rotated@example.com"
                )
            }
        }
    }

    @Test func foregroundFetchRejectsDifferentLiveSessionBeforeProfileRequest() async throws {
        try await withMockedSuperTokensSession {
            let originalContext = Context.currentContext
            let isolatedStore = createStore()
            _ = Context(isolatedStore)
            defer { Context.currentContext = originalContext }

            let rowndAccessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 1800).timeIntervalSince1970,
                sessionHandle: "rownd-session"
            )
            let liveAccessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
                sessionHandle: "different-live-session"
            )
            #expect(await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: liveAccessToken,
                    refreshToken: makeSuperTokensTestJWT(expiresIn: 5400)
                )
            }.value)
            await MainActor.run {
                isolatedStore.dispatch(SetAuthState(payload: AuthState(
                    accessToken: rowndAccessToken
                )))
            }

            let outcome = await UserData.fetchForegroundUserData(
                isolatedStore.state,
                fetchUserData: { _ in
                    Issue.record("A different live session must prevent profile fetch")
                    return .profile(UserStateResponse())
                }
            )

            #expect(outcome == .ignored)
            await MainActor.run {
                #expect(isolatedStore.state.auth.accessToken == rowndAccessToken)
            }
        }
    }

    @Test func replacementProfileFetchPersistsRotatedTokenBeforeProfile() async throws {
        try await withMockedSuperTokensSession {
            let originalContext = Context.currentContext
            let isolatedStore = createStore()
            _ = Context(isolatedStore)
            defer { Context.currentContext = originalContext }

            let replacementAccessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 1800).timeIntervalSince1970,
                sessionHandle: "replacement-session"
            )
            let rotatedAccessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
                sessionHandle: "replacement-session"
            )
            await MainActor.run {
                isolatedStore.dispatch(SetAuthState(payload: AuthState(accessToken: "old-access-token")))
            }
            #expect(await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: replacementAccessToken,
                    refreshToken: makeSuperTokensTestJWT(expiresIn: 5400)
                )
            }.value)

            let persistedStates = StatePersistenceRecorder()
            let outcome = try await SuperTokensSessionBridge.syncReplacementRowndStateFromSuperTokens(
                expectedAccessToken: replacementAccessToken,
                expectedPreviousRowndAccessToken: "old-access-token",
                fetchUserData: { _ in
                    let refreshed = await SuperTokensSessionBridge.attemptRefresh {
                        SDKStorage.set("st-storage-item-st-access-token", value: rotatedAccessToken)
                            && FrontToken.setItem(frontToken: SuperTokensSessionBridge.buildFrontToken(
                                from: rotatedAccessToken
                            ))
                    }
                    #expect(refreshed)
                    return UserStateResponse(data: [
                        "email": AnyCodable("verified@example.com")
                    ])
                },
                persistState: persistedStates.persist
            )

            #expect(outcome == .profileSynchronized)
            let snapshots = persistedStates.snapshots
            try #require(snapshots.count == 3)
            #expect(snapshots[0].auth.accessToken == replacementAccessToken)
            #expect(snapshots[0].user.data.isEmpty)
            #expect(snapshots[1].auth.accessToken == rotatedAccessToken)
            #expect(snapshots[1].user.data.isEmpty)
            #expect(snapshots[2].auth.accessToken == rotatedAccessToken)
            #expect(snapshots[2].user.data["email"]?.value as? String == "verified@example.com")
        }
    }

    @Test func replacementSyncAcceptsRotationBeforeInitialAuthSync() async throws {
        try await withMockedSuperTokensSession {
            let originalContext = Context.currentContext
            let isolatedStore = createStore()
            _ = Context(isolatedStore)
            defer { Context.currentContext = originalContext }

            let responseAccessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 1800).timeIntervalSince1970,
                sessionHandle: "replacement-session"
            )
            let rotatedAccessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
                sessionHandle: "replacement-session"
            )
            await MainActor.run {
                isolatedStore.dispatch(SetAuthState(payload: AuthState(accessToken: "old-access-token")))
            }
            #expect(await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: responseAccessToken,
                    refreshToken: makeSuperTokensTestJWT(expiresIn: 5400)
                )
            }.value)

            let persistedStates = StatePersistenceRecorder()
            let outcome = try await SuperTokensSessionBridge.syncReplacementRowndStateFromSuperTokens(
                expectedAccessToken: responseAccessToken,
                expectedPreviousRowndAccessToken: "old-access-token",
                fetchUserData: { state in
                    #expect(state.auth.accessToken == rotatedAccessToken)
                    return UserStateResponse(data: ["email": AnyCodable("verified@example.com")])
                },
                persistState: persistedStates.persist,
                beforeInitialAuthSync: {
                    #expect(await SuperTokensSessionBridge.attemptRefresh {
                        SDKStorage.set("st-storage-item-st-access-token", value: rotatedAccessToken)
                            && FrontToken.setItem(frontToken: SuperTokensSessionBridge.buildFrontToken(
                                from: rotatedAccessToken
                            ))
                    })
                }
            )

            #expect(outcome == .profileSynchronized)
            let snapshots = persistedStates.snapshots
            try #require(snapshots.count == 2)
            #expect(snapshots[0].auth.accessToken == rotatedAccessToken)
            #expect(snapshots[0].user.data.isEmpty)
            #expect(snapshots[1].auth.accessToken == rotatedAccessToken)
            #expect(snapshots[1].user.data["email"]?.value as? String == "verified@example.com")
        }
    }

    @Test func replacementSyncAcceptsRotationDuringInitialAuthDispatch() async throws {
        try await withMockedSuperTokensSession {
            let originalContext = Context.currentContext
            let isolatedStore = createStore()
            _ = Context(isolatedStore)
            defer { Context.currentContext = originalContext }

            let responseAccessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 1800).timeIntervalSince1970,
                sessionHandle: "replacement-session"
            )
            let rotatedAccessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
                sessionHandle: "replacement-session"
            )
            await MainActor.run {
                isolatedStore.dispatch(SetAuthState(payload: AuthState(accessToken: "old-access-token")))
            }
            #expect(await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: responseAccessToken,
                    refreshToken: makeSuperTokensTestJWT(expiresIn: 5400)
                )
            }.value)

            let persistedStates = StatePersistenceRecorder()
            let outcome = try await SuperTokensSessionBridge.syncReplacementRowndStateFromSuperTokens(
                expectedAccessToken: responseAccessToken,
                expectedPreviousRowndAccessToken: "old-access-token",
                fetchUserData: { state in
                    #expect(state.auth.accessToken == rotatedAccessToken)
                    return UserStateResponse(data: ["email": AnyCodable("verified@example.com")])
                },
                persistState: persistedStates.persist,
                afterInitialAuthDispatch: { attempt in
                    guard attempt == 0 else { return }
                    #expect(await SuperTokensSessionBridge.attemptRefresh {
                        SDKStorage.set("st-storage-item-st-access-token", value: rotatedAccessToken)
                            && FrontToken.setItem(frontToken: SuperTokensSessionBridge.buildFrontToken(
                                from: rotatedAccessToken
                            ))
                    })
                }
            )

            #expect(outcome == .profileSynchronized)
            let snapshots = persistedStates.snapshots
            try #require(snapshots.count == 3)
            #expect(snapshots[0].auth.accessToken == responseAccessToken)
            #expect(snapshots[0].user.data.isEmpty)
            #expect(snapshots[1].auth.accessToken == rotatedAccessToken)
            #expect(snapshots[1].user.data.isEmpty)
            #expect(snapshots[2].auth.accessToken == rotatedAccessToken)
            #expect(snapshots[2].user.data["email"]?.value as? String == "verified@example.com")
        }
    }

    @Test func replacementSyncRejectsRotationWithDifferentUserOrTenant() async throws {
        try await withMockedSuperTokensSession {
            for changedToken in [
                generateJwt(
                    expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
                    sessionHandle: "replacement-session",
                    userId: "different-user",
                    tenantId: "tenant-a"
                ),
                generateJwt(
                    expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
                    sessionHandle: "replacement-session",
                    tenantId: "tenant-b"
                )
            ] {
                let originalContext = Context.currentContext
                let isolatedStore = createStore()
                _ = Context(isolatedStore)
                let responseAccessToken = generateJwt(
                    expires: Date(timeIntervalSinceNow: 1800).timeIntervalSince1970,
                    sessionHandle: "replacement-session",
                    tenantId: "tenant-a"
                )
                await MainActor.run {
                    isolatedStore.dispatch(SetAuthState(payload: AuthState(accessToken: "old-access-token")))
                }
                #expect(await Task.detached {
                    SuperTokensSessionBridge.bootstrapSession(
                        accessToken: responseAccessToken,
                        refreshToken: makeSuperTokensTestJWT(expiresIn: 5400)
                    )
                }.value)

                await #expect(throws: (any Error).self) {
                    try await SuperTokensSessionBridge.syncReplacementRowndStateFromSuperTokens(
                        expectedAccessToken: responseAccessToken,
                        expectedPreviousRowndAccessToken: "old-access-token",
                        fetchUserData: { _ in
                            Issue.record("A changed user or tenant must prevent profile fetch")
                            return UserStateResponse()
                        },
                        beforeInitialAuthSync: {
                            _ = await SuperTokensSessionBridge.attemptRefresh {
                                SDKStorage.set("st-storage-item-st-access-token", value: changedToken)
                                    && FrontToken.setItem(frontToken: SuperTokensSessionBridge.buildFrontToken(
                                        from: changedToken
                                    ))
                            }
                        }
                    )
                }
                await SuperTokensSessionBridge.signOut()
                Context.currentContext = originalContext
            }
        }
    }

    @Test func replacementProfileFetchRejectsTokenFromDifferentSession() async throws {
        try await withMockedSuperTokensSession {
            let originalContext = Context.currentContext
            let isolatedStore = createStore()
            _ = Context(isolatedStore)
            defer { Context.currentContext = originalContext }

            let replacementAccessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 1800).timeIntervalSince1970,
                sessionHandle: "replacement-session"
            )
            let differentSessionAccessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
                sessionHandle: "different-session"
            )
            await MainActor.run {
                isolatedStore.dispatch(SetAuthState(payload: AuthState(accessToken: "old-access-token")))
            }
            #expect(await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: replacementAccessToken,
                    refreshToken: makeSuperTokensTestJWT(expiresIn: 5400)
                )
            }.value)

            let persistedStates = StatePersistenceRecorder()
            await #expect(throws: (any Error).self) {
                try await SuperTokensSessionBridge.syncReplacementRowndStateFromSuperTokens(
                    expectedAccessToken: replacementAccessToken,
                    expectedPreviousRowndAccessToken: "old-access-token",
                    fetchUserData: { _ in
                        let refreshed = await SuperTokensSessionBridge.attemptRefresh {
                            SDKStorage.set(
                                "st-storage-item-st-access-token",
                                value: differentSessionAccessToken
                            ) && FrontToken.setItem(frontToken: SuperTokensSessionBridge.buildFrontToken(
                                from: differentSessionAccessToken
                            ))
                        }
                        #expect(refreshed)
                        return UserStateResponse(data: [
                            "email": AnyCodable("wrong@example.com")
                        ])
                    },
                    persistState: persistedStates.persist
                )
            }

            let snapshots = persistedStates.snapshots
            try #require(snapshots.count == 1)
            #expect(snapshots[0].auth.accessToken == replacementAccessToken)
            #expect(snapshots[0].user.data.isEmpty)
            await MainActor.run {
                #expect(isolatedStore.state.user.data.isEmpty)
            }
        }
    }

    @Test func signOutBetweenHubSessionAdoptionAndSyncWins() async throws {
        try await withMockedSuperTokensSession {
            let originalContext = Context.currentContext
            let isolatedStore = createStore()
            _ = Context(isolatedStore)
            defer {
                Context.currentContext = originalContext
            }

            let accessToken = makeSuperTokensTestJWT(expiresIn: 3600)
            let refreshToken = makeSuperTokensTestJWT(expiresIn: 7200)
            let adopted = await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: accessToken,
                    refreshToken: refreshToken
                )
            }.value
            #expect(adopted)

            var steps: [String] = []
            let tokenWasRead = SessionSyncGate()
            let resumeSync = SessionSyncGate()
            let syncTask = Task {
                await HubWebViewController.completeAuthenticationAfterAdoption(
                    succeeded: adopted,
                    syncAuthState: {
                        steps.append("sync")
                        return await SuperTokensSessionBridge.syncRowndAuthStateFromSuperTokens(
                            afterTokenRead: {
                                await tokenWasRead.open()
                                await resumeSync.wait()
                            }
                        )
                    },
                    syncFailure: { steps.append("show-error") },
                    completion: { steps.append("complete") }
                )
            }

            await tokenWasRead.wait()
            await Rownd.signOut()
            await resumeSync.open()
            await syncTask.value

            #expect(steps == ["sync", "show-error"])
            #expect(await !SuperTokensSessionBridge.doesSessionExist())
            #expect(await SuperTokensSessionBridge.getAccessToken() == nil)
            await MainActor.run {
                #expect(Context.currentContext.store.state.auth.isAuthenticated == false)
            }
        }
    }

    @Test func commitPredicatePreventsRowndAuthDispatch() async throws {
        try await withMockedSuperTokensSession {
            let originalContext = Context.currentContext
            let isolatedStore = createStore()
            _ = Context(isolatedStore)
            defer { Context.currentContext = originalContext }

            let accessToken = makeSuperTokensTestJWT(expiresIn: 3600)
            let refreshToken = makeSuperTokensTestJWT(expiresIn: 7200)
            let adopted = await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: accessToken,
                    refreshToken: refreshToken
                )
            }.value
            #expect(adopted)

            let synced = await SuperTokensSessionBridge.syncRowndAuthStateFromSuperTokens(
                afterTokenRead: {},
                commitIf: { false }
            )

            #expect(!synced)
            await MainActor.run {
                #expect(isolatedStore.state.auth.accessToken == nil)
                #expect(!isolatedStore.state.auth.isAuthenticated)
            }
        }
    }

    @Test func commitPredicatePreventsReconciliationAuthDispatch() async throws {
        try await withMockedSuperTokensSession {
            let originalContext = Context.currentContext
            let isolatedStore = createStore()
            _ = Context(isolatedStore)
            defer { Context.currentContext = originalContext }

            let accessToken = makeSuperTokensTestJWT(expiresIn: 3600)
            let refreshToken = makeSuperTokensTestJWT(expiresIn: 7200)
            let replacementAccessToken = makeSuperTokensTestJWT(expiresIn: 1800)
            let adopted = await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: accessToken,
                    refreshToken: refreshToken
                )
            }.value
            #expect(adopted)

            let synced = await SuperTokensSessionBridge.syncRowndAuthStateFromSuperTokens(
                afterTokenRead: {
                    let refreshed = await SuperTokensSessionBridge.attemptRefresh {
                        SDKStorage.set(
                            "st-storage-item-st-access-token",
                            value: replacementAccessToken
                        ) && FrontToken.setItem(
                            frontToken: SuperTokensSessionBridge.buildFrontToken(
                                from: replacementAccessToken
                            )
                        )
                    }
                    #expect(refreshed)
                },
                commitIf: { false }
            )

            #expect(!synced)
            await MainActor.run {
                #expect(isolatedStore.state.auth.accessToken == nil)
                #expect(!isolatedStore.state.auth.isAuthenticated)
            }
        }
    }

    @Test func refreshTokenChangeDuringSyncReconcilesRowndToRefreshedToken() async throws {
        try await withMockedSuperTokensSession {
            let originalContext = Context.currentContext
            let isolatedStore = createStore()
            _ = Context(isolatedStore)
            defer { Context.currentContext = originalContext }

            let originalAccessToken = makeSuperTokensTestJWT(expiresIn: 3600)
            let refreshToken = makeSuperTokensTestJWT(expiresIn: 7200)
            let refreshedAccessToken = makeSuperTokensTestJWT(expiresIn: 1800)
            let adopted = await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: originalAccessToken,
                    refreshToken: refreshToken
                )
            }.value
            #expect(adopted)

            let synced = await SuperTokensSessionBridge.syncRowndAuthStateFromSuperTokens(
                afterTokenRead: {
                    let refreshed = await SuperTokensSessionBridge.attemptRefresh {
                        SDKStorage.set("st-storage-item-st-access-token", value: refreshedAccessToken)
                            && FrontToken.setItem(frontToken: SuperTokensSessionBridge.buildFrontToken(
                                from: refreshedAccessToken
                            ))
                    }
                    #expect(refreshed)
                }
            )

            #expect(!synced)
            #expect(await MainActor.run { isolatedStore.state.auth.accessToken } == refreshedAccessToken)
        }
    }

    @Test func expectedSessionRotationReturnsTrueAfterDurableReconciliation() async throws {
        try await withMockedSuperTokensSession {
            let originalContext = Context.currentContext
            let isolatedStore = createStore()
            _ = Context(isolatedStore)
            defer { Context.currentContext = originalContext }

            let originalAccessToken = makeSuperTokensTestJWT(expiresIn: 3600)
            let rotatedAccessToken = makeSuperTokensTestJWT(expiresIn: 1800)
            #expect(await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: originalAccessToken,
                    refreshToken: makeSuperTokensTestJWT(expiresIn: 7200)
                )
            }.value)
            let expectedIdentity = try #require(
                await SuperTokensSessionBridge.currentSessionIdentity(matching: originalAccessToken)
            )
            let persistedStates = StatePersistenceRecorder()

            let synchronized = await SuperTokensSessionBridge.syncRowndAuthStateFromSuperTokens(
                afterTokenRead: {
                    #expect(await SuperTokensSessionBridge.attemptRefresh {
                        SDKStorage.set("st-storage-item-st-access-token", value: rotatedAccessToken)
                            && FrontToken.setItem(
                                frontToken: SuperTokensSessionBridge.buildFrontToken(
                                    from: rotatedAccessToken
                                )
                            )
                    })
                },
                expectedSessionIdentity: expectedIdentity,
                persistState: persistedStates.persist
            )

            #expect(synchronized)
            #expect(persistedStates.snapshots.count == 1)
            #expect(await MainActor.run {
                isolatedStore.state.auth.accessToken == rotatedAccessToken
            })
        }
    }

    @Test func expectedSessionRotationPersistenceFailureReturnsFalseWithoutStoreMutation() async throws {
        try await withMockedSuperTokensSession {
            let originalContext = Context.currentContext
            let isolatedStore = createStore()
            _ = Context(isolatedStore)
            defer { Context.currentContext = originalContext }

            let originalAccessToken = makeSuperTokensTestJWT(expiresIn: 3600)
            let rotatedAccessToken = makeSuperTokensTestJWT(expiresIn: 1800)
            #expect(await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: originalAccessToken,
                    refreshToken: makeSuperTokensTestJWT(expiresIn: 7200)
                )
            }.value)
            let expectedIdentity = try #require(
                await SuperTokensSessionBridge.currentSessionIdentity(matching: originalAccessToken)
            )
            await MainActor.run {
                isolatedStore.dispatch(SetAuthState(payload: AuthState(
                    accessToken: originalAccessToken
                )))
                isolatedStore.dispatch(SetUserState(payload: UserState(data: [
                    "email": AnyCodable("preserved@example.com")
                ])))
            }

            let synchronized = await SuperTokensSessionBridge.syncRowndAuthStateFromSuperTokens(
                afterTokenRead: {
                    #expect(await SuperTokensSessionBridge.attemptRefresh {
                        SDKStorage.set("st-storage-item-st-access-token", value: rotatedAccessToken)
                            && FrontToken.setItem(
                                frontToken: SuperTokensSessionBridge.buildFrontToken(
                                    from: rotatedAccessToken
                                )
                            )
                    })
                },
                expectedSessionIdentity: expectedIdentity,
                persistState: { _ in false }
            )

            #expect(!synchronized)
            await MainActor.run {
                #expect(isolatedStore.state.auth.accessToken == originalAccessToken)
                #expect(isolatedStore.state.user.data["email"]?.value as? String == "preserved@example.com")
            }
        }
    }

    @Test func nonNilSessionReplacementAfterAuthDispatchReconcilesRownd() async throws {
        try await withMockedSuperTokensSession {
            let originalContext = Context.currentContext
            let isolatedStore = createStore()
            _ = Context(isolatedStore)
            defer { Context.currentContext = originalContext }

            let originalAccessToken = makeSuperTokensTestJWT(expiresIn: 3600)
            let originalRefreshToken = makeSuperTokensTestJWT(expiresIn: 7200)
            let replacementAccessToken = makeSuperTokensTestJWT(expiresIn: 1800)
            let replacementRefreshToken = makeSuperTokensTestJWT(expiresIn: 5400)
            let adopted = await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: originalAccessToken,
                    refreshToken: originalRefreshToken
                )
            }.value
            #expect(adopted)

            let synced = await SuperTokensSessionBridge.syncRowndAuthStateFromSuperTokens(
                afterTokenRead: {},
                afterAuthDispatch: {
                    let replaced = await Task.detached {
                        SuperTokensSessionBridge.bootstrapSession(
                            accessToken: replacementAccessToken,
                            refreshToken: replacementRefreshToken,
                            refreshSession: {
                                SDKStorage.set(
                                    "st-storage-item-st-access-token",
                                    value: replacementAccessToken
                                ) && FrontToken.setItem(frontToken: SuperTokensSessionBridge.buildFrontToken(
                                    from: replacementAccessToken
                                ))
                            }
                        )
                    }.value
                    #expect(replaced)
                }
            )

            #expect(!synced)
            #expect(await MainActor.run { isolatedStore.state.auth.accessToken } == replacementAccessToken)
        }
    }

    @Test func reconciliationContinuesAfterInitialCommitPermissionIsRevoked() async throws {
        try await withMockedSuperTokensSession {
            let originalContext = Context.currentContext
            let isolatedStore = createStore()
            _ = Context(isolatedStore)
            defer { Context.currentContext = originalContext }

            let originalAccessToken = makeSuperTokensTestJWT(expiresIn: 3600)
            let originalRefreshToken = makeSuperTokensTestJWT(expiresIn: 7200)
            let replacementAccessToken = makeSuperTokensTestJWT(expiresIn: 1800)
            let replacementRefreshToken = makeSuperTokensTestJWT(expiresIn: 5400)
            let permission = await MainActor.run { SessionCommitPermission() }
            let adopted = await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: originalAccessToken,
                    refreshToken: originalRefreshToken
                )
            }.value
            #expect(adopted)

            let synced = await SuperTokensSessionBridge.syncRowndAuthStateFromSuperTokens(
                afterTokenRead: {},
                afterAuthDispatch: {
                    await MainActor.run {
                        #expect(isolatedStore.state.auth.accessToken == originalAccessToken)
                        permission.isAllowed = false
                    }
                    let replaced = await Task.detached {
                        SuperTokensSessionBridge.bootstrapSession(
                            accessToken: replacementAccessToken,
                            refreshToken: replacementRefreshToken,
                            refreshSession: {
                                SDKStorage.set(
                                    "st-storage-item-st-access-token",
                                    value: replacementAccessToken
                                ) && FrontToken.setItem(
                                    frontToken: SuperTokensSessionBridge.buildFrontToken(
                                        from: replacementAccessToken
                                    )
                                )
                            }
                        )
                    }.value
                    #expect(replaced)
                },
                commitIf: { permission.isAllowed }
            )

            #expect(!synced)
            #expect(await MainActor.run { !permission.isAllowed })
            #expect(await MainActor.run {
                isolatedStore.state.auth.accessToken == replacementAccessToken
            })
        }
    }

    @Test func replacementDuringReconciliationStabilizesOnLatestToken() async throws {
        try await withMockedSuperTokensSession {
            let originalContext = Context.currentContext
            let isolatedStore = createStore()
            _ = Context(isolatedStore)
            defer { Context.currentContext = originalContext }

            let originalAccessToken = makeSuperTokensTestJWT(expiresIn: 3600)
            let originalRefreshToken = makeSuperTokensTestJWT(expiresIn: 7200)
            let firstReplacementAccessToken = makeSuperTokensTestJWT(expiresIn: 1800)
            let firstReplacementRefreshToken = makeSuperTokensTestJWT(expiresIn: 5400)
            let finalAccessToken = makeSuperTokensTestJWT(expiresIn: 900)
            let finalRefreshToken = makeSuperTokensTestJWT(expiresIn: 4500)
            let adopted = await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: originalAccessToken,
                    refreshToken: originalRefreshToken
                )
            }.value
            #expect(adopted)

            func replaceSession(accessToken: String, refreshToken: String) async -> Bool {
                await Task.detached {
                    SuperTokensSessionBridge.bootstrapSession(
                        accessToken: accessToken,
                        refreshToken: refreshToken,
                        refreshSession: {
                            SDKStorage.set("st-storage-item-st-access-token", value: accessToken)
                                && FrontToken.setItem(frontToken: SuperTokensSessionBridge.buildFrontToken(
                                    from: accessToken
                                ))
                        }
                    )
                }.value
            }

            let synced = await SuperTokensSessionBridge.syncRowndAuthStateFromSuperTokens(
                afterTokenRead: {},
                afterAuthDispatch: {
                    #expect(await replaceSession(
                        accessToken: firstReplacementAccessToken,
                        refreshToken: firstReplacementRefreshToken
                    ))
                },
                afterReconciliationDispatch: { attempt in
                    guard attempt == 0 else { return }
                    #expect(await replaceSession(
                        accessToken: finalAccessToken,
                        refreshToken: finalRefreshToken
                    ))
                }
            )

            #expect(!synced)
            #expect(await MainActor.run { isolatedStore.state.auth.accessToken } == finalAccessToken)
        }
    }

    @Test func reconciliationExhaustionClearsLastIntermediateToken() async throws {
        try await withMockedSuperTokensSession {
            let originalContext = Context.currentContext
            let isolatedStore = createStore()
            _ = Context(isolatedStore)
            defer { Context.currentContext = originalContext }

            let originalAccessToken = makeSuperTokensTestJWT(expiresIn: 3600)
            let originalRefreshToken = makeSuperTokensTestJWT(expiresIn: 7200)
            let replacementTokens = [1800, 1500, 1200, 900].map {
                makeSuperTokensTestJWT(expiresIn: TimeInterval($0))
            }
            let replacementRefreshTokens = [5400, 5100, 4800, 4500].map {
                makeSuperTokensTestJWT(expiresIn: TimeInterval($0))
            }
            let adopted = await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: originalAccessToken,
                    refreshToken: originalRefreshToken
                )
            }.value
            #expect(adopted)

            func replaceSession(at index: Int) async -> Bool {
                let accessToken = replacementTokens[index]
                let refreshToken = replacementRefreshTokens[index]
                return await Task.detached {
                    SuperTokensSessionBridge.bootstrapSession(
                        accessToken: accessToken,
                        refreshToken: refreshToken,
                        refreshSession: {
                            SDKStorage.set("st-storage-item-st-access-token", value: accessToken)
                                && FrontToken.setItem(frontToken: SuperTokensSessionBridge.buildFrontToken(
                                    from: accessToken
                                ))
                        }
                    )
                }.value
            }

            let terminalState = StatePersistenceRecorder()
            let synced = await SuperTokensSessionBridge.syncRowndAuthStateFromSuperTokens(
                afterTokenRead: {},
                afterAuthDispatch: {
                    #expect(await replaceSession(at: 0))
                },
                afterReconciliationDispatch: { attempt in
                    #expect(await replaceSession(at: attempt + 1))
                },
                afterTerminalReconciliationDispatch: {
                    await MainActor.run {
                        _ = terminalState.persist(isolatedStore.state)
                    }
                }
            )

            #expect(!synced)
            #expect(await SuperTokensSessionBridge.getAccessToken() == replacementTokens[3])
            await MainActor.run {
                #expect(isolatedStore.state.auth.accessToken == nil)
                #expect(!isolatedStore.state.auth.isAuthenticated)
            }
            let terminalSnapshots = terminalState.snapshots
            try #require(terminalSnapshots.count == 1)
            #expect(!terminalSnapshots[0].auth.isAuthenticated)
        }
    }

    @Test func localCleanupClearsSessionThroughCore() async throws {
        try await withMockedSuperTokensSession {
            let accessToken = makeSuperTokensTestJWT(expiresIn: 3600)
            let refreshToken = makeSuperTokensTestJWT(expiresIn: 7200)
            await Task.detached {
                _ = SuperTokensSessionBridge.bootstrapSession(
                    accessToken: accessToken,
                    refreshToken: refreshToken,
                    antiCSRF: "anti-csrf-token"
                )
            }.value
            #expect(await SuperTokensSessionBridge.doesSessionExist())

            #expect(SuperTokensSessionBridge.clearLocalSessionArtifacts())

            // The clear now routes through the core SDK (single source of truth);
            // verify the session is gone rather than asserting on hand-rolled keys.
            #expect(await !SuperTokensSessionBridge.doesSessionExist())
            #expect(SuperTokensSessionBridge.getFrontToken() == nil)
            #expect(SuperTokensSessionBridge.getAntiCSRF() == nil)
        }
    }

    @Test func rowndSignOutClearsSuperTokensAndCompatibilityState() async throws {
        try await withMockedSuperTokensSession {
            let originalContext = Context.currentContext
            let isolatedStore = createStore()
            _ = Context(isolatedStore)
            defer {
                Context.currentContext = originalContext
            }

            let accessToken = makeSuperTokensTestJWT(expiresIn: 3600)
            let refreshToken = makeSuperTokensTestJWT(expiresIn: 7200)

            await MainActor.run {
                Context.currentContext.store.dispatch(
                    SetAuthState(
                        payload: AuthState(accessToken: accessToken, refreshToken: refreshToken)
                    )
                )
            }

            await Task.detached {
                _ = SuperTokensSessionBridge.bootstrapSession(
                    accessToken: accessToken,
                    refreshToken: refreshToken
                )
            }.value

            #expect(await SuperTokensSessionBridge.getAccessToken() == accessToken)
            #expect(Self.activeStore.get("st-storage-item-st-refresh-token") == refreshToken)

            await Rownd.signOut()

            for _ in 0..<40 {
                let isAuthenticated = await MainActor.run {
                    Context.currentContext.store.state?.auth.isAuthenticated
                }

                if isAuthenticated == false, await !SuperTokensSessionBridge.doesSessionExist() {
                    break
                }

                try await Task.sleep(nanoseconds: 25_000_000)
            }

            await MainActor.run {
                #expect(Context.currentContext.store.state?.auth.isAuthenticated == false)
            }
            #expect(await !SuperTokensSessionBridge.doesSessionExist())
            #expect(Self.activeStore.get("supertokens-ios-fronttoken-key") == nil)
        }
    }

    @Test func rowndSignOutAsyncKeepsAuthorizationWhenCallerClearsStorageAfterReturn() async throws {
        try await withLocalSignOutServerSession { server in
            let accessToken = makeSuperTokensTestJWT(expiresIn: 3600)
            let refreshToken = makeSuperTokensTestJWT(expiresIn: 7200)

            await Task.detached {
                _ = SuperTokensSessionBridge.bootstrapSession(
                    accessToken: accessToken,
                    refreshToken: refreshToken
                )
            }.value

            #expect(await SuperTokensSessionBridge.doesSessionExist())

            await Rownd.signOut()
            clearStoredSessionArtifacts()

            let request = try await server.nextRequest()
            #expect(request.path == "/auth/signout")
            #expect(request.headers["authorization"]?.hasPrefix("Bearer ") == true)
        }
    }

    @Test func rowndSignOutFireAndForgetCanLoseAuthorizationWhenCallerClearsStorageImmediately() async throws {
        try await withLocalSignOutServerSession { server in
            let accessToken = makeSuperTokensTestJWT(expiresIn: 3600)
            let refreshToken = makeSuperTokensTestJWT(expiresIn: 7200)

            await Task.detached {
                _ = SuperTokensSessionBridge.bootstrapSession(
                    accessToken: accessToken,
                    refreshToken: refreshToken
                )
            }.value

            #expect(await SuperTokensSessionBridge.doesSessionExist())

            callFireAndForgetSignOut()
            clearStoredSessionArtifacts()

            let request = try await server.nextRequestIfAvailable()
            if let request {
                #expect(request.path == "/auth/signout")
                #expect(request.headers["authorization"]?.hasPrefix("Bearer ") != true)
            }
        }
    }

    @Test func blockingSuperTokensApisAreOnlyUsedThroughBridge() async throws {
        try await withGlobalTestLock {
            let sourceRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Rownd")

            let enumerator = FileManager.default.enumerator(
                at: sourceRoot,
                includingPropertiesForKeys: nil
            )

            var directReferences: [String] = []

            while let fileURL = enumerator?.nextObject() as? URL {
                guard fileURL.pathExtension == "swift" else { continue }
                let contents = try String(contentsOf: fileURL)

                if contents.contains("SuperTokens.doesSessionExist(")
                    || contents.contains("SuperTokens.attemptRefreshingSession(")
                {
                    directReferences.append(fileURL.lastPathComponent)
                }
            }

            #expect(directReferences == ["SuperTokensSessionBridge.swift"])
        }
    }

    @Test func delayedForegroundProfile404CannotSignOutNewAccount() async throws {
        try await withMockedSuperTokensSession {
            let originalContext = Context.currentContext
            let isolatedStore = createStore()
            _ = Context(isolatedStore)
            let originalRequestSession = UserData.testingRequestSession
            let controller = DelayedProfile404Controller()
            DelayedProfile404URLProtocol.controller = controller
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [DelayedProfile404URLProtocol.self]
            UserData.testingRequestSession = URLSession(configuration: configuration)
            defer {
                UserData.testingRequestSession = originalRequestSession
                DelayedProfile404URLProtocol.controller = nil
                Context.currentContext = originalContext
            }

            let oldAccessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
                sessionHandle: "old-session"
            )
            let newAccessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
                sessionHandle: "new-session"
            )
            #expect(await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: oldAccessToken,
                    refreshToken: makeSuperTokensTestJWT(expiresIn: 5400)
                )
            }.value)
            await MainActor.run {
                isolatedStore.dispatch(SetAuthState(payload: AuthState(accessToken: oldAccessToken)))
                isolatedStore.dispatch(UserData.fetch())
            }
            await controller.waitUntilStarted()
            #expect(await waitUntil {
                await MainActor.run { isolatedStore.state.user.isLoading }
            })

            #expect(await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: newAccessToken,
                    refreshToken: makeSuperTokensTestJWT(expiresIn: 5400),
                    refreshSession: {
                        SDKStorage.set("st-storage-item-st-access-token", value: newAccessToken)
                            && FrontToken.setItem(frontToken: SuperTokensSessionBridge.buildFrontToken(
                                from: newAccessToken
                            ))
                    }
                )
            }.value)
            await MainActor.run {
                isolatedStore.dispatch(SetAuthState(payload: AuthState(accessToken: newAccessToken)))
                isolatedStore.dispatch(SetUserState(payload: UserState(data: [
                    "email": AnyCodable("new-account@example.com")
                ])))
            }

            await controller.releaseResponse()
            await controller.waitUntilDelivered()
            #expect(await waitUntil {
                await MainActor.run { !isolatedStore.state.user.isLoading }
            })

            #expect(await SuperTokensSessionBridge.getAccessToken() == newAccessToken)
            await MainActor.run {
                #expect(isolatedStore.state.auth.accessToken == newAccessToken)
                #expect(isolatedStore.state.user.data["email"]?.value as? String == "new-account@example.com")
            }
        }
    }

    @Test func backgroundedBlocked404IsIgnoredWithoutSigningOut() async throws {
        try await withMockedSuperTokensSession {
            let originalContext = Context.currentContext
            let isolatedStore = createStore()
            _ = Context(isolatedStore)
            defer { Context.currentContext = originalContext }

            let accessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
                sessionHandle: "backgrounded-404-session"
            )
            #expect(await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: accessToken,
                    refreshToken: makeSuperTokensTestJWT(expiresIn: 5400)
                )
            }.value)
            await MainActor.run {
                isolatedStore.dispatch(SetAuthState(payload: AuthState(accessToken: accessToken)))
            }
            let state = try #require(isolatedStore.state)
            let requestStarted = SessionSyncGate()
            let releaseResponse = SessionSyncGate()
            let permission = await MainActor.run { SessionCommitPermission() }

            let fetchTask = Task {
                await UserData.fetchForegroundUserData(
                    state,
                    fetchUserData: { _ in
                        await requestStarted.open()
                        await releaseResponse.wait()
                        return .notFound
                    },
                    persistState: { _ in true },
                    commitIf: { permission.isAllowed }
                )
            }
            await requestStarted.wait()
            await MainActor.run { permission.isAllowed = false }
            await releaseResponse.open()

            #expect(await fetchTask.value == .ignored)
            #expect(await SuperTokensSessionBridge.getAccessToken() == accessToken)
            await MainActor.run {
                #expect(isolatedStore.state.auth.accessToken == accessToken)
            }
        }
    }

    @Test func backgroundCancellationWhileConditionalSignOutIsQueuedPreventsSignOut() async throws {
        try await withMockedSuperTokensSession {
            UserData.fetchCoordinator.cancelCurrent()
            let accessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
                sessionHandle: "queued-background-signout"
            )
            let installed = await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: accessToken,
                    refreshToken: makeSuperTokensTestJWT(expiresIn: 5400)
                )
            }.value
            #expect(installed)
            let identity = try #require(
                await SuperTokensSessionBridge.currentSessionIdentity(matching: accessToken)
            )
            let ticket = try #require(UserData.fetchCoordinator.begin(
                accessToken: accessToken,
                purpose: .foreground
            ))
            let queueEntered = DispatchSemaphore(value: 0)
            let releaseQueue = DispatchSemaphore(value: 0)
            let conditionPrechecked = DispatchSemaphore(value: 0)
            let conditionProbe = SynchronousConditionProbe()
            let queueBlocker = Task {
                await SuperTokensSessionBridge.attemptRefresh {
                    queueEntered.signal()
                    releaseQueue.wait()
                    return true
                }
            }
            await waitForSignal(queueEntered)

            let signOutTask = Task {
                await SuperTokensSessionBridge.signOutIfCurrentSession(
                    identity,
                    expectedRowndAccessToken: accessToken,
                    condition: {
                        conditionProbe.evaluate(
                            UserData.fetchCoordinator.isCurrent(ticket),
                            firstEvaluation: conditionPrechecked
                        )
                    }
                )
            }
            await waitForSignal(conditionPrechecked)
            AppStateListener().appMovedToBackground()
            DispatchQueue.global(qos: .userInitiated).async {
                releaseQueue.signal()
            }

            #expect(await !signOutTask.value)
            #expect(await queueBlocker.value)
            #expect(conditionProbe.evaluationCount == 2)
            #expect(await SuperTokensSessionBridge.getAccessToken() == accessToken)
            #expect(!UserData.fetchCoordinator.isCurrent(ticket))

            let nextTicket = try #require(UserData.fetchCoordinator.begin(
                accessToken: accessToken,
                purpose: .foreground
            ))
            #expect(UserData.fetchCoordinator.isCurrent(nextTicket))
            UserData.fetchCoordinator.finish(nextTicket)
        }
    }

    @Test func appleEnrichmentRequestAndCommitRemainBoundToCapturedSession() async throws {
        try await withMockedSuperTokensSession {
            let originalContext = Context.currentContext
            let isolatedStore = createStore()
            _ = Context(isolatedStore)
            let originalRequestSession = UserData.testingExpectedSessionRequestSession
            let controller = DelayedExpectedSessionSaveController()
            DelayedExpectedSessionSaveURLProtocol.controller = controller
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [DelayedExpectedSessionSaveURLProtocol.self]
            UserData.testingExpectedSessionRequestSession = URLSession(configuration: configuration)
            defer {
                UserData.testingExpectedSessionRequestSession = originalRequestSession
                DelayedExpectedSessionSaveURLProtocol.controller = nil
                Context.currentContext = originalContext
            }

            let appleAccessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
                sessionHandle: "apple-session"
            )
            let replacementAccessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
                sessionHandle: "replacement-session",
                userId: "replacement-user"
            )
            let installedAppleSession = await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: appleAccessToken,
                    refreshToken: makeSuperTokensTestJWT(expiresIn: 5400)
                )
            }.value
            #expect(installedAppleSession)
            await MainActor.run {
                isolatedStore.dispatch(SetAuthState(payload: AuthState(accessToken: appleAccessToken)))
                isolatedStore.dispatch(SetUserState(payload: UserState(data: [
                    "email": AnyCodable("apple-before@example.com")
                ])))
            }
            let appleIdentity = try #require(
                await SuperTokensSessionBridge.currentSessionIdentity(matching: appleAccessToken)
            )
            let ticket = try #require(UserData.fetchCoordinator.begin(
                accessToken: appleAccessToken,
                purpose: .foreground
            ))
            defer { UserData.fetchCoordinator.finish(ticket) }

            let saveTask = Task<Bool, Never> {
                await UserData.saveExpectedSession(
                    ["email": AnyCodable("apple-captured@example.com")],
                    expectedData: ["email": AnyCodable("apple-before@example.com")],
                    expectedSessionIdentity: appleIdentity,
                    ticket: ticket
                )
            }
            await controller.waitUntilStarted()

            let installedReplacementSession = await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: replacementAccessToken,
                    refreshToken: makeSuperTokensTestJWT(expiresIn: 5400),
                    refreshSession: {
                        SDKStorage.set("st-storage-item-st-access-token", value: replacementAccessToken)
                            && FrontToken.setItem(frontToken: SuperTokensSessionBridge.buildFrontToken(
                                from: replacementAccessToken
                            ))
                    }
                )
            }.value
            #expect(installedReplacementSession)
            await MainActor.run {
                isolatedStore.dispatch(SetAuthState(payload: AuthState(
                    accessToken: replacementAccessToken
                )))
                isolatedStore.dispatch(SetUserState(payload: UserState(data: [
                    "email": AnyCodable("replacement@example.com")
                ])))
            }
            await controller.releaseResponse()

            #expect(await saveTask.value == false)
            #expect(await controller.authorization == "Bearer \(appleAccessToken)")
            #expect(await SuperTokensSessionBridge.getAccessToken() == replacementAccessToken)
            await MainActor.run {
                #expect(isolatedStore.state.auth.accessToken == replacementAccessToken)
                #expect(isolatedStore.state.user.data["email"]?.value as? String == "replacement@example.com")
            }
        }
    }

    @Test func appleEnrichmentSupersedesActiveSameSessionForegroundFetchAndSaves() async throws {
        try await withMockedSuperTokensSession {
            let originalContext = Context.currentContext
            let isolatedStore = createStore()
            _ = Context(isolatedStore)
            let originalRequestSession = UserData.testingExpectedSessionRequestSession
            let controller = DelayedExpectedSessionSaveController()
            DelayedExpectedSessionSaveURLProtocol.controller = controller
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [DelayedExpectedSessionSaveURLProtocol.self]
            UserData.testingExpectedSessionRequestSession = URLSession(configuration: configuration)
            UserDefaults.standard.removeObject(forKey: "userAppleSignInData")
            defer {
                UserData.testingExpectedSessionRequestSession = originalRequestSession
                DelayedExpectedSessionSaveURLProtocol.controller = nil
                UserDefaults.standard.removeObject(forKey: "userAppleSignInData")
                Context.currentContext = originalContext
            }

            let accessToken = generateJwt(
                expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
                sessionHandle: "apple-enrichment-session"
            )
            #expect(await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(
                    accessToken: accessToken,
                    refreshToken: makeSuperTokensTestJWT(expiresIn: 5400)
                )
            }.value)
            let sessionIdentity = try #require(
                await SuperTokensSessionBridge.currentSessionIdentity(matching: accessToken)
            )
            await MainActor.run {
                isolatedStore.dispatch(SetAuthState(payload: AuthState(accessToken: accessToken)))
                isolatedStore.dispatch(SetUserState(payload: UserState(data: [
                    "email": AnyCodable("before-apple@example.com")
                ])))
            }
            let foregroundTicket = try #require(UserData.fetchCoordinator.begin(
                accessToken: accessToken,
                purpose: .foreground
            ))
            let coordinator = AppleSignUpCoordinator(Rownd.getInstance())
            let enrichmentTask = Task {
                await coordinator.enrichUserDataWithAppleData(
                    fullName: nil,
                    email: "apple-captured@example.com",
                    state: isolatedStore.state,
                    sessionIdentity: sessionIdentity,
                    fetchUserData: { state in
                        #expect(state.auth.accessToken == accessToken)
                        return .profile(UserStateResponse())
                    }
                )
            }

            await controller.waitUntilStarted()
            #expect(!UserData.fetchCoordinator.isCurrent(foregroundTicket))
            #expect(await controller.authorization == "Bearer \(accessToken)")
            await controller.releaseResponse()

            #expect(await enrichmentTask.value)
            await MainActor.run {
                #expect(isolatedStore.state.auth.accessToken == accessToken)
                #expect(
                    isolatedStore.state.user.data["email"]?.value as? String
                        == "apple-captured@example.com"
                )
                #expect(!isolatedStore.state.user.isLoading)
            }
        }
    }

    private func withMockedSuperTokensSession(
        _ operation: @escaping () async throws -> Void
    ) async throws {
        try await withGlobalTestLock {
            // Force a clean SuperTokens init for every test. Another suite's harness
            // (withLocalSignOutServerSession) resets SuperTokens in its teardown while
            // leaving Rownd's isSuperTokensInitialized flag set, which would otherwise
            // make initializeSuperTokensIfNeeded short-circuit and leave
            // SuperTokens.isInitCalled false — breaking the core APIs the bridge now
            // routes through.
            let previousIsInitialized = Rownd.isSuperTokensInitialized
            Self.resetToKnownState()
            Rownd.isSuperTokensInitialized = false
            Rownd.config.supertokens = Self.supertokensConfig
            _ = try Rownd.initializeSuperTokensIfNeeded()
            let store = InMemorySessionStore()
            Self.activeStore = store
            SDKStorage.setTokenStorageForTests(store)
            let previousStorageOverride = SuperTokensSessionBridge.storageOverride
            SuperTokensSessionBridge.storageOverride = store
            URLProtocol.registerClass(SuperTokensSignOutURLProtocol.self)

            defer {
                URLProtocol.unregisterClass(SuperTokensSignOutURLProtocol.self)
                SuperTokensSessionBridge.storageOverride = previousStorageOverride
                SuperTokens.resetForTests()
                Rownd.isSuperTokensInitialized = previousIsInitialized
            }

            clearStoredSessionArtifacts()
            await clearSessionIfNeeded()
            await UserData.profileHydrationRetryCoordinator.cancel()
            try await operation()
            await UserData.profileHydrationRetryCoordinator.cancel()
            await clearSessionIfNeeded()
            clearStoredSessionArtifacts()
        }
    }

    private func withLocalSignOutServerSession(
        _ operation: @escaping (LocalHTTPServer) async throws -> Void
    ) async throws {
        try await withGlobalTestLock {
            let server = try await LocalHTTPServer.start()
            let originalSuperTokensConfig = Rownd.config.supertokens
            let originalIsSuperTokensInitialized = Rownd.isSuperTokensInitialized

            Rownd.isSuperTokensInitialized = false
            Self.resetToKnownState()
            Rownd.config.supertokens = RowndSuperTokensConfig(
                appName: "Signout Race Test",
                apiDomain: server.baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                apiBasePath: "/auth"
            )
            _ = try Rownd.initializeSuperTokensIfNeeded()
            let store = InMemorySessionStore()
            Self.activeStore = store
            SDKStorage.setTokenStorageForTests(store)
            let previousStorageOverride = SuperTokensSessionBridge.storageOverride
            SuperTokensSessionBridge.storageOverride = store

            defer {
                server.stop()
                SuperTokens.resetForTests()
                SuperTokensSessionBridge.storageOverride = previousStorageOverride
                Rownd.config.supertokens = originalSuperTokensConfig
                Rownd.isSuperTokensInitialized = originalIsSuperTokensInitialized
            }

            clearStoredSessionArtifacts()
            try await operation(server)
            clearStoredSessionArtifacts()
        }
    }

    private func clearSessionIfNeeded() async {
        if await SuperTokensSessionBridge.doesSessionExist() {
            await SuperTokensSessionBridge.signOut()
        }
    }

    private func clearStoredSessionArtifacts() {
        Self.activeStore.reset()
        let userDefaults = UserDefaults.standard
        for key in Self.allSessionKeys {
            userDefaults.removeObject(forKey: key)
        }
    }

    private func callFireAndForgetSignOut() {
        Rownd.signOut()
    }

    private func makeSuperTokensTestJWT(expiresIn seconds: TimeInterval) -> String {
        // SuperTokens local session state reads real JWT claims such as sub and exp.
        generateJwt(
            expires: Date(timeIntervalSinceNow: seconds).timeIntervalSince1970,
            sessionHandle: "test-session"
        )
    }

    @MainActor private func callBlockingBridgeMethodsFromMainActor() async {
        _ = await SuperTokensSessionBridge.doesSessionExist()
        _ = await SuperTokensSessionBridge.attemptRefresh()
    }

    private func expectCompletesWithinOneSecond(
        _ operation: @escaping @Sendable () async -> Void
    ) async throws {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await operation()
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                return false
            }

            let completed = await group.next() ?? false
            group.cancelAll()
            #expect(completed)
        }
    }

    private func waitUntil(
        attempts: Int = 200,
        condition: @escaping () async -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if await condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    private func fetchInitialForegroundProfile(
        recorder: InitialForegroundProfileRecorder
    ) async {
        await Rownd.fetchInitialForegroundProfileIfNeeded(
            appIsActive: { true },
            fetchUserData: { _ in
                await recorder.recordFetch(nil)
                return .profileHydrationStillPending
            },
            scheduleRetry: { outcome in
                await recorder.recordScheduledOutcome(outcome)
            }
        )
    }

    private func waitForSignal(_ semaphore: DispatchSemaphore) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                semaphore.wait()
                continuation.resume()
            }
        }
    }

    private func waitForSignal(
        _ semaphore: DispatchSemaphore,
        timeout: TimeInterval
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now()) {
                continuation.resume(
                    returning: semaphore.wait(timeout: .now() + timeout) == .success
                )
            }
        }
    }
}

@MainActor
private final class SessionCommitPermission {
    var isAllowed = true
}

private final class SynchronousConditionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var evaluationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func evaluate(_ value: Bool, firstEvaluation: DispatchSemaphore) -> Bool {
        lock.lock()
        count += 1
        let shouldSignal = count == 1
        lock.unlock()
        if shouldSignal {
            firstEvaluation.signal()
        }
        return value
    }
}

private actor InitialForegroundProfileRecorder {
    private(set) var fetchedIdentity: SuperTokensSessionBridge.StableSessionIdentity?
    private(set) var scheduledOutcome: UserData.ForegroundFetchOutcome?
    private(set) var fetchCount = 0
    private(set) var scheduleCount = 0

    func recordFetch(_ identity: SuperTokensSessionBridge.StableSessionIdentity?) {
        fetchCount += 1
        fetchedIdentity = identity
    }

    func recordScheduledOutcome(_ outcome: UserData.ForegroundFetchOutcome) {
        scheduleCount += 1
        scheduledOutcome = outcome
    }
}

private actor SessionSyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pendingWaiters = waiters
        waiters.removeAll()
        for waiter in pendingWaiters {
            waiter.resume()
        }
    }
}

private enum ReplacementProfileTestError: Error {
    case unavailable
}

private actor FailingThenSuccessfulProfileSequence {
    private(set) var count = 0

    func next() throws -> UserData.FetchResult {
        count += 1
        if count == 1 {
            throw ReplacementProfileTestError.unavailable
        }
        return .profile(UserStateResponse(data: [
            "email": AnyCodable("retried@example.com")
        ]))
    }
}

private actor DelayedProfile404Controller {
    private var hasStarted = false
    private var canRespond = false
    private var hasDelivered = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var responseWaiters: [CheckedContinuation<Void, Never>] = []
    private var deliveredWaiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        hasStarted = true
        let waiters = startedWaiters
        startedWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitUntilStarted() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func waitForRelease() async {
        guard !canRespond else { return }
        await withCheckedContinuation { responseWaiters.append($0) }
    }

    func releaseResponse() {
        canRespond = true
        let waiters = responseWaiters
        responseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func markDelivered() {
        hasDelivered = true
        let waiters = deliveredWaiters
        deliveredWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitUntilDelivered() async {
        guard !hasDelivered else { return }
        await withCheckedContinuation { deliveredWaiters.append($0) }
    }
}

private final class DelayedProfile404URLProtocol: URLProtocol {
    nonisolated(unsafe) static var controller: DelayedProfile404Controller?
    private var responseTask: Task<Void, Never>?

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path == "/auth/plugin/rownd/user"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let controller = Self.controller else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        responseTask = Task { [weak self] in
            await controller.markStarted()
            await controller.waitForRelease()
            guard let self, !Task.isCancelled else { return }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 404,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"status":"NOT_FOUND"}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
            await controller.markDelivered()
        }
    }

    override func stopLoading() {
        responseTask?.cancel()
    }
}

private actor DelayedExpectedSessionSaveController {
    private var hasStarted = false
    private var canRespond = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var responseWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var authorization: String?

    func markStarted(authorization: String?) {
        self.authorization = authorization
        hasStarted = true
        let waiters = startedWaiters
        startedWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitUntilStarted() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func waitForRelease() async {
        guard !canRespond else { return }
        await withCheckedContinuation { responseWaiters.append($0) }
    }

    func releaseResponse() {
        canRespond = true
        let waiters = responseWaiters
        responseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private final class DelayedExpectedSessionSaveURLProtocol: URLProtocol {
    nonisolated(unsafe) static var controller: DelayedExpectedSessionSaveController?
    private var responseTask: Task<Void, Never>?

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path == "/auth/plugin/rownd/user" && request.httpMethod == "PUT"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let controller = Self.controller else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        responseTask = Task { [weak self] in
            guard let self else { return }
            await controller.markStarted(
                authorization: request.value(forHTTPHeaderField: "Authorization")
            )
            await controller.waitForRelease()
            guard !Task.isCancelled else { return }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"data":{"email":"apple-captured@example.com"},"meta":{},"state":"enabled","auth_level":"verified"}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        responseTask?.cancel()
    }
}

private final class StatePersistenceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedSnapshots: [RowndState] = []

    var snapshots: [RowndState] {
        lock.lock(); defer { lock.unlock() }
        return recordedSnapshots
    }

    @MainActor func persist(_ state: RowndState) -> Bool {
        lock.lock(); defer { lock.unlock() }
        recordedSnapshots.append(state)
        return true
    }
}

// One in-memory store, shared by the core `TokenStorage` seam and the bridge's
// `SuperTokensSessionStorage`, so the core SDK reads/writes and the adopt-path's
// direct storage access stay on a single backing during tests.
//
// It must NOT be backed by UserDefaults.standard: core's `SDKStorage.set` writes to
// the token storage and then calls `UserDefaults.standard.removeObject(forKey:)` to
// purge the legacy-migration copy. A UserDefaults.standard-backed double is that same
// store, so every write would immediately erase itself and no session would ever be
// visible to a subsequent read. An in-memory dictionary sidesteps the legacy purge.
final class InMemorySessionStore: TokenStorage, SuperTokensSessionStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func get(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    @discardableResult
    func set(_ key: String, value: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
        return true
    }

    @discardableResult
    func remove(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        values.removeValue(forKey: key)
        return true
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        values.removeAll()
    }
}

private final class RecordingSessionStorage: SuperTokensSessionStorage {
    private(set) var removedKeys: [String] = []

    func get(_ key: String) -> String? {
        nil
    }

    func set(_ key: String, value: String) -> Bool {
        true
    }

    func remove(_ key: String) -> Bool {
        removedKeys.append(key)
        return true
    }
}

private final class FailingSessionStorage: TokenStorage, SuperTokensSessionStorage {
    var failingKey: String?
    private var values: [String: String] = [:]

    func get(_ key: String) -> String? {
        values[key]
    }

    func set(_ key: String, value: String) -> Bool {
        guard key != failingKey else { return false }
        values[key] = value
        return true
    }

    func remove(_ key: String) -> Bool {
        values.removeValue(forKey: key)
        return true
    }
}

private final class SuperTokensSignOutURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.absoluteString == "https://api.example.com/auth/signout"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: [
                "Content-Type": "application/json",
                "front-token": "remove",
            ]
        )!

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"status":"OK"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class LocalHTTPServer: @unchecked Sendable {
    struct CapturedRequest: Sendable {
        var path: String
        var headers: [String: String]
    }

    private(set) var baseURL: URL!

    private let listener: NWListener
    private let queue = DispatchQueue(label: "io.rownd.tests.local-http-server")
    private let requests: AsyncStream<CapturedRequest>
    private let requestContinuation: AsyncStream<CapturedRequest>.Continuation

    private init(listener: NWListener) {
        self.listener = listener

        var continuation: AsyncStream<CapturedRequest>.Continuation!
        self.requests = AsyncStream { continuation = $0 }
        self.requestContinuation = continuation
    }

    static func start() async throws -> LocalHTTPServer {
        let listener = try NWListener(using: .tcp, on: .any)
        let server = LocalHTTPServer(listener: listener)

        return try await withCheckedThrowingContinuation { continuation in
            var hasResumed = false

            listener.newConnectionHandler = { connection in
                server.handle(connection)
            }

            listener.stateUpdateHandler = { state in
                guard !hasResumed else { return }

                switch state {
                case .ready:
                    guard let port = listener.port else {
                        hasResumed = true
                        continuation.resume(throwing: RowndError("Local test server started without a port"))
                        return
                    }

                    server.baseURL = URL(string: "http://127.0.0.1:\(port.rawValue)")!
                    hasResumed = true
                    continuation.resume(returning: server)
                case .failed(let error):
                    hasResumed = true
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }

            listener.start(queue: DispatchQueue(label: "io.rownd.tests.local-http-listener"))
        }
    }

    func stop() {
        listener.cancel()
        requestContinuation.finish()
    }

    func nextRequest(timeout: TimeInterval = 2) async throws -> CapturedRequest {
        try await withThrowingTaskGroup(of: CapturedRequest.self) { group in
            group.addTask { [requests] in
                for await request in requests {
                    return request
                }
                throw RowndError("Local test server stopped before receiving a request")
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw RowndError("Timed out waiting for local test server request")
            }

            let request = try await group.next()!
            group.cancelAll()
            return request
        }
    }

    func nextRequestIfAvailable(timeout: TimeInterval = 0.5) async throws -> CapturedRequest? {
        try await withThrowingTaskGroup(of: CapturedRequest?.self) { group in
            group.addTask { [requests] in
                for await request in requests {
                    return request
                }
                throw RowndError("Local test server stopped before receiving a request")
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }

            let request = try await group.next()!
            group.cancelAll()
            return request
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, error in
            guard let self else { return }
            guard error == nil else {
                connection.cancel()
                return
            }

            var nextBuffer = buffer
            if let data {
                nextBuffer.append(data)
            }

            guard String(data: nextBuffer, encoding: .utf8)?.contains("\r\n\r\n") == true else {
                self.receive(on: connection, buffer: nextBuffer)
                return
            }

            self.requestContinuation.yield(Self.parseRequest(nextBuffer))
            self.sendResponse(on: connection)
        }
    }

    private func sendResponse(on connection: NWConnection) {
        let body = #"{"status":"OK"}"#
        let response = """
            HTTP/1.1 200 OK\r
            Content-Type: application/json\r
            Content-Length: \(body.utf8.count)\r
            front-token: remove\r
            Connection: close\r
            \r
            \(body)
            """

        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func parseRequest(_ data: Data) -> CapturedRequest {
        let rawRequest = String(data: data, encoding: .utf8) ?? ""
        let lines = rawRequest.components(separatedBy: "\r\n")
        let requestLineParts = (lines.first ?? "").split(separator: " ")
        var headers: [String: String] = [:]

        for line in lines.dropFirst() {
            guard let separatorIndex = line.firstIndex(of: ":") else { continue }
            let name = line[..<separatorIndex].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separatorIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }

        return CapturedRequest(
            path: requestLineParts.count > 1 ? String(requestLineParts[1]) : "",
            headers: headers
        )
    }
}
