import Foundation
import AnyCodable
import ReSwift
import Testing

@testable import Rownd

@Suite(.serialized) struct AppleSignUpCoordinatorTests {
    private static let appleSessionTokens = SuperTokensSessionTokens(
        accessToken: "apple-access-token",
        refreshToken: "apple-refresh-token",
        frontToken: "apple-front-token",
        antiCSRF: nil
    )
    private static let appleSessionIdentity = SuperTokensSessionBridge.SessionIdentity(
        accessToken: appleSessionTokens.accessToken,
        generation: 42,
        stable: SuperTokensSessionBridge.StableSessionIdentity(
            sessionHandle: "apple-session",
            userId: "apple-user",
            tenantId: nil
        )
    )

    @Test func syncPersistenceFailureDiscardsSessionBeforeFallback() async throws {
        try await withGlobalTestLock {
            let recorder = AppleSignInStepRecorder()
            let identities = AppleSessionIdentityRecorder()
            let originalDisplayHubHandler = Rownd.displayHubHandler
            let (store, originalAppConfig, originalSignIn) = await MainActor.run {
                let store = Context.currentContext.store
                return (store, store.state.appConfig, store.state.signIn)
            }
            defer { Rownd.displayHubHandler = originalDisplayHubHandler }

            Rownd.displayHubHandler = { _, options in
                guard let options = options as? RowndSignInJsOptions,
                      let loginStep = options.loginStep else {
                    return
                }
                recorder.append("hub-\(loginStep.rawValue)")
            }
            await MainActor.run {
                store.dispatch(SetAppConfig(payload: Self.appConfig(
                    iosClientType: "native-apple-client"
                )))
            }

            let coordinator = TestAppleSignUpCoordinator(Rownd.getInstance())
            coordinator.signInWithApple = { _, _ in
                recorder.append("exchange")
                return SuperTokensAppleSignInResponse(
                    status: "OK",
                    createdNewRecipeUser: true,
                    sessionTokens: Self.appleSessionTokens
                )
            }
            coordinator.syncAuthState = { identity, _ in
                identities.append(identity)
                recorder.append("sync-auth")
                return false
            }
            coordinator.onAdopt = { recorder.append("adopt") }
            coordinator.discardSessionIfCurrent = { identity in
                identities.append(identity)
                recorder.append("discard")
                return true
            }
            coordinator.waitBeforeCompletion = { recorder.append("wait") }
            coordinator.dismissHub = { _ in recorder.append("dismiss") }
            coordinator.emitEvent = { _ in recorder.append("event") }
            coordinator.onUpdateUserData = { _ in recorder.append("profile") }

            let hubRequestID = UUID()
            await MainActor.run {
                Rownd.requestSignInForNativeCompletion(
                    jsFnOptions: RowndSignInJsOptions(loginStep: .completing),
                    requestID: hubRequestID
                )
            }
            await coordinator.completeSignIn(
                authorizationCode: "apple-auth-code",
                fullName: nil,
                email: nil,
                intent: nil,
                hubRequestID: hubRequestID
            )

            #expect(recorder.steps == [
                "hub-completing",
                "exchange",
                "hub-success",
                "wait",
                "dismiss",
                "adopt",
                "sync-auth",
                "discard",
                "hub-error"
            ])
            #expect(identities.identities.count == 2)
            #expect(identities.identities[0] == identities.identities[1])
            let originalRequestIsActive = await Rownd.isNativeHubRequestActive(hubRequestID)
            #expect(!originalRequestIsActive)
            let signIn = await MainActor.run { store.state.signIn }
            #expect(signIn == originalSignIn)
            await MainActor.run {
                store.dispatch(SetAppConfig(payload: originalAppConfig))
            }
        }
    }

    @Test func dismissesHubBeforePublishingAuthAndEmittingSignInCompleted() async throws {
        try await withGlobalTestLock {
            let recorder = AppleSignInStepRecorder()
            let identityRecorder = AppleSessionIdentityRecorder()
            let allowDismissalToFinish = AppleSignInGate()
            let dismissalStarted = AppleSignInGate()
            let originalDisplayHubHandler = Rownd.displayHubHandler
            let (store, originalAppConfig) = await MainActor.run {
                let store = Context.currentContext.store
                return (store, store.state.appConfig)
            }

            Rownd.displayHubHandler = { _, options in
                guard let options = options as? RowndSignInJsOptions,
                      options.loginStep == .success else {
                    return
                }
                recorder.append("hub-success")
            }

            let coordinator = TestAppleSignUpCoordinator(Rownd.getInstance())
            coordinator.invalidateAuthOperationPermits = {
                recorder.append("permit-invalidated")
                SuperTokensSessionBridge.invalidateAuthOperationPermits()
            }
            coordinator.captureAuthOperationPermit = {
                recorder.append("permit-captured")
                return SuperTokensSessionBridge.captureAuthOperationPermit()
            }
            coordinator.signInWithApple = { authorizationCode, clientType in
                #expect(authorizationCode == "apple-auth-code")
                #expect(clientType == "native-apple-client")
                recorder.append("exchange")
                return SuperTokensAppleSignInResponse(
                    status: "OK",
                    createdNewRecipeUser: true,
                    sessionTokens: Self.appleSessionTokens
                )
            }
            coordinator.syncAuthState = { sessionIdentity, _ in
                identityRecorder.append(sessionIdentity)
                recorder.append("sync-auth")
                return true
            }
            coordinator.onAdopt = { recorder.append("adopt") }
            coordinator.waitBeforeCompletion = {
                recorder.append("wait")
            }
            coordinator.dismissHub = { _ in
                recorder.append("hub-dismiss-started")
                await dismissalStarted.open()
                await allowDismissalToFinish.wait()
                recorder.append("hub-dismissed")
            }
            coordinator.emitEvent = { event in
                #expect(event.event == .signInCompleted)
                #expect(event.data?["method"]??.value as? String == SignInType.apple.rawValue)
                #expect(event.data?["user_type"]??.value as? String == UserType.NewUser.rawValue)
                #expect(event.data?["app_variant_user_type"]??.value as? String == UserType.NewUser.rawValue)
                recorder.append("sign-in-completed")
            }
            coordinator.onUpdateUserData = { sessionIdentity in
                identityRecorder.append(sessionIdentity)
            }

            await MainActor.run {
                store.dispatch(SetAppConfig(payload: Self.appConfig(
                    iosClientType: "native-apple-client"
                )))
            }

            let hubRequestID = UUID()
            await MainActor.run {
                Rownd.requestSignInForNativeCompletion(
                    jsFnOptions: RowndSignInJsOptions(loginStep: .completing),
                    requestID: hubRequestID
                )
            }
            let signInTask = Task {
                await coordinator.completeSignIn(
                    authorizationCode: "apple-auth-code",
                    fullName: nil,
                    email: nil,
                    intent: .signUp,
                    hubRequestID: hubRequestID
                )
            }

            let didStartDismissal = await dismissalStarted.waitUntilOpen()
            #expect(!recorder.steps.contains("sync-auth"))
            #expect(!recorder.steps.contains("sign-in-completed"))
            await allowDismissalToFinish.open()
            await signInTask.value

            #expect(didStartDismissal)
            #expect(recorder.steps == [
                "permit-invalidated",
                "permit-captured",
                "exchange",
                "hub-success",
                "wait",
                "hub-dismiss-started",
                "hub-dismissed",
                "adopt",
                "sync-auth",
                "sign-in-completed"
            ])
            #expect(identityRecorder.identities.count == 2)
            #expect(identityRecorder.identities[0] == identityRecorder.identities[1])
            Rownd.displayHubHandler = originalDisplayHubHandler
            await MainActor.run {
                store.dispatch(SetAppConfig(payload: originalAppConfig))
            }
        }
    }

    @Test func failedSessionAdoptionShowsSyncFailureWithoutSyncOrCompletion() async throws {
        try await withGlobalTestLock {
            let recorder = AppleSignInStepRecorder()
            let originalDisplayHubHandler = Rownd.displayHubHandler
            let (store, originalAppConfig) = await MainActor.run {
                let store = Context.currentContext.store
                return (store, store.state.appConfig)
            }
            defer { Rownd.displayHubHandler = originalDisplayHubHandler }
            Rownd.displayHubHandler = { _, options in
                guard let options = options as? RowndSignInJsOptions,
                      let loginStep = options.loginStep else { return }
                recorder.append("hub-\(loginStep.rawValue)")
            }
            await MainActor.run {
                store.dispatch(SetAppConfig(payload: Self.appConfig(
                    iosClientType: "native-apple-client"
                )))
            }

            let coordinator = TestAppleSignUpCoordinator(Rownd.getInstance())
            coordinator.signInWithApple = { _, _ in
                SuperTokensAppleSignInResponse(
                    status: "OK",
                    createdNewRecipeUser: false,
                    sessionTokens: Self.appleSessionTokens
                )
            }
            coordinator.adoptResponseSession = { _, _ in
                recorder.append("adopt")
                return nil
            }
            coordinator.syncAuthState = { _, _ in
                Issue.record("A failed adoption must not synchronize auth")
                return true
            }
            coordinator.waitBeforeCompletion = {}
            coordinator.dismissHub = { _ in recorder.append("dismiss") }
            coordinator.emitEvent = { _ in Issue.record("A failed adoption must not emit completion") }

            let requestID = UUID()
            await MainActor.run {
                Rownd.requestSignInForNativeCompletion(
                    jsFnOptions: RowndSignInJsOptions(loginStep: .completing),
                    requestID: requestID
                )
            }
            await coordinator.completeSignIn(
                authorizationCode: "apple-auth-code",
                fullName: nil,
                email: nil,
                intent: nil,
                hubRequestID: requestID
            )

            #expect(recorder.steps == [
                "hub-completing",
                "hub-success",
                "dismiss",
                "adopt",
                "hub-error"
            ])
            await MainActor.run {
                store.dispatch(SetAppConfig(payload: originalAppConfig))
            }
        }
    }

    @Test func refusedSigninupShowsErrorAndEmitsSignInFailedWithoutCompletion() async throws {
        try await withGlobalTestLock {
            let recorder = AppleSignInStepRecorder()
            let events = AppleEventRecorder()
            let originalDisplayHubHandler = Rownd.displayHubHandler
            let (store, originalAppConfig) = await MainActor.run {
                let store = Context.currentContext.store
                return (store, store.state.appConfig)
            }
            defer { Rownd.displayHubHandler = originalDisplayHubHandler }
            Rownd.displayHubHandler = { _, options in
                guard let options = options as? RowndSignInJsOptions,
                      let loginStep = options.loginStep else { return }
                recorder.append("hub-\(loginStep.rawValue)")
            }
            await MainActor.run {
                store.dispatch(SetAppConfig(payload: Self.appConfig(
                    iosClientType: "native-apple-client"
                )))
            }

            let coordinator = TestAppleSignUpCoordinator(Rownd.getInstance())
            coordinator.signInWithApple = { _, _ in
                throw SuperTokensSignInUpRefusedError(
                    status: "SIGN_IN_UP_NOT_ALLOWED",
                    reason: "Cannot sign in / up due to security reasons."
                )
            }
            coordinator.onAdopt = { Issue.record("A refused signinup must not adopt a session") }
            coordinator.syncAuthState = { _, _ in
                Issue.record("A refused signinup must not synchronize auth")
                return true
            }
            coordinator.waitBeforeCompletion = {}
            coordinator.dismissHub = { _ in recorder.append("dismiss") }
            coordinator.emitEvent = { event in events.append(event) }

            let requestID = UUID()
            await MainActor.run {
                Rownd.requestSignInForNativeCompletion(
                    jsFnOptions: RowndSignInJsOptions(loginStep: .completing),
                    requestID: requestID
                )
            }
            await coordinator.completeSignIn(
                authorizationCode: "apple-auth-code",
                fullName: nil,
                email: nil,
                intent: nil,
                hubRequestID: requestID
            )

            #expect(recorder.steps == ["hub-completing", "hub-error"])
            #expect(events.events.map(\.event) == [.signInFailed])
            let data = try #require(events.events.first?.data)
            #expect(data["reason"]??.value as? String == "SIGN_IN_UP_NOT_ALLOWED")
            #expect(data["message"]??.value as? String == "Cannot sign in / up due to security reasons.")
            #expect(data["method"]??.value as? String == SignInType.apple.rawValue)
            await MainActor.run {
                store.dispatch(SetAppConfig(payload: originalAppConfig))
            }
        }
    }

    @Test func appleEnrichmentUsesOnlyOperationScopedData() throws {
        let legacyKey = "userAppleSignInData"
        UserDefaults.standard.set(
            try JSONEncoder().encode(AppleSignInData(
                email: "stale@example.com",
                firstName: nil,
                lastName: nil,
                fullName: nil
            )),
            forKey: legacyKey
        )
        defer { UserDefaults.standard.removeObject(forKey: legacyKey) }

        var fullName = PersonNameComponents()
        fullName.givenName = "Current"
        fullName.familyName = "User"
        let data = AppleSignUpCoordinator.appleUserData(
            fullName: fullName,
            email: "current@example.com"
        )

        #expect(data["email"]?.value as? String == "current@example.com")
        #expect(data["first_name"]?.value as? String == "Current")
        #expect(data["full_name"]?.value as? String == "Current User")
    }

    @Test func appleProfile404KeepsPendingSessionAndSchedulesRetry() async throws {
        try await withGlobalTestLock {
            let originalContext = Context.currentContext
            let store = createStore()
            _ = Context(store)
            defer { Context.currentContext = originalContext }
            let identity = Self.profileHydrationIdentity(sessionHandle: "apple-profile-404")
            await MainActor.run {
                var auth = AuthState(accessToken: identity.accessToken)
                auth.profileHydrationPendingSessionIdentity = identity.stable
                store.dispatch(SetAuthState(payload: auth))
            }
            let state = try #require(await MainActor.run { store.state })
            let scheduledIdentities = AppleStableIdentityRecorder()
            let coordinator = TestAppleSignUpCoordinator(Rownd.getInstance())
            coordinator.signOutIfCurrentSession = { _, _, _ in
                Issue.record("Pending profile hydration must not sign out")
                return true
            }

            let didEnrich = await coordinator.enrichUserDataWithAppleData(
                fullName: nil,
                email: "apple@example.com",
                state: state,
                sessionIdentity: identity,
                fetchUserData: { _ in .notFound },
                persistState: { _ in
                    Issue.record("A missing profile must not persist state")
                    return true
                },
                scheduleProfileHydrationRetry: { stableIdentity in
                    scheduledIdentities.append(stableIdentity)
                }
            )

            #expect(!didEnrich)
            #expect(scheduledIdentities.identities == [identity.stable])
            await MainActor.run {
                #expect(store.state.auth.accessToken == identity.accessToken)
                #expect(
                    store.state.auth.profileHydrationPendingSessionIdentity
                        == identity.stable
                )
            }
        }
    }

    @Test func successfulAppleEnrichmentPersistsProfileAndClearsPendingMarker() async throws {
        try await withGlobalTestLock {
            let originalContext = Context.currentContext
            let store = createStore()
            _ = Context(store)
            defer { Context.currentContext = originalContext }
            let identity = Self.profileHydrationIdentity(sessionHandle: "apple-profile-success")
            await MainActor.run {
                var auth = AuthState(accessToken: identity.accessToken)
                auth.profileHydrationPendingSessionIdentity = identity.stable
                store.dispatch(SetAuthState(payload: auth))
                store.dispatch(SetUserState(payload: UserState(data: [
                    "email": AnyCodable("before@example.com")
                ])))
            }
            let state = try #require(await MainActor.run { store.state })
            let coordinator = TestAppleSignUpCoordinator(Rownd.getInstance())
            coordinator.saveExpectedSession = { data, expectedData, savedIdentity, _ in
                #expect(data["email"]?.value as? String == "apple@example.com")
                #expect(expectedData["email"]?.value as? String == "before@example.com")
                #expect(savedIdentity == identity)
                await MainActor.run {
                    store.dispatch(SetUserData(data: [
                        "email": AnyCodable("apple@example.com"),
                        "user_id": AnyCodable("apple-user")
                    ]))
                }
                return true
            }
            var persistedState: RowndState?
            let canonicalProfile = UserStateResponse(
                data: [
                    "email": AnyCodable("canonical@example.com"),
                    "user_id": AnyCodable("apple-user")
                ],
                meta: ["source": AnyCodable("canonical")],
                state: .enabled,
                authLevel: .verified
            )

            let didEnrich = await coordinator.enrichUserDataWithAppleData(
                fullName: nil,
                email: "apple@example.com",
                state: state,
                sessionIdentity: identity,
                fetchUserData: { _ in .profile(canonicalProfile) },
                persistState: { candidate in
                    persistedState = candidate
                    return true
                },
                scheduleProfileHydrationRetry: { _ in
                    Issue.record("A successful profile fetch must not schedule a retry")
                }
            )

            #expect(didEnrich)
            #expect(persistedState?.auth.profileHydrationPendingSessionIdentity == nil)
            #expect(persistedState?.user.data["email"]?.value as? String == "apple@example.com")
            #expect(persistedState?.user.meta?["source"]?.value as? String == "canonical")
            await MainActor.run {
                #expect(store.state.auth.profileHydrationPendingSessionIdentity == nil)
                #expect(store.state.user.data["email"]?.value as? String == "apple@example.com")
                #expect(store.state.user.meta?["source"]?.value as? String == "canonical")
            }
        }
    }

    @Test func appleProfile404WithoutPendingHydrationUsesExistingSignOutBehavior() async throws {
        try await withGlobalTestLock {
            let originalContext = Context.currentContext
            let store = createStore()
            _ = Context(store)
            defer { Context.currentContext = originalContext }
            let identity = Self.profileHydrationIdentity(sessionHandle: "apple-profile-deleted")
            await MainActor.run {
                store.dispatch(SetAuthState(payload: AuthState(accessToken: identity.accessToken)))
            }
            let state = try #require(await MainActor.run { store.state })
            let recorder = AppleSignInStepRecorder()
            let coordinator = TestAppleSignUpCoordinator(Rownd.getInstance())
            coordinator.signOutIfCurrentSession = { signedOutIdentity, accessToken, condition in
                #expect(signedOutIdentity == identity)
                #expect(accessToken == identity.accessToken)
                #expect(condition())
                recorder.append("sign-out")
                return true
            }

            let didEnrich = await coordinator.enrichUserDataWithAppleData(
                fullName: nil,
                email: nil,
                state: state,
                sessionIdentity: identity,
                fetchUserData: { _ in .notFound },
                scheduleProfileHydrationRetry: { _ in
                    Issue.record("Deleted profiles must not schedule hydration retry")
                }
            )

            #expect(!didEnrich)
            #expect(recorder.steps == ["sign-out"])
        }
    }

    @Test func appleEnrichmentWithoutEmailCommitsCanonicalProfileAndClearsMarker() async throws {
        try await withGlobalTestLock {
            let originalContext = Context.currentContext
            let store = createStore()
            _ = Context(store)
            defer { Context.currentContext = originalContext }
            let identity = Self.profileHydrationIdentity(sessionHandle: "apple-profile-no-email")
            await MainActor.run {
                var auth = AuthState(accessToken: identity.accessToken)
                auth.profileHydrationPendingSessionIdentity = identity.stable
                store.dispatch(SetAuthState(payload: auth))
            }
            let state = try #require(await MainActor.run { store.state })
            let coordinator = TestAppleSignUpCoordinator(Rownd.getInstance())
            coordinator.saveExpectedSession = { _, _, _, _ in
                Issue.record("No Apple data must skip profile save")
                return true
            }
            let canonicalProfile = UserStateResponse(
                data: [
                    "email": AnyCodable("canonical@example.com"),
                    "user_id": AnyCodable("apple-user")
                ],
                meta: ["source": AnyCodable("canonical")],
                state: .enabled,
                authLevel: .verified
            )
            var persistedState: RowndState?

            let didEnrich = await coordinator.enrichUserDataWithAppleData(
                fullName: nil,
                email: nil,
                state: state,
                sessionIdentity: identity,
                fetchUserData: { _ in .profile(canonicalProfile) },
                persistState: { candidate in
                    persistedState = candidate
                    return true
                }
            )

            #expect(didEnrich)
            #expect(persistedState?.auth.profileHydrationPendingSessionIdentity == nil)
            #expect(
                persistedState?.user.data["email"]?.value as? String
                    == "canonical@example.com"
            )
            await MainActor.run {
                #expect(store.state.auth.profileHydrationPendingSessionIdentity == nil)
                #expect(
                    store.state.user.data["email"]?.value as? String
                        == "canonical@example.com"
                )
            }
        }
    }

    @Test func appleProfileSaveFailureLeavesPendingMarkerAndSkipsPersistence() async throws {
        try await withGlobalTestLock {
            let originalContext = Context.currentContext
            let store = createStore()
            _ = Context(store)
            defer { Context.currentContext = originalContext }
            let identity = Self.profileHydrationIdentity(sessionHandle: "apple-profile-save-failure")
            await MainActor.run {
                var auth = AuthState(accessToken: identity.accessToken)
                auth.profileHydrationPendingSessionIdentity = identity.stable
                store.dispatch(SetAuthState(payload: auth))
            }
            let state = try #require(await MainActor.run { store.state })
            let coordinator = TestAppleSignUpCoordinator(Rownd.getInstance())
            coordinator.saveExpectedSession = { _, _, _, _ in false }

            let didEnrich = await coordinator.enrichUserDataWithAppleData(
                fullName: nil,
                email: "apple@example.com",
                state: state,
                sessionIdentity: identity,
                fetchUserData: { _ in .profile(UserStateResponse()) },
                persistState: { _ in
                    Issue.record("A failed Apple profile save must not persist hydration")
                    return true
                }
            )

            #expect(!didEnrich)
            await MainActor.run {
                #expect(
                    store.state.auth.profileHydrationPendingSessionIdentity
                        == identity.stable
                )
            }
        }
    }

    @Test func appleEnrichmentPersistenceFailureLeavesPendingMarker() async throws {
        try await withGlobalTestLock {
            let originalContext = Context.currentContext
            let store = createStore()
            _ = Context(store)
            defer { Context.currentContext = originalContext }
            let identity = Self.profileHydrationIdentity(sessionHandle: "apple-profile-persist-failure")
            await MainActor.run {
                var auth = AuthState(accessToken: identity.accessToken)
                auth.profileHydrationPendingSessionIdentity = identity.stable
                store.dispatch(SetAuthState(payload: auth))
            }
            let state = try #require(await MainActor.run { store.state })
            let coordinator = TestAppleSignUpCoordinator(Rownd.getInstance())
            coordinator.saveExpectedSession = { _, _, _, _ in true }
            let canonicalProfile = UserStateResponse(data: [
                "email": AnyCodable("canonical@example.com")
            ])

            let didEnrich = await coordinator.enrichUserDataWithAppleData(
                fullName: nil,
                email: "apple@example.com",
                state: state,
                sessionIdentity: identity,
                fetchUserData: { _ in .profile(canonicalProfile) },
                persistState: { _ in false }
            )

            #expect(!didEnrich)
            await MainActor.run {
                #expect(
                    store.state.auth.profileHydrationPendingSessionIdentity
                        == identity.stable
                )
            }
        }
    }

    @Test func signOutInvalidationBeforeAdoptionDoesNotPresentFallback() async throws {
        try await withGlobalTestLock {
            let recorder = AppleSignInStepRecorder()
            let adoptionStarted = AppleSignInGate()
            let finishAdoption = AppleSignInGate()
            let originalDisplayHubHandler = Rownd.displayHubHandler
            let (store, originalAppConfig) = await MainActor.run {
                let store = Context.currentContext.store
                return (store, store.state.appConfig)
            }
            defer { Rownd.displayHubHandler = originalDisplayHubHandler }
            Rownd.displayHubHandler = { _, options in
                guard let options = options as? RowndSignInJsOptions,
                      let loginStep = options.loginStep else { return }
                recorder.append("hub-\(loginStep.rawValue)")
            }
            await MainActor.run {
                store.dispatch(SetAppConfig(payload: Self.appConfig(
                    iosClientType: "native-apple-client"
                )))
            }

            let coordinator = TestAppleSignUpCoordinator(Rownd.getInstance())
            coordinator.signInWithApple = { _, _ in
                SuperTokensAppleSignInResponse(
                    status: "OK",
                    createdNewRecipeUser: false,
                    sessionTokens: Self.appleSessionTokens
                )
            }
            coordinator.waitBeforeCompletion = {}
            coordinator.dismissHub = { _ in recorder.append("dismiss") }
            coordinator.adoptResponseSession = { _, _ in
                recorder.append("adopt-start")
                await adoptionStarted.open()
                await finishAdoption.wait()
                recorder.append("adopt-finish")
                return nil
            }
            coordinator.syncAuthState = { _, _ in
                Issue.record("Sign-out invalidation must prevent sync")
                return true
            }
            coordinator.emitEvent = { _ in Issue.record("Sign-out invalidation must prevent completion") }

            let requestID = UUID()
            await MainActor.run {
                Rownd.requestSignInForNativeCompletion(
                    jsFnOptions: RowndSignInJsOptions(loginStep: .completing),
                    requestID: requestID
                )
            }
            let signInTask = Task {
                await coordinator.completeSignIn(
                    authorizationCode: "apple-auth-code",
                    fullName: nil,
                    email: nil,
                    intent: nil,
                    hubRequestID: requestID
                )
            }
            await adoptionStarted.wait()

            SuperTokensSessionBridge.invalidateAuthOperationPermits()
            await finishAdoption.open()
            await signInTask.value

            #expect(recorder.steps == [
                "hub-completing",
                "hub-success",
                "dismiss",
                "adopt-start",
                "adopt-finish"
            ])
            await MainActor.run {
                coordinator.cancelCurrentOperation()
                store.dispatch(SetAppConfig(payload: originalAppConfig))
            }
        }
    }

    @Test func permitInvalidationDuringAdoptionDiscardsExactSession() async throws {
        try await withGlobalTestLock {
            let recorder = AppleSignInStepRecorder()
            let identities = AppleSessionIdentityRecorder()
            let adoptionStarted = AppleSignInGate()
            let finishAdoption = AppleSignInGate()
            let originalDisplayHubHandler = Rownd.displayHubHandler
            let (store, originalAppConfig) = await MainActor.run {
                let store = Context.currentContext.store
                return (store, store.state.appConfig)
            }
            defer { Rownd.displayHubHandler = originalDisplayHubHandler }
            Rownd.displayHubHandler = { _, _ in }
            await MainActor.run {
                store.dispatch(SetAppConfig(payload: Self.appConfig(
                    iosClientType: "native-apple-client"
                )))
            }

            let coordinator = TestAppleSignUpCoordinator(Rownd.getInstance())
            coordinator.signInWithApple = { _, _ in
                SuperTokensAppleSignInResponse(
                    status: "OK",
                    createdNewRecipeUser: false,
                    sessionTokens: Self.appleSessionTokens
                )
            }
            coordinator.waitBeforeCompletion = {}
            coordinator.dismissHub = { _ in }
            coordinator.adoptResponseSession = { _, _ in
                recorder.append("adopt-start")
                await adoptionStarted.open()
                await finishAdoption.wait()
                recorder.append("adopt-finish")
                return Self.appleSessionIdentity
            }
            coordinator.discardSessionIfCurrent = { identity in
                identities.append(identity)
                recorder.append("discard")
                return true
            }
            coordinator.syncAuthState = { _, _ in
                Issue.record("An invalidated permit must prevent sync")
                return true
            }
            coordinator.emitEvent = { _ in Issue.record("An invalidated permit must prevent completion") }

            let requestID = UUID()
            await MainActor.run {
                Rownd.requestSignInForNativeCompletion(
                    jsFnOptions: RowndSignInJsOptions(loginStep: .completing),
                    requestID: requestID
                )
            }
            let signInTask = Task {
                await coordinator.completeSignIn(
                    authorizationCode: "apple-auth-code",
                    fullName: nil,
                    email: nil,
                    intent: nil,
                    hubRequestID: requestID
                )
            }
            await adoptionStarted.wait()

            SuperTokensSessionBridge.invalidateAuthOperationPermits()
            await finishAdoption.open()
            await signInTask.value

            #expect(recorder.steps == ["adopt-start", "adopt-finish", "discard"])
            #expect(identities.identities == [Self.appleSessionIdentity])
            await MainActor.run {
                store.dispatch(SetAppConfig(payload: originalAppConfig))
            }
        }
    }

    @Test func newerGenericHubDuringAdoptionDiscardsExactSessionAndBlocksCompletion() async throws {
        try await withGlobalTestLock {
            let recorder = AppleSignInStepRecorder()
            let identities = AppleSessionIdentityRecorder()
            let adoptionStarted = AppleSignInGate()
            let finishAdoption = AppleSignInGate()
            let originalDisplayHubHandler = Rownd.displayHubHandler
            let (store, originalAppConfig) = await MainActor.run {
                let store = Context.currentContext.store
                return (store, store.state.appConfig)
            }
            defer { Rownd.displayHubHandler = originalDisplayHubHandler }
            Rownd.displayHubHandler = { _, options in
                guard let options = options as? RowndSignInJsOptions,
                      let loginStep = options.loginStep else { return }
                recorder.append("hub-\(loginStep.rawValue)")
            }
            await MainActor.run {
                store.dispatch(SetAppConfig(payload: Self.appConfig(
                    iosClientType: "native-apple-client"
                )))
            }

            let coordinator = TestAppleSignUpCoordinator(Rownd.getInstance())
            coordinator.signInWithApple = { _, _ in
                SuperTokensAppleSignInResponse(
                    status: "OK",
                    createdNewRecipeUser: false,
                    sessionTokens: Self.appleSessionTokens
                )
            }
            coordinator.waitBeforeCompletion = {}
            coordinator.dismissHub = { _ in recorder.append("dismiss") }
            coordinator.adoptResponseSession = { _, _ in
                recorder.append("adopt-start")
                await adoptionStarted.open()
                await finishAdoption.wait()
                recorder.append("adopt-finish")
                return Self.appleSessionIdentity
            }
            coordinator.discardSessionIfCurrent = { identity in
                identities.append(identity)
                recorder.append("discard")
                return true
            }
            coordinator.syncAuthState = { _, _ in
                Issue.record("A newer Hub must prevent sync")
                return true
            }
            coordinator.emitEvent = { _ in Issue.record("A newer Hub must prevent completion") }
            coordinator.onUpdateUserData = { _ in Issue.record("A newer Hub must prevent enrichment") }

            let appleRequestID = UUID()
            let newerRequestID = UUID()
            await MainActor.run {
                Rownd.requestSignInForNativeCompletion(
                    jsFnOptions: RowndSignInJsOptions(loginStep: .completing),
                    requestID: appleRequestID
                )
            }
            let signInTask = Task {
                await coordinator.completeSignIn(
                    authorizationCode: "apple-auth-code",
                    fullName: nil,
                    email: nil,
                    intent: nil,
                    hubRequestID: appleRequestID
                )
            }
            await adoptionStarted.wait()
            await MainActor.run {
                Rownd.requestSignInForNativeCompletion(
                    jsFnOptions: RowndSignInJsOptions(loginStep: .completing),
                    requestID: newerRequestID
                )
            }
            await finishAdoption.open()
            await signInTask.value

            #expect(recorder.steps == [
                "hub-completing",
                "hub-success",
                "dismiss",
                "adopt-start",
                "hub-completing",
                "adopt-finish",
                "discard"
            ])
            #expect(identities.identities == [Self.appleSessionIdentity])
            #expect(await Rownd.isNativeHubRequestActive(newerRequestID))
            await MainActor.run {
                store.dispatch(SetAppConfig(payload: originalAppConfig))
            }
        }
    }

    @Test func cancelCurrentOperationRetiresHubAndPreventsNetworkCompletion() async throws {
        try await withGlobalTestLock {
            let recorder = AppleSignInStepRecorder()
            let exchangeStarted = AppleSignInGate()
            let finishExchange = AppleSignInGate()
            let hubRetired = AppleSignInGate()
            let originalDisplayHubHandler = Rownd.displayHubHandler
            let (store, originalAppConfig) = await MainActor.run {
                let store = Context.currentContext.store
                return (store, store.state.appConfig)
            }
            defer { Rownd.displayHubHandler = originalDisplayHubHandler }
            Rownd.displayHubHandler = { _, _ in }
            await MainActor.run {
                store.dispatch(SetAppConfig(payload: Self.appConfig(
                    iosClientType: "native-apple-client"
                )))
            }

            let coordinator = TestAppleSignUpCoordinator(Rownd.getInstance())
            coordinator.signInWithApple = { _, _ in
                recorder.append("exchange-start")
                await exchangeStarted.open()
                await finishExchange.wait()
                recorder.append("exchange-finish")
                return SuperTokensAppleSignInResponse(
                    status: "OK",
                    createdNewRecipeUser: false,
                    sessionTokens: Self.appleSessionTokens
                )
            }
            coordinator.dismissHub = { _ in
                recorder.append("retire")
                await hubRetired.open()
            }
            coordinator.onAdopt = { recorder.append("adopt") }
            coordinator.syncAuthState = { _, _ in
                Issue.record("A cancelled operation must not sync")
                return true
            }
            coordinator.emitEvent = { _ in Issue.record("A cancelled operation must not complete") }

            let requestID = UUID()
            await MainActor.run {
                Rownd.requestSignInForNativeCompletion(
                    jsFnOptions: RowndSignInJsOptions(loginStep: .completing),
                    requestID: requestID
                )
            }
            let signInTask = Task {
                await coordinator.completeSignIn(
                    authorizationCode: "apple-auth-code",
                    fullName: nil,
                    email: nil,
                    intent: nil,
                    hubRequestID: requestID
                )
            }
            await exchangeStarted.wait()

            await MainActor.run { coordinator.cancelCurrentOperation() }
            await hubRetired.wait()
            await finishExchange.open()
            await signInTask.value

            #expect(recorder.steps == ["exchange-start", "retire", "exchange-finish"])
            await MainActor.run {
                store.dispatch(SetAppConfig(payload: originalAppConfig))
            }
        }
    }

    @Test func newerHubDuringCompletionDelaySuppressesAuthPublicationAndCompletion() async throws {
        try await withGlobalTestLock {
            let recorder = AppleSignInStepRecorder()
            let completionDelayStarted = AppleSignInGate()
            let finishCompletionDelay = AppleSignInGate()
            let originalDisplayHubHandler = Rownd.displayHubHandler
            let (store, originalAppConfig) = await MainActor.run {
                let store = Context.currentContext.store
                return (store, store.state.appConfig)
            }
            defer { Rownd.displayHubHandler = originalDisplayHubHandler }

            Rownd.displayHubHandler = { _, options in
                guard let options = options as? RowndSignInJsOptions,
                      let loginStep = options.loginStep else {
                    return
                }
                recorder.append("hub-\(loginStep.rawValue)")
            }
            await MainActor.run {
                store.dispatch(SetAppConfig(payload: Self.appConfig(
                    iosClientType: "native-apple-client"
                )))
            }

            let coordinator = TestAppleSignUpCoordinator(Rownd.getInstance())
            coordinator.signInWithApple = { _, _ in
                recorder.append("exchange")
                return SuperTokensAppleSignInResponse(
                    status: "OK",
                    createdNewRecipeUser: false,
                    sessionTokens: Self.appleSessionTokens
                )
            }
            coordinator.syncAuthState = { _, _ in
                recorder.append("sync")
                return true
            }
            coordinator.waitBeforeCompletion = {
                await completionDelayStarted.open()
                await finishCompletionDelay.wait()
            }
            coordinator.dismissHub = { _ in recorder.append("dismiss") }
            coordinator.onAdopt = { recorder.append("adopt") }
            coordinator.emitEvent = { _ in recorder.append("event") }
            coordinator.onUpdateUserData = { _ in recorder.append("profile") }

            let appleRequestID = UUID()
            let newerRequestID = UUID()
            await MainActor.run {
                Rownd.requestSignInForNativeCompletion(
                    jsFnOptions: RowndSignInJsOptions(loginStep: .completing),
                    requestID: appleRequestID
                )
            }
            let signInTask = Task {
                await coordinator.completeSignIn(
                    authorizationCode: "apple-auth-code",
                    fullName: nil,
                    email: nil,
                    intent: nil,
                    hubRequestID: appleRequestID
                )
            }

            await completionDelayStarted.wait()
            await MainActor.run {
                Rownd.requestSignInForNativeCompletion(
                    jsFnOptions: RowndSignInJsOptions(loginStep: .completing),
                    requestID: newerRequestID
                )
            }
            await finishCompletionDelay.open()
            await signInTask.value

            #expect(recorder.steps == [
                "hub-completing",
                "exchange",
                "hub-success",
                "hub-completing"
            ])
            #expect(await Rownd.isNativeHubRequestActive(newerRequestID))
            await MainActor.run {
                store.dispatch(SetAppConfig(payload: originalAppConfig))
            }
        }
    }

    @Test func ownershipLossDuringSyncDiscardsSessionWithoutFallback() async throws {
        try await withGlobalTestLock {
            let recorder = AppleSignInStepRecorder()
            let identities = AppleSessionIdentityRecorder()
            let syncStarted = AppleSignInGate()
            let finishSync = AppleSignInGate()
            let originalDisplayHubHandler = Rownd.displayHubHandler
            let (store, originalAppConfig) = await MainActor.run {
                let store = Context.currentContext.store
                return (store, store.state.appConfig)
            }
            defer { Rownd.displayHubHandler = originalDisplayHubHandler }

            Rownd.displayHubHandler = { _, options in
                guard let options = options as? RowndSignInJsOptions,
                      let loginStep = options.loginStep else {
                    return
                }
                recorder.append("hub-\(loginStep.rawValue)")
            }
            await MainActor.run {
                store.dispatch(SetAppConfig(payload: Self.appConfig(
                    iosClientType: "native-apple-client"
                )))
            }

            let coordinator = TestAppleSignUpCoordinator(Rownd.getInstance())
            coordinator.signInWithApple = { _, _ in
                SuperTokensAppleSignInResponse(
                    status: "OK",
                    createdNewRecipeUser: false,
                    sessionTokens: Self.appleSessionTokens
                )
            }
            coordinator.syncAuthState = { identity, _ in
                identities.append(identity)
                await syncStarted.open()
                await finishSync.wait()
                return false
            }
            coordinator.waitBeforeCompletion = {}
            coordinator.dismissHub = { _ in }
            coordinator.discardSessionIfCurrent = { identity in
                identities.append(identity)
                recorder.append("discard")
                return true
            }
            coordinator.emitEvent = { _ in recorder.append("event") }
            coordinator.onUpdateUserData = { _ in recorder.append("profile") }

            let appleRequestID = UUID()
            let newerRequestID = UUID()
            await MainActor.run {
                Rownd.requestSignInForNativeCompletion(
                    jsFnOptions: RowndSignInJsOptions(loginStep: .completing),
                    requestID: appleRequestID
                )
            }
            let signInTask = Task {
                await coordinator.completeSignIn(
                    authorizationCode: "apple-auth-code",
                    fullName: nil,
                    email: nil,
                    intent: nil,
                    hubRequestID: appleRequestID
                )
            }

            await syncStarted.wait()
            await MainActor.run {
                Rownd.requestSignInForNativeCompletion(
                    jsFnOptions: RowndSignInJsOptions(loginStep: .completing),
                    requestID: newerRequestID
                )
            }
            await finishSync.open()
            await signInTask.value

            #expect(recorder.steps == [
                "hub-completing",
                "hub-success",
                "hub-completing",
                "discard"
            ])
            #expect(identities.identities.count == 2)
            #expect(identities.identities[0] == identities.identities[1])
            #expect(await Rownd.isNativeHubRequestActive(newerRequestID))
            await MainActor.run {
                store.dispatch(SetAppConfig(payload: originalAppConfig))
            }
        }
    }

    @Test func newerCompletionInvalidatesOverlappingAppleSignIn() async throws {
        try await withGlobalTestLock {
            let recorder = AppleSignInStepRecorder()
            let firstExchangeStarted = AppleSignInGate()
            let finishFirstExchange = AppleSignInGate()
            let originalDisplayHubHandler = Rownd.displayHubHandler
            let (store, originalAppConfig) = await MainActor.run {
                let store = Context.currentContext.store
                return (store, store.state.appConfig)
            }
            defer { Rownd.displayHubHandler = originalDisplayHubHandler }
            Rownd.displayHubHandler = { _, _ in }
            await MainActor.run {
                store.dispatch(SetAppConfig(payload: Self.appConfig(
                    iosClientType: "native-apple-client"
                )))
            }

            let coordinator = TestAppleSignUpCoordinator(Rownd.getInstance())
            coordinator.invalidateAuthOperationPermits = {
                recorder.append("permit-invalidated")
                SuperTokensSessionBridge.invalidateAuthOperationPermits()
            }
            coordinator.captureAuthOperationPermit = {
                recorder.append("permit-captured")
                return SuperTokensSessionBridge.captureAuthOperationPermit()
            }
            coordinator.signInWithApple = { authorizationCode, _ in
                recorder.append("exchange-\(authorizationCode)")
                if authorizationCode == "first" {
                    await firstExchangeStarted.open()
                    await finishFirstExchange.wait()
                }
                return SuperTokensAppleSignInResponse(
                    status: "OK",
                    createdNewRecipeUser: authorizationCode == "second",
                    sessionTokens: Self.appleSessionTokens
                )
            }
            coordinator.syncAuthState = { _, _ in
                recorder.append("sync")
                return true
            }
            coordinator.waitBeforeCompletion = {}
            coordinator.dismissHub = { _ in }
            coordinator.onAdopt = { recorder.append("adopt") }
            coordinator.emitEvent = { _ in recorder.append("event") }
            coordinator.onUpdateUserData = { _ in recorder.append("profile") }

            let firstRequestID = UUID()
            let secondRequestID = UUID()
            await MainActor.run {
                Rownd.requestSignInForNativeCompletion(
                    jsFnOptions: RowndSignInJsOptions(loginStep: .completing),
                    requestID: firstRequestID
                )
            }
            let firstTask = Task {
                await coordinator.completeSignIn(
                    authorizationCode: "first",
                    fullName: nil,
                    email: nil,
                    intent: nil,
                    hubRequestID: firstRequestID
                )
            }
            await firstExchangeStarted.wait()
            await MainActor.run {
                Rownd.requestSignInForNativeCompletion(
                    jsFnOptions: RowndSignInJsOptions(loginStep: .completing),
                    requestID: secondRequestID
                )
            }
            await coordinator.completeSignIn(
                authorizationCode: "second",
                fullName: nil,
                email: nil,
                intent: nil,
                hubRequestID: secondRequestID
            )
            await finishFirstExchange.open()
            await firstTask.value

            #expect(recorder.steps == [
                "permit-invalidated",
                "permit-captured",
                "exchange-first",
                "permit-invalidated",
                "permit-captured",
                "exchange-second",
                "adopt",
                "sync",
                "profile",
                "event"
            ])
            await MainActor.run {
                store.dispatch(SetAppConfig(payload: originalAppConfig))
            }
        }
    }

    @Test func newerAppleOperationInvalidatesInFlightSyncBeforeAuthCommit() async throws {
        try await withGlobalTestLock {
            let recorder = AppleSignInStepRecorder()
            let firstSyncStarted = AppleSignInGate()
            let finishFirstSync = AppleSignInGate()
            let secondExchangeStarted = AppleSignInGate()
            let finishSecondExchange = AppleSignInGate()
            let originalDisplayHubHandler = Rownd.displayHubHandler
            let (store, originalAppConfig) = await MainActor.run {
                let store = Context.currentContext.store
                return (store, store.state.appConfig)
            }
            defer { Rownd.displayHubHandler = originalDisplayHubHandler }

            Rownd.displayHubHandler = { _, _ in }
            await MainActor.run {
                store.dispatch(SetAppConfig(payload: Self.appConfig(
                    iosClientType: "native-apple-client"
                )))
            }

            let coordinator = TestAppleSignUpCoordinator(Rownd.getInstance())
            coordinator.signInWithApple = { authorizationCode, _ in
                recorder.append("exchange-\(authorizationCode)")
                if authorizationCode == "second" {
                    await secondExchangeStarted.open()
                    await finishSecondExchange.wait()
                }
                return SuperTokensAppleSignInResponse(
                    status: "OK",
                    createdNewRecipeUser: false,
                    sessionTokens: Self.appleSessionTokens
                )
            }
            coordinator.syncAuthState = { _, commitIf in
                recorder.append("sync-started")
                await firstSyncStarted.open()
                await finishFirstSync.wait()
                let shouldCommit = await MainActor.run { commitIf() }
                recorder.append(shouldCommit ? "auth-committed" : "auth-suppressed")
                return shouldCommit
            }
            coordinator.waitBeforeCompletion = {}
            coordinator.dismissHub = { _ in }
            coordinator.emitEvent = { _ in recorder.append("event") }
            coordinator.onUpdateUserData = { _ in recorder.append("profile") }

            let firstRequestID = UUID()
            await MainActor.run {
                Rownd.requestSignInForNativeCompletion(
                    jsFnOptions: RowndSignInJsOptions(loginStep: .completing),
                    requestID: firstRequestID
                )
            }
            let firstTask = Task {
                await coordinator.completeSignIn(
                    authorizationCode: "first",
                    fullName: nil,
                    email: nil,
                    intent: nil,
                    hubRequestID: firstRequestID
                )
            }
            await firstSyncStarted.wait()

            let secondTask = Task {
                await coordinator.completeSignIn(
                    authorizationCode: "second",
                    fullName: nil,
                    email: nil,
                    intent: nil,
                    hubRequestID: firstRequestID
                )
            }
            await secondExchangeStarted.wait()
            await finishFirstSync.open()
            await firstTask.value

            secondTask.cancel()
            await finishSecondExchange.open()
            await secondTask.value

            #expect(recorder.steps == [
                "exchange-first",
                "sync-started",
                "exchange-second",
                "auth-suppressed"
            ])
            await MainActor.run {
                store.dispatch(SetAppConfig(payload: originalAppConfig))
            }
        }
    }

    @Test func newerHubAfterSyncSuppressesAtomicProfileAndEventFinalization() async throws {
        try await withGlobalTestLock {
            let recorder = AppleSignInStepRecorder()
            let finalizationStarted = AppleSignInGate()
            let finishFinalization = AppleSignInGate()
            let originalDisplayHubHandler = Rownd.displayHubHandler
            let (store, originalAppConfig) = await MainActor.run {
                let store = Context.currentContext.store
                return (store, store.state.appConfig)
            }
            defer { Rownd.displayHubHandler = originalDisplayHubHandler }

            Rownd.displayHubHandler = { _, _ in }
            await MainActor.run {
                store.dispatch(SetAppConfig(payload: Self.appConfig(
                    iosClientType: "native-apple-client"
                )))
            }

            let coordinator = TestAppleSignUpCoordinator(Rownd.getInstance())
            coordinator.signInWithApple = { _, _ in
                SuperTokensAppleSignInResponse(
                    status: "OK",
                    createdNewRecipeUser: false,
                    sessionTokens: Self.appleSessionTokens
                )
            }
            coordinator.syncAuthState = { _, commitIf in
                let shouldCommit = await MainActor.run { commitIf() }
                if shouldCommit {
                    recorder.append("sync")
                }
                return shouldCommit
            }
            coordinator.waitBeforeCompletion = {}
            coordinator.dismissHub = { _ in }
            coordinator.beforeFinalization = {
                await finalizationStarted.open()
                await finishFinalization.wait()
            }
            coordinator.emitEvent = { _ in recorder.append("event") }
            coordinator.onUpdateUserData = { _ in recorder.append("profile") }

            let appleRequestID = UUID()
            let newerRequestID = UUID()
            await MainActor.run {
                Rownd.requestSignInForNativeCompletion(
                    jsFnOptions: RowndSignInJsOptions(loginStep: .completing),
                    requestID: appleRequestID
                )
            }
            let signInTask = Task {
                await coordinator.completeSignIn(
                    authorizationCode: "apple-auth-code",
                    fullName: nil,
                    email: nil,
                    intent: nil,
                    hubRequestID: appleRequestID
                )
            }

            await finalizationStarted.wait()
            await MainActor.run {
                Rownd.requestSignInForNativeCompletion(
                    jsFnOptions: RowndSignInJsOptions(loginStep: .completing),
                    requestID: newerRequestID
                )
            }
            await finishFinalization.open()
            await signInTask.value

            #expect(recorder.steps == ["sync"])
            #expect(await Rownd.isNativeHubRequestActive(newerRequestID))
            await MainActor.run {
                store.dispatch(SetAppConfig(payload: originalAppConfig))
            }
        }
    }

    @Test func reentrantOperationDuringFinalizationSuppressesProfileAndEvent() async throws {
        try await withGlobalTestLock {
            let recorder = AppleSignInStepRecorder()
            let originalDisplayHubHandler = Rownd.displayHubHandler
            let (store, originalAppConfig) = await MainActor.run {
                let store = Context.currentContext.store
                return (store, store.state.appConfig)
            }
            defer { Rownd.displayHubHandler = originalDisplayHubHandler }

            Rownd.displayHubHandler = { _, _ in }
            await MainActor.run {
                store.dispatch(SetAppConfig(payload: Self.appConfig(
                    iosClientType: "native-apple-client"
                )))
                store.dispatch(ResetSignInState())
            }

            let coordinator = TestAppleSignUpCoordinator(Rownd.getInstance())
            coordinator.signInWithApple = { _, _ in
                SuperTokensAppleSignInResponse(
                    status: "OK",
                    createdNewRecipeUser: false,
                    sessionTokens: Self.appleSessionTokens
                )
            }
            coordinator.syncAuthState = { _, commitIf in
                let shouldCommit = await MainActor.run { commitIf() }
                if shouldCommit {
                    recorder.append("sync")
                }
                return shouldCommit
            }
            coordinator.waitBeforeCompletion = {}
            coordinator.dismissHub = { _ in }
            coordinator.emitEvent = { _ in recorder.append("event") }
            coordinator.onUpdateUserData = { _ in recorder.append("profile") }

            let appleRequestID = UUID()
            let newerRequestID = UUID()
            let observer = await MainActor.run {
                let observer = ReentrantAppleSignInObserver {
                    recorder.append("reentrant-operation")
                    _ = coordinator.registerAuthorizationOperation(
                        controllerID: ObjectIdentifier(NSObject())
                    )
                    Rownd.requestSignInForNativeCompletion(
                        jsFnOptions: RowndSignInJsOptions(loginStep: .completing),
                        requestID: newerRequestID
                    )
                }
                store.subscribe(observer) {
                    $0.select { $0.signIn }
                }
                Rownd.requestSignInForNativeCompletion(
                    jsFnOptions: RowndSignInJsOptions(loginStep: .completing),
                    requestID: appleRequestID
                )
                return observer
            }

            await coordinator.completeSignIn(
                authorizationCode: "apple-auth-code",
                fullName: nil,
                email: nil,
                intent: nil,
                hubRequestID: appleRequestID
            )

            #expect(recorder.steps == ["sync", "reentrant-operation"])
            #expect(await Rownd.isNativeHubRequestActive(newerRequestID))
            await MainActor.run {
                store.unsubscribe(observer)
                store.dispatch(SetAppConfig(payload: originalAppConfig))
                store.dispatch(ResetSignInState())
            }
        }
    }

    @Test func onlyDirectAuthorizationOperationsEmitSignInStarted() async throws {
        try await withGlobalTestLock {
            let events = AppleEventRecorder()
            let coordinator = TestAppleSignUpCoordinator(Rownd.getInstance())
            coordinator.emitEvent = { events.append($0) }
            let controller = NSObject()

            await coordinator.registerAuthorizationOperation(
                controllerID: ObjectIdentifier(controller),
                emitsSignInStarted: false
            )
            #expect(events.events.isEmpty)

            await coordinator.registerAuthorizationOperation(
                controllerID: ObjectIdentifier(controller),
                emitsSignInStarted: true
            )
            #expect(events.events.map(\.event) == [.signInStarted])
            #expect(events.events.first?.data?["method"]??.value as? String == SignInType.apple.rawValue)
        }
    }

    @Test(arguments: [false, true])
    func requestSignInEmitsStartOnlyWhenNotInitiatedByHub(_ initiatedByHub: Bool) async throws {
        try await withGlobalTestLock {
            let originalCoordinator = Rownd.appleSignUpCoordinator
            defer { Rownd.appleSignUpCoordinator = originalCoordinator }
            let coordinator = EntryPointRecordingAppleCoordinator(Rownd.getInstance())
            Rownd.appleSignUpCoordinator = coordinator

            Rownd.requestSignIn(
                with: .appleId,
                signInOptions: RowndSignInOptions(),
                initiatedByHub: initiatedByHub
            )

            #expect(coordinator.emitsSignInStarted == [!initiatedByHub])
        }
    }

    @Test func authorizationOperationsFollowInitiationOrderNotCallbackOrder() async throws {
        try await withGlobalTestLock {
            let coordinator = TestAppleSignUpCoordinator(Rownd.getInstance())
            let firstController = NSObject()
            let secondController = NSObject()

            let firstOperationID = await coordinator.registerAuthorizationOperation(
                controllerID: ObjectIdentifier(firstController)
            )
            let secondOperationID = await coordinator.registerAuthorizationOperation(
                controllerID: ObjectIdentifier(secondController)
            )

            #expect(firstOperationID != secondOperationID)
            let staleOperationID = await coordinator.consumeAuthorizationOperation(
                controllerID: ObjectIdentifier(firstController)
            )
            let consumedOperationID = await coordinator.consumeAuthorizationOperation(
                controllerID: ObjectIdentifier(secondController)
            )
            let duplicateOperationID = await coordinator.consumeAuthorizationOperation(
                controllerID: ObjectIdentifier(secondController)
            )
            #expect(staleOperationID == nil)
            #expect(consumedOperationID == secondOperationID)
            #expect(duplicateOperationID == nil)
        }
    }

    @Test func invalidationBeforeHubPresentationRetiresOnlyStaleRequest() async throws {
        try await withGlobalTestLock {
            let recorder = AppleSignInStepRecorder()
            let presentationPaused = AppleSignInGate()
            let resumePresentation = AppleSignInGate()
            let staleRequestRetired = AppleSignInGate()
            let originalDisplayHubHandler = Rownd.displayHubHandler
            defer { Rownd.displayHubHandler = originalDisplayHubHandler }
            Rownd.displayHubHandler = { _, _ in recorder.append("present") }

            let coordinator = TestAppleSignUpCoordinator(Rownd.getInstance())
            coordinator.beforeHubPresentation = {
                await presentationPaused.open()
                await resumePresentation.wait()
            }
            let staleHubRequestID = UUID()
            coordinator.dismissHub = { requestID in
                #expect(requestID == staleHubRequestID)
                recorder.append("retire")
                await staleRequestRetired.open()
            }

            let firstController = NSObject()
            let firstOperationID = await coordinator.registerAuthorizationOperation(
                controllerID: ObjectIdentifier(firstController)
            )
            let presentationTask = Task {
                await coordinator.presentHubForNativeCompletion(
                    operationID: firstOperationID,
                    hubRequestID: staleHubRequestID
                )
            }
            await presentationPaused.wait()

            let secondController = NSObject()
            _ = await coordinator.registerAuthorizationOperation(
                controllerID: ObjectIdentifier(secondController)
            )
            await staleRequestRetired.wait()
            await resumePresentation.open()

            #expect(await presentationTask.value == false)
            #expect(recorder.steps == ["retire"])
        }
    }

    @Test func missingAppleClientTypeDoesNotExchangeAuthorizationCode() async throws {
        try await withGlobalTestLock {
            let originalConfig = Rownd.config
            let originalDisplayHubHandler = Rownd.displayHubHandler
            let (store, originalAppConfig) = await MainActor.run {
                let store = Context.currentContext.store
                return (store, store.state.appConfig)
            }

            Rownd.config = RowndConfig()
            Rownd.displayHubHandler = { _, _ in }
            await MainActor.run {
                store.dispatch(SetAppConfig(payload: Self.appConfig(
                    iosClientType: "  "
                )))
            }

            let recorder = AppleSignInStepRecorder()
            let coordinator = TestAppleSignUpCoordinator(Rownd.getInstance())
            coordinator.signInWithApple = { _, _ in
                recorder.append("exchange")
                return SuperTokensAppleSignInResponse(
                    status: "OK",
                    createdNewRecipeUser: true,
                    sessionTokens: Self.appleSessionTokens
                )
            }
            coordinator.syncAuthState = { _, _ in true }
            coordinator.waitBeforeCompletion = {}
            coordinator.dismissHub = { _ in }
            coordinator.emitEvent = { _ in }

            let hubRequestID = UUID()
            await MainActor.run {
                Rownd.requestSignInForNativeCompletion(
                    jsFnOptions: RowndSignInJsOptions(loginStep: .completing),
                    requestID: hubRequestID
                )
            }
            await coordinator.completeSignIn(
                authorizationCode: "apple-auth-code",
                fullName: nil,
                email: nil,
                intent: nil,
                hubRequestID: hubRequestID
            )

            #expect(recorder.steps.isEmpty)
            Rownd.config = originalConfig
            Rownd.displayHubHandler = originalDisplayHubHandler
            await MainActor.run {
                store.dispatch(SetAppConfig(payload: originalAppConfig))
            }
        }
    }

    @Test func refreshedAppleClientTypeIsUsedForExchange() async throws {
        try await withGlobalTestLock {
            let originalConfig = Rownd.config
            let originalProtocolClasses = AppConfig.testingProtocolClasses
            let originalDisplayHubHandler = Rownd.displayHubHandler
            let (store, originalAppConfig) = await MainActor.run {
                let store = Context.currentContext.store
                return (store, store.state.appConfig)
            }

            Rownd.config = RowndConfig()
            Rownd.displayHubHandler = { _, _ in }
            Rownd.config.supertokens = RowndSuperTokensConfig(
                appName: "Example App",
                apiDomain: "https://auth.example.com",
                apiBasePath: "/auth"
            )
            AppleAppConfigURLProtocol.responseData = Self.refreshedAppConfigData
            AppConfig.testingProtocolClasses = [AppleAppConfigURLProtocol.self]
            await MainActor.run {
                store.dispatch(SetAppConfig(payload: Self.appConfig(iosClientType: nil)))
            }

            let recorder = AppleSignInStepRecorder()
            let coordinator = TestAppleSignUpCoordinator(Rownd.getInstance())
            coordinator.signInWithApple = { authorizationCode, clientType in
                #expect(authorizationCode == "apple-auth-code")
                #expect(clientType == "refreshed-native-client")
                recorder.append("exchange")
                return SuperTokensAppleSignInResponse(
                    status: "OK",
                    createdNewRecipeUser: false,
                    sessionTokens: Self.appleSessionTokens
                )
            }
            coordinator.syncAuthState = { _, _ in true }
            coordinator.waitBeforeCompletion = {}
            coordinator.dismissHub = { _ in }
            coordinator.emitEvent = { _ in }

            let hubRequestID = UUID()
            await MainActor.run {
                Rownd.requestSignInForNativeCompletion(
                    jsFnOptions: RowndSignInJsOptions(loginStep: .completing),
                    requestID: hubRequestID
                )
            }
            await coordinator.completeSignIn(
                authorizationCode: "apple-auth-code",
                fullName: nil,
                email: nil,
                intent: nil,
                hubRequestID: hubRequestID
            )

            #expect(recorder.steps == ["exchange"])
            let installedClientType = await MainActor.run {
                store.state.appConfig.config?.hub?.auth?.signInMethods?.apple?.iosClientType
            }
            #expect(installedClientType == "refreshed-native-client")
            Rownd.config = originalConfig
            Rownd.displayHubHandler = originalDisplayHubHandler
            AppConfig.testingProtocolClasses = originalProtocolClasses
            AppleAppConfigURLProtocol.responseData = Data()
            await MainActor.run {
                store.dispatch(SetAppConfig(payload: originalAppConfig))
            }
        }
    }

    @Test func staleConfigResolutionFailureDoesNotReplaceNewerHubRequest() async throws {
        try await withGlobalTestLock {
            let recorder = AppleSignInStepRecorder()
            let fetchStarted = AppleSignInGate()
            let finishFetch = AppleSignInGate()
            let originalDisplayHubHandler = Rownd.displayHubHandler
            let (store, originalAppConfig) = await MainActor.run {
                let store = Context.currentContext.store
                return (store, store.state.appConfig)
            }
            Rownd.displayHubHandler = { _, options in
                guard let options = options as? RowndSignInJsOptions,
                      let loginStep = options.loginStep else {
                    return
                }
                recorder.append(loginStep.rawValue)
            }
            await MainActor.run {
                store.dispatch(SetAppConfig(payload: Self.appConfig(iosClientType: nil)))
            }

            let coordinator = TestAppleSignUpCoordinator(Rownd.getInstance())
            coordinator.fetchAppConfig = {
                await fetchStarted.open()
                await finishFetch.wait()
                return nil
            }
            let appleRequestID = UUID()
            let newerRequestID = UUID()
            await MainActor.run {
                Rownd.requestSignInForNativeCompletion(
                    jsFnOptions: RowndSignInJsOptions(loginStep: .completing),
                    requestID: appleRequestID
                )
            }
            let signInTask = Task {
                await coordinator.completeSignIn(
                    authorizationCode: "apple-auth-code",
                    fullName: nil,
                    email: nil,
                    intent: nil,
                    hubRequestID: appleRequestID
                )
            }

            await fetchStarted.wait()
            await MainActor.run {
                Rownd.requestSignInForNativeCompletion(
                    jsFnOptions: RowndSignInJsOptions(loginStep: .completing),
                    requestID: newerRequestID
                )
            }
            await finishFetch.open()
            await signInTask.value

            #expect(recorder.steps == [
                RowndSignInLoginStep.completing.rawValue,
                RowndSignInLoginStep.completing.rawValue
            ])
            Rownd.displayHubHandler = originalDisplayHubHandler
            await MainActor.run {
                store.dispatch(SetAppConfig(payload: originalAppConfig))
            }
        }
    }

    @Test func newerClientTypeWinsWhileFallbackFetchIsInFlight() async throws {
        try await withGlobalTestLock {
            let fetchStarted = AppleSignInGate()
            let finishFetch = AppleSignInGate()
            let originalDisplayHubHandler = Rownd.displayHubHandler
            let (store, originalAppConfig) = await MainActor.run {
                let store = Context.currentContext.store
                return (store, store.state.appConfig)
            }
            Rownd.displayHubHandler = { _, _ in }
            await MainActor.run {
                store.dispatch(SetAppConfig(payload: Self.appConfig(iosClientType: nil)))
            }

            let recorder = AppleSignInStepRecorder()
            let coordinator = TestAppleSignUpCoordinator(Rownd.getInstance())
            coordinator.fetchAppConfig = {
                await fetchStarted.open()
                await finishFetch.wait()
                return AppConfigResponse(app: Self.appConfig(iosClientType: "stale-client"))
            }
            coordinator.signInWithApple = { _, clientType in
                recorder.append(clientType)
                return SuperTokensAppleSignInResponse(
                    status: "OK",
                    createdNewRecipeUser: false,
                    sessionTokens: Self.appleSessionTokens
                )
            }
            coordinator.syncAuthState = { _, _ in true }
            coordinator.waitBeforeCompletion = {}
            coordinator.dismissHub = { _ in }
            coordinator.emitEvent = { _ in }

            let hubRequestID = UUID()
            await MainActor.run {
                Rownd.requestSignInForNativeCompletion(
                    jsFnOptions: RowndSignInJsOptions(loginStep: .completing),
                    requestID: hubRequestID
                )
            }
            let signInTask = Task {
                await coordinator.completeSignIn(
                    authorizationCode: "apple-auth-code",
                    fullName: nil,
                    email: nil,
                    intent: nil,
                    hubRequestID: hubRequestID
                )
            }
            await fetchStarted.wait()
            await MainActor.run {
                store.dispatch(SetAppConfig(payload: Self.appConfig(iosClientType: "newer-client")))
            }
            await finishFetch.open()
            await signInTask.value

            let installedClientType = await MainActor.run {
                store.state.appConfig.config?.hub?.auth?.signInMethods?.apple?.iosClientType
            }
            #expect(recorder.steps == ["newer-client"])
            #expect(installedClientType == "newer-client")
            Rownd.displayHubHandler = originalDisplayHubHandler
            await MainActor.run {
                store.dispatch(SetAppConfig(payload: originalAppConfig))
            }
        }
    }

    @Test func concurrentClientTypeRemovalWinsOverStaleFallbackFetch() async throws {
        try await withGlobalTestLock {
            let fetchStarted = AppleSignInGate()
            let finishFetch = AppleSignInGate()
            let originalDisplayHubHandler = Rownd.displayHubHandler
            let (store, originalAppConfig) = await MainActor.run {
                let store = Context.currentContext.store
                return (store, store.state.appConfig)
            }
            Rownd.displayHubHandler = { _, _ in }
            await MainActor.run {
                store.dispatch(SetAppConfig(payload: Self.appConfig(iosClientType: nil)))
            }

            let recorder = AppleSignInStepRecorder()
            let coordinator = TestAppleSignUpCoordinator(Rownd.getInstance())
            coordinator.fetchAppConfig = {
                await fetchStarted.open()
                await finishFetch.wait()
                return AppConfigResponse(app: Self.appConfig(iosClientType: "stale-client"))
            }
            coordinator.signInWithApple = { _, _ in
                recorder.append("exchange")
                return SuperTokensAppleSignInResponse(
                    status: "OK",
                    createdNewRecipeUser: false,
                    sessionTokens: Self.appleSessionTokens
                )
            }

            let hubRequestID = UUID()
            await MainActor.run {
                Rownd.requestSignInForNativeCompletion(
                    jsFnOptions: RowndSignInJsOptions(loginStep: .completing),
                    requestID: hubRequestID
                )
            }
            let signInTask = Task {
                await coordinator.completeSignIn(
                    authorizationCode: "apple-auth-code",
                    fullName: nil,
                    email: nil,
                    intent: nil,
                    hubRequestID: hubRequestID
                )
            }
            await fetchStarted.wait()
            let removedAppConfig = AppConfigState(id: "newer-config-without-apple")
            await MainActor.run {
                store.dispatch(SetAppConfig(payload: removedAppConfig))
            }
            await finishFetch.open()
            await signInTask.value

            let installedAppConfig = await MainActor.run {
                store.state.appConfig
            }
            #expect(recorder.steps.isEmpty)
            #expect(installedAppConfig == removedAppConfig)
            Rownd.displayHubHandler = originalDisplayHubHandler
            await MainActor.run {
                store.dispatch(SetAppConfig(payload: originalAppConfig))
            }
        }
    }

    @Test func loadingChangeDoesNotDiscardFallbackClientType() async throws {
        try await withGlobalTestLock {
            let fetchStarted = AppleSignInGate()
            let finishFetch = AppleSignInGate()
            let originalDisplayHubHandler = Rownd.displayHubHandler
            let (store, originalAppConfig) = await MainActor.run {
                let store = Context.currentContext.store
                return (store, store.state.appConfig)
            }
            Rownd.displayHubHandler = { _, _ in }
            await MainActor.run {
                store.dispatch(SetAppConfig(payload: Self.appConfig(iosClientType: nil)))
            }

            let recorder = AppleSignInStepRecorder()
            let coordinator = TestAppleSignUpCoordinator(Rownd.getInstance())
            coordinator.fetchAppConfig = {
                await fetchStarted.open()
                await finishFetch.wait()
                return AppConfigResponse(app: Self.appConfig(iosClientType: "fetched-client"))
            }
            coordinator.signInWithApple = { _, clientType in
                recorder.append(clientType)
                return SuperTokensAppleSignInResponse(
                    status: "OK",
                    createdNewRecipeUser: false,
                    sessionTokens: Self.appleSessionTokens
                )
            }
            coordinator.syncAuthState = { _, _ in true }
            coordinator.waitBeforeCompletion = {}
            coordinator.dismissHub = { _ in }
            coordinator.emitEvent = { _ in }

            let hubRequestID = UUID()
            await MainActor.run {
                Rownd.requestSignInForNativeCompletion(
                    jsFnOptions: RowndSignInJsOptions(loginStep: .completing),
                    requestID: hubRequestID
                )
            }
            let signInTask = Task {
                await coordinator.completeSignIn(
                    authorizationCode: "apple-auth-code",
                    fullName: nil,
                    email: nil,
                    intent: nil,
                    hubRequestID: hubRequestID
                )
            }
            await fetchStarted.wait()
            await MainActor.run {
                store.dispatch(SetAppLoading(isLoading: true))
            }
            await finishFetch.open()
            await signInTask.value

            let installedAppConfig = await MainActor.run {
                store.state.appConfig
            }
            #expect(recorder.steps == ["fetched-client"])
            #expect(
                installedAppConfig.config?.hub?.auth?.signInMethods?.apple?.iosClientType
                    == "fetched-client"
            )
            #expect(!installedAppConfig.isLoading)
            Rownd.displayHubHandler = originalDisplayHubHandler
            await MainActor.run {
                store.dispatch(SetAppConfig(payload: originalAppConfig))
            }
        }
    }

    @Test @MainActor func hubHideCompletesOnlyAfterOuterHostDisappears() async {
        let hostController = TestBottomSheetViewController()
        let hubViewController = HubViewController()
        hostController.controller = hubViewController
        hubViewController.hostController = hostController
        hostController.isOuterHostDetachedOverride = false
        var didComplete = false

        hubViewController.hide {
            didComplete = true
        }

        #expect(hostController.didRequestBottomSheetDismissal)
        #expect(!hostController.didRequestOuterDismissal)
        #expect(!didComplete)

        hostController.completeBottomSheetDismissal()
        await nextMainRunLoop()

        #expect(hostController.didRequestOuterDismissal)
        #expect(!didComplete)

        hostController.completeOuterDismissal()

        #expect(!didComplete)

        hostController.isOuterHostDetachedOverride = true
        hostController.viewDidDisappear(false)
        await nextMainRunLoop()

        #expect(didComplete)
    }

    @Test @MainActor func programmaticDismissalCompletionFinalizesDetachedOuterHostOnce() async {
        let hostController = TestBottomSheetViewController()
        let hubViewController = HubViewController()
        hostController.controller = hubViewController
        hubViewController.hostController = hostController
        hostController.isOuterHostDetachedOverride = false
        var completionCount = 0

        hubViewController.hide {
            completionCount += 1
        }
        hostController.completeBottomSheetDismissal()
        await nextMainRunLoop()

        #expect(hostController.didRequestOuterDismissal)
        #expect(completionCount == 0)

        hostController.isOuterHostDetachedOverride = true
        hostController.completeOuterDismissal()

        #expect(completionCount == 1)

        hostController.viewDidDisappear(false)
        hostController.completeOuterDismissal()
        await nextMainRunLoop()

        #expect(completionCount == 1)
    }

    @Test @MainActor func hostDisappearanceCompletesOverlappingHideRequestsOnce() async {
        let hostController = TestBottomSheetViewController()
        let hubViewController = HubViewController()
        hostController.controller = hubViewController
        hubViewController.hostController = hostController
        var completionCount = 0

        hubViewController.hide {
            completionCount += 1
        }
        hubViewController.hide {
            completionCount += 1
        }

        #expect(hostController.bottomSheetDismissalRequestCount == 1)
        hostController.completeBottomSheetDismissal()
        await nextMainRunLoop()
        #expect(hostController.outerDismissalRequestCount == 1)
        #expect(completionCount == 0)

        hostController.viewDidDisappear(false)
        await nextMainRunLoop()

        #expect(completionCount == 2)
        hostController.completeOuterDismissal()
        #expect(completionCount == 2)
    }

    @Test @MainActor func hostCoveredByInnerSheetDoesNotCompleteHide() async {
        let hostController = TestBottomSheetViewController()
        let hubViewController = HubViewController()
        hostController.controller = hubViewController
        hubViewController.hostController = hostController
        hostController.shouldFinalizeDisappearanceOverride = false
        var didComplete = false

        hubViewController.hide {
            didComplete = true
        }
        hostController.viewDidDisappear(false)
        await nextMainRunLoop()

        #expect(hostController.controller === hubViewController)
        #expect(!didComplete)
    }

    @Test @MainActor func staleHubHideCompletesWithoutReusingFinalizedHost() {
        let hostController = TestBottomSheetViewController()
        let hubViewController = HubViewController()
        let requestID = UUID()
        var disappearanceCount = 0
        var hideCompletionCount = 0
        hubViewController.presentationRequestID = requestID
        hubViewController.onDisappeared = { disappearedRequestID in
            #expect(disappearedRequestID == requestID)
            disappearanceCount += 1
        }
        hostController.controller = hubViewController
        hubViewController.hostController = hostController

        hostController.viewDidDisappear(false)

        #expect(hostController.controller == nil)
        #expect(hubViewController.hostController == nil)
        #expect(disappearanceCount == 1)

        hubViewController.hide {
            hideCompletionCount += 1
        }

        #expect(hideCompletionCount == 1)
        #expect(disappearanceCount == 1)
        #expect(hostController.outerDismissalRequestCount == 0)
        #expect(hostController.bottomSheetDismissalRequestCount == 0)
    }

    @Test @MainActor func staleHubCannotDismissNewHostOwner() {
        let hostController = TestBottomSheetViewController()
        let oldHubViewController = HubViewController()
        hostController.controller = oldHubViewController
        oldHubViewController.hostController = hostController
        hostController.viewDidDisappear(false)

        let newHubViewController = HubViewController()
        hostController.controller = newHubViewController
        newHubViewController.hostController = hostController
        oldHubViewController.hostController = hostController
        var hideCompletionCount = 0

        oldHubViewController.hide {
            hideCompletionCount += 1
        }

        #expect(hideCompletionCount == 1)
        #expect(oldHubViewController.hostController == nil)
        #expect(hostController.controller === newHubViewController)
        #expect(hostController.outerDismissalRequestCount == 0)
        #expect(hostController.bottomSheetDismissalRequestCount == 0)
    }

    @Test @MainActor func interactiveDismissalDefersOuterHostAndCompletesOnceDetached() async {
        let hostController = TestBottomSheetViewController()
        let hubViewController = HubViewController()
        hostController.controller = hubViewController
        hubViewController.hostController = hostController
        hostController.isOuterHostDetachedOverride = false
        var hideCompletionCount = 0

        hubViewController.handleHostContentWillDisappear()

        #expect(hostController.outerDismissalRequestCount == 0)

        await nextMainRunLoop()

        #expect(hostController.outerDismissalRequestCount == 1)

        hubViewController.hide {
            hideCompletionCount += 1
        }

        #expect(hostController.outerDismissalRequestCount == 1)
        #expect(hostController.bottomSheetDismissalRequestCount == 0)
        #expect(hideCompletionCount == 0)

        hostController.isOuterHostDetachedOverride = true
        hostController.completeOuterDismissal()

        #expect(hideCompletionCount == 1)
        #expect(hostController.controller == nil)
        #expect(hubViewController.hostController == nil)

        hostController.viewDidDisappear(false)
        hostController.completeOuterDismissal()
        await nextMainRunLoop()

        #expect(hideCompletionCount == 1)
        #expect(hostController.outerDismissalRequestCount == 1)
    }

    @MainActor private func nextMainRunLoop() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    @Test func staleAppleSuccessDoesNotReplaceANewerHubRequest() async throws {
        try await withGlobalTestLock {
            let recorder = AppleSignInStepRecorder()
            let originalDisplayHubHandler = Rownd.displayHubHandler
            defer { Rownd.displayHubHandler = originalDisplayHubHandler }
            Rownd.displayHubHandler = { _, options in
                guard let options = options as? RowndSignInJsOptions,
                      let loginStep = options.loginStep else {
                    return
                }
                recorder.append(loginStep.rawValue)
            }

            let appleRequestID = UUID()
            let newerRequestID = UUID()
            await MainActor.run {
                Rownd.requestSignInForNativeCompletion(
                    jsFnOptions: RowndSignInJsOptions(loginStep: .completing),
                    requestID: appleRequestID
                )
                Rownd.requestSignInForNativeCompletion(
                    jsFnOptions: RowndSignInJsOptions(loginStep: .completing),
                    requestID: newerRequestID
                )
                Rownd.updateSignInForNativeCompletion(
                    jsFnOptions: RowndSignInJsOptions(loginStep: .success),
                    requestID: appleRequestID
                )
            }

            #expect(recorder.steps == [
                RowndSignInLoginStep.completing.rawValue,
                RowndSignInLoginStep.completing.rawValue
            ])
        }
    }

    @Test func userDismissalBlocksStaleHubWorkButFinalizesAppleSignIn() async throws {
        try await withGlobalTestLock {
            let recorder = AppleSignInStepRecorder()
            let completionDelayStarted = AppleSignInGate()
            let finishCompletionDelay = AppleSignInGate()
            let originalDisplayHubHandler = Rownd.displayHubHandler
            let (store, originalAppConfig) = await MainActor.run {
                let store = Context.currentContext.store
                return (store, store.state.appConfig)
            }
            defer { Rownd.displayHubHandler = originalDisplayHubHandler }
            Rownd.displayHubHandler = nil
            await MainActor.run {
                store.dispatch(SetAppConfig(payload: Self.appConfig(
                    iosClientType: "native-apple-client"
                )))
            }

            let coordinator = TestAppleSignUpCoordinator(Rownd.getInstance())
            coordinator.signInWithApple = { _, _ in
                SuperTokensAppleSignInResponse(
                    status: "OK",
                    createdNewRecipeUser: false,
                    sessionTokens: Self.appleSessionTokens
                )
            }
            coordinator.syncAuthState = { _, commitIf in
                recorder.append("sync")
                return await MainActor.run { commitIf() }
            }
            coordinator.waitBeforeCompletion = {
                await completionDelayStarted.open()
                await finishCompletionDelay.wait()
            }
            coordinator.dismissHub = { _ in recorder.append("dismiss") }
            coordinator.onAdopt = { recorder.append("adopt") }
            coordinator.emitEvent = { _ in recorder.append("event") }
            coordinator.onUpdateUserData = { _ in recorder.append("profile") }

            let hubRequestID = UUID()
            await MainActor.run {
                Rownd.requestSignInForNativeCompletion(
                    jsFnOptions: RowndSignInJsOptions(loginStep: .completing),
                    requestID: hubRequestID
                )
            }
            let signInTask = Task {
                await coordinator.completeSignIn(
                    authorizationCode: "apple-auth-code",
                    fullName: nil,
                    email: nil,
                    intent: nil,
                    hubRequestID: hubRequestID
                )
            }

            let didStartCompletionDelay = await completionDelayStarted.waitUntilOpen()
            await MainActor.run {
                Rownd.getInstance().bottomSheetController.viewDidDisappear(false)
            }
            await finishCompletionDelay.open()
            await signInTask.value

            let lifecycleState = await MainActor.run {
                (
                    Rownd.isNativeHubRequestActive(hubRequestID),
                    Rownd.getInstance().bottomSheetController.controller
                )
            }
            #expect(!lifecycleState.0)
            #expect(lifecycleState.1 == nil)
            #expect(didStartCompletionDelay)
            #expect(recorder.steps == ["adopt", "sync", "profile", "event"])
            await MainActor.run {
                store.dispatch(SetAppConfig(payload: originalAppConfig))
            }
        }
    }

    @Test func newerHubRequestPresentsAfterOlderDismissalCompletes() async throws {
        try await withGlobalTestLock {
            let originalDisplayHubHandler = Rownd.displayHubHandler
            defer { Rownd.displayHubHandler = originalDisplayHubHandler }
            Rownd.displayHubHandler = nil

            let oldRequestID = UUID()
            let newRequestID = UUID()
            let (oldController, hostController) = await MainActor.run {
                Rownd.requestSignInForNativeCompletion(
                    jsFnOptions: RowndSignInJsOptions(loginStep: .completing),
                    requestID: oldRequestID
                )
                let hostController = Rownd.getInstance().bottomSheetController
                let oldController = hostController.controller as! HubViewController
                hostController.bottomSheetInteractionWillDismiss()
                Rownd.requestSignInForNativeCompletion(
                    jsFnOptions: RowndSignInJsOptions(loginStep: .error),
                    requestID: newRequestID
                )
                return (oldController, hostController)
            }

            let controllerWhileDismissing = await MainActor.run {
                hostController.controller as? HubViewController
            }
            #expect(controllerWhileDismissing === oldController)
            #expect(await MainActor.run { hostController.controller === oldController })

            await MainActor.run {
                hostController.viewDidDisappear(false)
            }
            await nextMainRunLoop()
            await nextMainRunLoop()
            let newController = await MainActor.run {
                hostController.controller as? HubViewController
            }
            #expect(newController != nil)
            #expect(newController !== oldController)
            let didPresentError = await MainActor.run {
                newController?.hubWebController.jsFunctionArgsAsJson.contains("error") == true
            }
            #expect(didPresentError)
            #expect(await Rownd.isNativeHubRequestActive(newRequestID))

            await MainActor.run {
                hostController.viewDidDisappear(false)
            }
        }
    }

    private static func appConfig(iosClientType: String?) -> AppConfigState {
        AppConfigState(config: AppConfigConfig(
            hub: AppHubConfigState(
                auth: AppHubAuthConfigState(
                    signInMethods: SignInMethods(
                        apple: AppleSignInMethodConfig(iosClientType: iosClientType)
                    )
                )
            )
        ))
    }

    private static func profileHydrationIdentity(
        sessionHandle: String
    ) -> SuperTokensSessionBridge.SessionIdentity {
        let accessToken = generateJwt(
            expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
            sessionHandle: sessionHandle,
            userId: "apple-user"
        )
        guard let stable = SuperTokensSessionBridge.stableSessionIdentity(from: accessToken) else {
            fatalError("Failed to create Apple profile hydration identity")
        }
        return SuperTokensSessionBridge.SessionIdentity(
            accessToken: accessToken,
            generation: 42,
            stable: stable
        )
    }

    private static let refreshedAppConfigData = """
    {
      "app": {
        "id": "app_test",
        "config": {
          "hub": {
            "auth": {
              "sign_in_methods": {
                "apple": {
                  "enabled": true,
                  "ios_client_type": "refreshed-native-client"
                }
              }
            }
          }
        }
      }
    }
    """.data(using: .utf8)!
}

private actor AppleSignInGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else {
            return
        }

        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitUntilOpen(timeoutNanoseconds: UInt64 = 2_000_000_000) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while !isOpen && DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return isOpen
    }

    func open() {
        isOpen = true
        let pendingContinuations = continuations
        continuations.removeAll()
        pendingContinuations.forEach { $0.resume() }
    }
}

private final class TestAppleSignUpCoordinator: AppleSignUpCoordinator {
    var onUpdateUserData: ((SuperTokensSessionBridge.SessionIdentity) -> Void)?
    var onAdopt: (() -> Void)?

    override init(
        _ parent: Rownd,
        signInClient: SuperTokensThirdPartySignInClient = SuperTokensThirdPartySignInClient()
    ) {
        super.init(parent, signInClient: signInClient)
        adoptResponseSession = { [weak self] tokens, _ in
            self?.onAdopt?()
            return SuperTokensSessionBridge.SessionIdentity(
                accessToken: tokens.accessToken,
                generation: 1,
                stable: SuperTokensSessionBridge.StableSessionIdentity(
                    sessionHandle: "apple-session",
                    userId: "apple-user",
                    tenantId: nil
                )
            )
        }
        isCurrentSession = { _ in true }
    }

    @MainActor override func updateUserDataWithAppleData(
        fullName: PersonNameComponents?,
        email: String?,
        sessionIdentity: SuperTokensSessionBridge.SessionIdentity
    ) {
        onUpdateUserData?(sessionIdentity)
    }
}

private final class ReentrantAppleSignInObserver: StoreSubscriber {
    private let onAppleSignIn: () -> Void
    private var hasTriggered = false

    init(onAppleSignIn: @escaping () -> Void) {
        self.onAppleSignIn = onAppleSignIn
    }

    func newState(state: SignInState) {
        guard state.lastSignIn == .apple, !hasTriggered else { return }
        hasTriggered = true
        onAppleSignIn()
    }
}

private final class TestBottomSheetViewController: BottomSheetViewController {
    private var bottomSheetDismissalCompletion: (() -> Void)?
    private var outerDismissalCompletion: (() -> Void)?
    private(set) var bottomSheetDismissalRequestCount = 0
    private(set) var outerDismissalRequestCount = 0
    var shouldFinalizeDisappearanceOverride: Bool?
    var isOuterHostDetachedOverride: Bool?

    override var shouldFinalizeDisappearance: Bool {
        shouldFinalizeDisappearanceOverride ?? super.shouldFinalizeDisappearance
    }

    override var isOuterHostDetached: Bool {
        isOuterHostDetachedOverride ?? super.isOuterHostDetached
    }

    var didRequestBottomSheetDismissal: Bool {
        bottomSheetDismissalRequestCount > 0
    }

    var didRequestOuterDismissal: Bool {
        outerDismissalRequestCount > 0
    }

    override func hideBottomSheet(_ completion: (() -> Void)? = nil) {
        bottomSheetDismissalRequestCount += 1
        bottomSheetDismissalCompletion = completion
    }

    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        outerDismissalRequestCount += 1
        outerDismissalCompletion = completion
    }

    func completeBottomSheetDismissal() {
        bottomSheetDismissalCompletion?()
    }

    func completeOuterDismissal() {
        outerDismissalCompletion?()
    }
}

private final class AppleSignInStepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedSteps: [String] = []

    var steps: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedSteps
    }

    func append(_ step: String) {
        lock.lock()
        recordedSteps.append(step)
        lock.unlock()
    }
}

private final class EntryPointRecordingAppleCoordinator: AppleSignUpCoordinator, @unchecked Sendable {
    private(set) var emitsSignInStarted: [Bool] = []

    override func signIn(_ intent: RowndSignInIntent?, emitsSignInStarted: Bool) {
        self.emitsSignInStarted.append(emitsSignInStarted)
    }
}

private final class AppleEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [RowndEvent] = []

    var events: [RowndEvent] {
        lock.withLock { recordedEvents }
    }

    func append(_ event: RowndEvent) {
        lock.withLock { recordedEvents.append(event) }
    }
}

private final class AppleSessionIdentityRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedIdentities: [SuperTokensSessionBridge.SessionIdentity] = []

    var identities: [SuperTokensSessionBridge.SessionIdentity] {
        lock.withLock { recordedIdentities }
    }

    func append(_ identity: SuperTokensSessionBridge.SessionIdentity) {
        lock.withLock { recordedIdentities.append(identity) }
    }
}

private final class AppleStableIdentityRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedIdentities: [SuperTokensSessionBridge.StableSessionIdentity] = []

    var identities: [SuperTokensSessionBridge.StableSessionIdentity] {
        lock.withLock { recordedIdentities }
    }

    func append(_ identity: SuperTokensSessionBridge.StableSessionIdentity) {
        lock.withLock { recordedIdentities.append(identity) }
    }
}

private final class AppleAppConfigURLProtocol: URLProtocol {
    static var responseData = Data()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path == "/auth/plugin/rownd/app-config"
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
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
