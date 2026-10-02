import Foundation
import Testing

@testable import Rownd

@Suite(.serialized) struct LegacySessionMigratorTests {
    @Test(arguments: [false, true], [nil, "", " \t\n\r"] as [String?])
    func accessOnlyMigrationUsesAccessToken(expired: Bool, blankRefresh: String?) async throws {
        try await withIsolatedStore {
            let calls = MigrationCalls()
            let accessToken = expired ? expiredLegacyToken() : validLegacyToken()
            let auth = AuthState(accessToken: accessToken, refreshToken: blankRefresh)
            await setAuthState(auth)
            await LegacySessionMigrator.migrateIfNeeded(authState: auth, dependencies: makeDependencies(calls: calls))
            #expect(calls.migrateAccessTokens == [accessToken])
        }
    }

    @Test func nativeAccessAndEmptyCredentialsAreNotMigrated() async throws {
        try await withIsolatedStore {
            for auth in [AuthState(), AuthState(accessToken: "", refreshToken: ""),
                         AuthState(accessToken: " \t\n", refreshToken: "\r\n "),
                         AuthState(refreshToken: validSuperTokensToken()),
                         AuthState(accessToken: validLegacyToken(), refreshToken: validSuperTokensToken()),
                         AuthState(accessToken: validSuperTokensToken(), refreshToken: "cached-refresh")] {
                let calls = MigrationCalls()
                await setAuthState(auth)
                await LegacySessionMigrator.migrateIfNeeded(authState: auth, dependencies: makeDependencies(calls: calls))
                #expect(calls.migrateAccessTokens.isEmpty)
                #expect(Context.currentContext.store.state.auth.accessToken == auth.accessToken)
                #expect(Context.currentContext.store.state.auth.refreshToken == auth.refreshToken)
            }
        }
    }

    @Test(arguments: [false, true]) func supersededFlightDoesNotBlockNewCredentials(signOutFirst: Bool) async throws {
        try await withIsolatedStore {
            let wasInitialized = Rownd.isSuperTokensInitialized
            Rownd.isSuperTokensInitialized = false
            defer { Rownd.isSuperTokensInitialized = wasInitialized }
            let gateA = MigrationResponseGate()
            let gateB = MigrationResponseGate()
            let calls = MigrationCalls()
            var dependenciesA = makeDependencies(calls: calls)
            dependenciesA.client = LegacySessionMigrationClient(migrateHandler: { _ in try await gateA.response() })
            let authA = AuthState(accessToken: validLegacyToken(), refreshToken: "refresh-A")
            await setAuthState(authA)
            let taskA = Task {
                await LegacySessionMigrator.migrateIfNeeded(authState: authA, dependencies: dependenciesA)
                await gateA.markCallerReturned()
            }
            await gateA.waitUntilStarted()
            if signOutFirst { await Rownd.signOut() }
            let authB = AuthState(accessToken: validLegacyToken(), refreshToken: "refresh-B")
            await setAuthState(authB)
            var dependenciesB = makeDependencies(calls: calls)
            dependenciesB.client = LegacySessionMigrationClient(migrateHandler: { token in
                calls.migrateAccessTokens.append(token)
                return try await gateB.response()
            })
            let taskB = Task { await LegacySessionMigrator.migrateIfNeeded(authState: authB, dependencies: dependenciesB) }
            try await Task.sleep(nanoseconds: 150_000_000)
            let startedB = !calls.migrateAccessTokens.isEmpty
            #expect(startedB, "B must start while superseded A is still suspended")
            #expect(await gateA.callerReturned, "Starting B must release A's waiters before its transport responds")
            await gateA.finish(.failure(RowndError("HTTP 500")))
            await taskA.value
            #expect(Context.currentContext.store.state.auth.refreshToken == "refresh-B")
            if startedB {
                let joinedB = Task { await LegacySessionMigrator.migrateIfNeeded(authState: authB, dependencies: dependenciesB) }
                try await Task.sleep(nanoseconds: 50_000_000)
                #expect(calls.migrateAccessTokens.count == 1, "Late A completion must not clear B's flight")
                await gateB.finish(.failure(RowndError("HTTP 500")))
                await joinedB.value
            }
            await taskB.value
        }
    }

    @Test func migrationHTTPRequiresEverySessionHeader() async throws {
        try await withIsolatedStore {
            let originalConfig = Rownd.config
            defer { Rownd.config = originalConfig }
            Rownd.config.supertokens = RowndSuperTokensConfig(
                appName: "Example", apiDomain: "https://migration.example.com", apiBasePath: "/auth"
            )
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [LegacyRefreshURLProtocol.self]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let headers = ["st-access-token": "access", "st-refresh-token": "refresh", "front-token": "front"]
            for missing in [nil, "st-access-token", "st-refresh-token", "front-token"] {
                var responseHeaders = headers
                if let missing { responseHeaders.removeValue(forKey: missing) }
                var url = URLComponents(string: "https://migration.example.com")!
                url.queryItems = [
                    URLQueryItem(name: "status", value: "200"),
                    URLQueryItem(name: "headers", value: String(data: try JSONEncoder().encode(responseHeaders), encoding: .utf8))
                ]
                let client = LegacySessionMigrationClient(apiDomain: url.string, session: session)
                do {
                    let result = try await client.migrate(legacyToken: "legacy")
                    #expect(missing == nil)
                    #expect(result == .migrated(SuperTokensSessionTokens(
                        accessToken: "access", refreshToken: "refresh", frontToken: "front", antiCSRF: nil
                    )))
                } catch {
                    #expect(missing != nil)
                }
            }
        }
    }

    @Test func ordinarySignOutDuringMigrationPreventsLateFailureMutation() async throws {
        try await withIsolatedStore {
            let wasInitialized = Rownd.isSuperTokensInitialized
            Rownd.isSuperTokensInitialized = false
            defer { Rownd.isSuperTokensInitialized = wasInitialized }
            let gate = MigrationResponseGate()
            let calls = MigrationCalls()
            var dependencies = makeDependencies(calls: calls)
            dependencies.client = LegacySessionMigrationClient(migrateHandler: { _ in
                try await gate.response()
            })
            let auth = AuthState(accessToken: validLegacyToken(), refreshToken: "legacy-refresh")
            await setAuthState(auth)
            let retry = Task { await LegacySessionMigrator.migrateIfNeeded(authState: auth, dependencies: dependencies) }
            await gate.waitUntilStarted()
            let permit = SuperTokensSessionBridge.captureAuthOperationPermit()
            await Rownd.signOut()
            #expect(!SuperTokensSessionBridge.isAuthOperationPermitValid(permit))
            await gate.finish(.failure(RowndError("HTTP 500")))
            await retry.value
            #expect(Context.currentContext.store.state.auth.accessToken == nil)
            #expect(Context.currentContext.store.state.auth.refreshToken == nil)
            #expect(!Context.currentContext.store.state.auth.isLoading)
        }
    }

    @Test func concurrentMigrationSharesSingleFlight() async throws {
        try await withIsolatedStore {
            let gate = MigrationResponseGate()
            let calls = MigrationCalls()
            var dependencies = makeDependencies(calls: calls)
            dependencies.client = LegacySessionMigrationClient(migrateHandler: { token in
                calls.migrateAccessTokens.append(token)
                return try await gate.response()
            })
            let auth = AuthState(accessToken: validLegacyToken(), refreshToken: "legacy-refresh")
            await setAuthState(auth)
            let retry = Task { await LegacySessionMigrator.migrateIfNeeded(authState: auth, dependencies: dependencies) }
            await gate.waitUntilStarted()
            let secondRetry = Task { await LegacySessionMigrator.migrateIfNeeded(authState: auth, dependencies: dependencies) }
            await gate.finish(.failure(RowndError("HTTP 500")))
            await retry.value
            await secondRetry.value
            #expect(calls.migrateAccessTokens.count == 1)
            #expect(!Context.currentContext.store.state.auth.isAuthenticated)
        }
    }

    @Test func migrationResponseCannotOverwriteNewerCredentials() async throws {
        try await withIsolatedStore {
            let replacement = AuthState(accessToken: validLegacyToken(), refreshToken: "new-user-refresh")
            let calls = MigrationCalls()
            var dependencies = makeDependencies(calls: calls)
            dependencies.client = LegacySessionMigrationClient(migrateHandler: { token in
                await setAuthState(replacement)
                calls.migrateAccessTokens.append(token)
                return .migrated(SuperTokensSessionTokens(
                    accessToken: validSuperTokensToken(), refreshToken: "st-refresh", frontToken: "front", antiCSRF: nil
                ))
            })
            let auth = AuthState(accessToken: expiredLegacyToken(), refreshToken: "old-refresh")
            await setAuthState(auth)
            await LegacySessionMigrator.migrateIfNeeded(authState: auth, dependencies: dependencies)
            #expect(Context.currentContext.store.state.auth.accessToken == replacement.accessToken)
            #expect(Context.currentContext.store.state.auth.refreshToken == replacement.refreshToken)
            #expect(calls.migrateAccessTokens == ["old-refresh"])
        }
    }

    @Test func usableSessionWithFailedSyncDoesNotDiscardLegacyCredentials() async throws {
        try await withIsolatedStore {
            let calls = MigrationCalls()
            var dependencies = makeDependencies(calls: calls)
            dependencies.doesSuperTokensSessionExist = { true }
            dependencies.syncRowndAuthStateFromSuperTokens = { _ in false }
            let auth = AuthState(isLoading: true, accessToken: validLegacyToken(), refreshToken: "old-refresh")
            await setAuthState(auth)
            await LegacySessionMigrator.migrateIfNeeded(authState: auth, dependencies: dependencies)
            #expect(Context.currentContext.store.state.auth.accessToken == auth.accessToken)
            #expect(Context.currentContext.store.state.auth.refreshToken == auth.refreshToken)
            #expect(!Context.currentContext.store.state.auth.isLoading)
            #expect(calls.migrateAccessTokens.isEmpty)
        }
    }

    @Test(arguments: [200, 400, 401, 403, 404, 409, 410, 429, 500, 503], ["{}", "not json"])
    func migrationHTTPFailureClearsProfileAndDoesNotRetryOnRelaunch(status: Int, body: String) async throws {
        try await withIsolatedStore {
            let originalConfig = Rownd.config
            defer { Rownd.config = originalConfig }
            Rownd.config.supertokens = RowndSuperTokensConfig(
                appName: "Example", apiDomain: "https://migration.example.com", apiBasePath: "/auth"
            )
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [LegacyRefreshURLProtocol.self]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            var url = URLComponents(string: "https://migration.example.com")!
            url.queryItems = [URLQueryItem(name: "status", value: String(status)), URLQueryItem(name: "body", value: body)]
            let calls = MigrationCalls()
            let client = LegacySessionMigrationClient(apiDomain: url.string, session: session)
            var dependencies = makeDependencies(calls: calls)
            dependencies.client = LegacySessionMigrationClient(migrateHandler: { token in
                calls.migrateAccessTokens.append(token)
                return try await client.migrate(legacyToken: token)
            })
            try await assertFailedMigrationLifecycle(dependencies: dependencies, calls: calls, expectedRequests: 1)
        }
    }

    @Test(arguments: [URLError.Code.notConnectedToInternet, .timedOut])
    func exhaustedMigrationNetworkFailureClearsProfileAndDoesNotRetryOnRelaunch(code: URLError.Code) async throws {
        try await withIsolatedStore {
            let calls = MigrationCalls()
            calls.migrateErrors = [URLError(code), URLError(code)]
            try await assertFailedMigrationLifecycle(dependencies: makeDependencies(calls: calls), calls: calls, expectedRequests: 2)
        }
    }

    @MainActor private func assertFailedMigrationLifecycle(
        dependencies: LegacySessionMigrationDependencies, calls: MigrationCalls, expectedRequests: Int
    ) async throws {
        let auth = AuthState(isLoading: true, accessToken: validLegacyToken(), refreshToken: "legacy-refresh")
        let events = LegacyMigrationEventHandler()
        RowndEventEmitter.resetForTests()
        defer { RowndEventEmitter.resetForTests() }
        Rownd.addEventHandler(events)
        setAuthState(auth)
        Context.currentContext.store.dispatch(SetUserData(data: ["user_id": "old-user"]))
        await LegacySessionMigrator.migrateIfNeeded(authState: auth, dependencies: dependencies)
        let state = Context.currentContext.store.state!
        #expect(!state.auth.isAuthenticated)
        #expect(state.auth.accessToken == nil)
        #expect(state.auth.refreshToken == nil)
        #expect(state.user.data.isEmpty)
        #expect(!state.auth.isLoading)
        #expect(events.events == [.signOut])
        let persisted = try #require(Storage.shared.get(forKey: "RowndState"))
        let reloaded = try JSONDecoder().decode(RowndState.self, from: Data(persisted.utf8))
        Context.currentContext.store.dispatch(InitializeRowndState(payload: reloaded))
        await LegacySessionMigrator.migrateIfNeeded(authState: reloaded.auth, dependencies: dependencies)
        #expect(calls.migrateAccessTokens.count == expectedRequests)
        #expect(!Context.currentContext.store.state.auth.isAuthenticated)
        #expect(Context.currentContext.store.state.user.data.isEmpty)
        #expect(events.events == [.signOut])

        var signedInDependencies = dependencies
        signedInDependencies.doesSuperTokensSessionExist = { true }
        await LegacySessionMigrator.migrateIfNeeded(authState: reloaded.auth, dependencies: signedInDependencies)
        #expect(Context.currentContext.store.state.auth.isAuthenticated)
        #expect(AuthState.isSuperTokensAccessToken(Context.currentContext.store.state.auth.accessToken))
        #expect(calls.migrateAccessTokens.count == expectedRequests)
    }

    @Test func boundedMigrationRetryUsesRefreshTokenAndSynchronizesSession() async throws {
        try await withIsolatedStore {
            let calls = MigrationCalls()
            calls.migrateErrors = [URLError(.timedOut)]
            calls.migrateResults = [.migrated(SuperTokensSessionTokens(
                accessToken: validSuperTokensToken(), refreshToken: "st-refresh", frontToken: "front", antiCSRF: nil
            ))]
            let dependencies = makeDependencies(calls: calls)
            let auth = AuthState(isLoading: true, accessToken: expiredLegacyToken(), refreshToken: "old")
            await setAuthState(auth)
            await LegacySessionMigrator.migrateIfNeeded(authState: auth, dependencies: dependencies)
            #expect(!Context.currentContext.store.state.auth.isLoading)
            #expect(calls.migrateAccessTokens == ["old", "old"])
            #expect(Context.currentContext.store.state.auth.isAuthenticated)
        }
    }

    @Test(arguments: [false, true], [false, true])
    func staleFailuresCannotClearNewerCredentialsOrSession(networkFailure: Bool, replaceContext: Bool) async throws {
        try await withIsolatedStore {
            for replacement in [validLegacyToken(), validSuperTokensToken()] {
                let calls = MigrationCalls()
                var dependencies = makeDependencies(calls: calls)
                dependencies.client = LegacySessionMigrationClient(migrateHandler: { _ in
                    await MainActor.run {
                        if replaceContext { _ = Context(createStore()) }
                        setAuthState(AuthState(accessToken: replacement, refreshToken: "new-refresh"))
                        Context.currentContext.store.dispatch(SetUserData(data: ["user_id": "new-user"]))
                    }
                    if networkFailure { throw URLError(.timedOut) }
                    throw RowndError("HTTP 500")
                })
                let auth = AuthState(accessToken: validLegacyToken(), refreshToken: "old-refresh")
                await setAuthState(auth)
                await LegacySessionMigrator.migrateIfNeeded(authState: auth, dependencies: dependencies)
                #expect(Context.currentContext.store.state.auth.accessToken == replacement)
                #expect(Context.currentContext.store.state.auth.refreshToken == "new-refresh")
                #expect(Context.currentContext.store.state.user.data["user_id"]?.value as? String == "new-user")
            }
        }
    }

    @Test(arguments: [false, true]) func nativeSessionArrivingDuringMigrationFailureWins(networkFailure: Bool) async throws {
        try await withIsolatedStore {
            let calls = MigrationCalls()
            calls.migrateErrors = networkFailure ? [URLError(.timedOut), URLError(.timedOut)] : [RowndError("HTTP 500")]
            var dependencies = makeDependencies(calls: calls)
            dependencies.doesSuperTokensSessionExist = { !calls.migrateAccessTokens.isEmpty }
            let auth = AuthState(accessToken: validLegacyToken(), refreshToken: "old-refresh")
            await setAuthState(auth)
            await LegacySessionMigrator.migrateIfNeeded(authState: auth, dependencies: dependencies)
            #expect(AuthState.isSuperTokensAccessToken(Context.currentContext.store.state.auth.accessToken))
        }
    }

    @Test(arguments: [false, true]) func synchronizesWhenSuperTokensSessionAlreadyExists(refreshOnly: Bool) async throws {
        try await withIsolatedStore {
            var didBootstrap = false
            var syncCount = 0
            var calls = MigrationCalls()
            var dependencies = makeDependencies(calls: calls)
            dependencies.doesSuperTokensSessionExist = { true }
            dependencies.bootstrapSession = { _, _ in didBootstrap = true; return true }
            dependencies.syncRowndAuthStateFromSuperTokens = { _ in syncCount += 1; return true }

            let auth = AuthState(accessToken: refreshOnly ? nil : validLegacyToken(), refreshToken: "legacy-refresh-token")
            await setAuthState(auth)

            await LegacySessionMigrator.migrateIfNeeded(
                authState: auth,
                dependencies: dependencies
            )

            #expect(!didBootstrap)
            #expect(syncCount == 1)
            #expect(calls.migrateAccessTokens.isEmpty)
        }
    }

    @Test func validLegacySessionMigratesWithoutLegacyRefresh() async throws {
        try await withIsolatedStore {
            let migratedAccessToken = validLegacyToken()
            var calls = MigrationCalls()
            calls.migrateResults = [.migrated(SuperTokensSessionTokens(
                accessToken: migratedAccessToken,
                refreshToken: "st-refresh-token",
                frontToken: "front-token",
                antiCSRF: "anti-csrf-token"
            ))]

            var bootstrappedTokens: SuperTokensSessionTokens?
            var syncCount = 0
            var dependencies = makeDependencies(calls: calls)
            dependencies.bootstrapSession = { tokens, _ in bootstrappedTokens = tokens; return true }
            dependencies.syncRowndAuthStateFromSuperTokens = { condition in
                await MainActor.run { guard condition() else { return false }; syncCount += 1; syncTestSession(); return true }
            }

            await setAuthState(AuthState(accessToken: validLegacyToken(), refreshToken: "legacy-refresh-token"))

            await LegacySessionMigrator.migrateIfNeeded(
                authState: Context.currentContext.store.state.auth,
                dependencies: dependencies
            )

            #expect(calls.migrateAccessTokens == ["legacy-refresh-token"])
            #expect(bootstrappedTokens == SuperTokensSessionTokens(
                accessToken: migratedAccessToken,
                refreshToken: "st-refresh-token",
                frontToken: "front-token",
                antiCSRF: "anti-csrf-token"
            ))
            #expect(syncCount == 1)
            #expect(await currentRefreshToken() == nil)
        }
    }

    @Test(arguments: [false, true]) func expiredOrMissingAccessMigratesWithRefreshToken(refreshOnly: Bool) async throws {
        try await withIsolatedStore {
            let migratedAccessToken = validLegacyToken()
            var calls = MigrationCalls()
            calls.migrateResults = [.migrated(SuperTokensSessionTokens(
                accessToken: migratedAccessToken,
                refreshToken: "st-refresh-token",
                frontToken: "front-token",
                antiCSRF: nil
            ))]

            var bootstrappedTokens: SuperTokensSessionTokens?
            var dependencies = makeDependencies(calls: calls)
            dependencies.bootstrapSession = { tokens, _ in bootstrappedTokens = tokens; return true }

            await setAuthState(AuthState(accessToken: refreshOnly ? nil : expiredLegacyToken(), refreshToken: "legacy-refresh-token"))

            await LegacySessionMigrator.migrateIfNeeded(
                authState: Context.currentContext.store.state.auth,
                dependencies: dependencies
            )

            #expect(calls.migrateAccessTokens == ["legacy-refresh-token"])
            #expect(bootstrappedTokens?.accessToken == migratedAccessToken)
            #expect(await currentRefreshToken() == nil)
        }
    }

    @Test func bootstrapFailureClearsAttemptedLegacySession() async throws {
        try await withIsolatedStore {
            var calls = MigrationCalls()
            calls.migrateResults = [.migrated(SuperTokensSessionTokens(
                accessToken: validSuperTokensToken(),
                refreshToken: "st-refresh-token",
                frontToken: "front-token",
                antiCSRF: nil
            ))]

            var syncCount = 0
            var dependencies = makeDependencies(calls: calls)
            dependencies.bootstrapSession = { _, _ in false }
            dependencies.syncRowndAuthStateFromSuperTokens = { _ in syncCount += 1; return true }

            await setAuthState(AuthState(accessToken: validLegacyToken(), refreshToken: "legacy-refresh-token"))
            await LegacySessionMigrator.migrateIfNeeded(
                authState: Context.currentContext.store.state.auth,
                dependencies: dependencies
            )

            #expect(syncCount == 0)
            #expect(await currentRefreshToken() == nil)
            #expect(Context.currentContext.store.state.auth.accessToken == nil)
            #expect(!Context.currentContext.store.state.auth.isLoading)
        }
    }

    @Test func failedRefreshOnlyMigrationClearsPersistedLegacySession() async throws {
        try await withIsolatedStore {
            let calls = MigrationCalls()
            calls.migrateErrors = [RowndError("HTTP 500")]
            let dependencies = makeDependencies(calls: calls)
            let auth = AuthState(refreshToken: "legacy-refresh")
            await setAuthState(auth)
            await MainActor.run {
                Context.currentContext.store.dispatch(SetUserData(data: ["user_id": "legacy-user"]))
            }

            await LegacySessionMigrator.migrateIfNeeded(authState: auth, dependencies: dependencies)

            let state = Context.currentContext.store.state!
            #expect(state.auth.accessToken == nil)
            #expect(state.auth.refreshToken == nil)
            #expect(state.user.data.isEmpty)
            let persisted = try #require(Storage.shared.get(forKey: "RowndState"))
            let reloaded = try JSONDecoder().decode(RowndState.self, from: Data(persisted.utf8))
            #expect(reloaded.auth.accessToken == nil)
            #expect(reloaded.auth.refreshToken == nil)
            await LegacySessionMigrator.migrateIfNeeded(authState: reloaded.auth, dependencies: dependencies)
            #expect(calls.migrateAccessTokens == ["legacy-refresh"])
        }
    }

    @Test(arguments: [false, true]) func requestPreparationFailureRetainsLegacyCredentials(invalidDomain: Bool) async throws {
        try await withIsolatedStore {
            let originalConfig = Rownd.config
            defer { Rownd.config = originalConfig }
            Rownd.config = RowndConfig()
            if invalidDomain {
                Rownd.config.supertokens = RowndSuperTokensConfig(appName: "Example", apiDomain: "http://[", apiBasePath: "/auth")
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [LegacyRefreshURLProtocol.self]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let requestsBefore = LegacyRefreshURLProtocol.requestCount
            let calls = MigrationCalls()
            var dependencies = makeDependencies(calls: calls)
            dependencies.client = LegacySessionMigrationClient(session: session)
            let auth = AuthState(accessToken: expiredLegacyToken(), refreshToken: "old-refresh")
            await MainActor.run {
                setAuthState(auth)
                Context.currentContext.store.dispatch(SetUserData(data: ["user_id": "legacy-user"]))
            }
            await LegacySessionMigrator.migrateIfNeeded(authState: auth, dependencies: dependencies)
            #expect(LegacyRefreshURLProtocol.requestCount == requestsBefore)
            #expect(Context.currentContext.store.state.auth.accessToken == auth.accessToken)
            #expect(Context.currentContext.store.state.auth.refreshToken == auth.refreshToken)
            #expect(!Context.currentContext.store.state.auth.isLoading)
            #expect(Context.currentContext.store.state.user.data["user_id"]?.value as? String == "legacy-user")
            let persisted = try #require(Storage.shared.get(forKey: "RowndState"))
            let state = try JSONDecoder().decode(RowndState.self, from: Data(persisted.utf8))
            #expect(state.auth.accessToken == auth.accessToken)
            #expect(state.auth.refreshToken == auth.refreshToken)
        }
    }

    @Test func failedMigrationClearsItsPersistedLegacyCredentials() async throws {
        try await withIsolatedStore {
            let calls = MigrationCalls()
            let auth = AuthState(accessToken: expiredLegacyToken(), refreshToken: "old-refresh")
            calls.migrateErrors = [URLError(.timedOut), URLError(.timedOut)]
            var dependencies = makeDependencies(calls: calls)
            let migrate = dependencies.client
            dependencies.client = LegacySessionMigrationClient(
                migrateHandler: { token in
                    let persisted = try #require(Storage.shared.get(forKey: "RowndState"))
                    let state = try JSONDecoder().decode(RowndState.self, from: Data(persisted.utf8))
                    #expect(state.auth.accessToken == auth.accessToken)
                    #expect(state.auth.refreshToken == auth.refreshToken)
                    return try await migrate.migrate(legacyToken: token)
                }
            )
            await setAuthState(auth)

            await LegacySessionMigrator.migrateIfNeeded(authState: Context.currentContext.store.state.auth,
                                                       dependencies: dependencies)

            #expect(Context.currentContext.store.state.auth.accessToken == nil)
            #expect(await currentRefreshToken() == nil)
            await LegacySessionMigrator.migrateIfNeeded(authState: Context.currentContext.store.state.auth,
                                                       dependencies: dependencies)
            #expect(calls.migrateAccessTokens == Array(repeating: "old-refresh", count: 2))
        }
    }

    @Test func unauthorizedMigrationSignsOut() async throws {
        try await withIsolatedStore {
            var calls = MigrationCalls()
            calls.migrateErrors = [RowndError("HTTP 401")]

            var signOutCount = 0
            var dependencies = makeDependencies(calls: calls)
            dependencies.signOut = { _ in signOutCount += 1 }

            let auth = AuthState(accessToken: validLegacyToken(), refreshToken: "legacy-refresh-token")
            await setAuthState(auth)

            await LegacySessionMigrator.migrateIfNeeded(
                authState: auth,
                dependencies: dependencies
            )

            #expect(signOutCount == 1)
        }
    }

    @Test func conflictMigrationSyncsExistingSession() async throws {
        try await withIsolatedStore {
            var calls = MigrationCalls()
            calls.migrateResults = [.sessionAlreadyExists]

            var syncCount = 0
            var didBootstrap = false
            var dependencies = makeDependencies(calls: calls)
            dependencies.doesSuperTokensSessionExist = { !calls.migrateAccessTokens.isEmpty }
            dependencies.syncRowndAuthStateFromSuperTokens = { condition in
                await MainActor.run { guard condition() else { return false }; syncCount += 1; syncTestSession(); return true }
            }
            dependencies.bootstrapSession = { _, _ in didBootstrap = true; return true }

            await setAuthState(AuthState(accessToken: validLegacyToken(), refreshToken: "legacy-refresh-token"))

            await LegacySessionMigrator.migrateIfNeeded(
                authState: Context.currentContext.store.state.auth,
                dependencies: dependencies
            )

            #expect(syncCount == 1)
            #expect(!didBootstrap)
            #expect(await currentRefreshToken() == nil)
        }
    }

    @Test func migrationNetworkFailureRetriesOnce() async throws {
        try await withIsolatedStore {
            let migratedAccessToken = validLegacyToken()
            var calls = MigrationCalls()
            calls.migrateErrors = [URLError(.notConnectedToInternet)]
            calls.migrateResults = [.migrated(SuperTokensSessionTokens(
                accessToken: migratedAccessToken,
                refreshToken: "st-refresh-token",
                frontToken: "front-token",
                antiCSRF: nil
            ))]

            var bootstrappedTokens: SuperTokensSessionTokens?
            var dependencies = makeDependencies(calls: calls)
            dependencies.bootstrapSession = { tokens, _ in bootstrappedTokens = tokens; return true }

            let auth = AuthState(accessToken: validLegacyToken(), refreshToken: "legacy-refresh-token")
            await setAuthState(auth)

            await LegacySessionMigrator.migrateIfNeeded(
                authState: auth,
                dependencies: dependencies
            )

            #expect(calls.migrateAccessTokens.count == 2)
            #expect(bootstrappedTokens?.accessToken == migratedAccessToken)
        }
    }

    @Test func migratesLegacyTokenEvenWhenCompatibilityAuthStateRejectsIt() async throws {
        try await withIsolatedStore {
            let originalConfig = Rownd.config
            defer { Rownd.config = originalConfig }

            Rownd.config.supertokens = RowndSuperTokensConfig(
                appName: "Example App",
                apiDomain: "https://api.example.com",
                apiBasePath: "/auth"
            )

            let legacyAuthState = AuthState(accessToken: validLegacyToken(), refreshToken: "legacy-refresh-token")
            let migratedAccessToken = validSuperTokensToken()
            var calls = MigrationCalls()
            calls.migrateResults = [.migrated(SuperTokensSessionTokens(
                accessToken: migratedAccessToken,
                refreshToken: "st-refresh-token",
                frontToken: "front-token",
                antiCSRF: nil
            ))]

            var bootstrappedTokens: SuperTokensSessionTokens?
            var dependencies = makeDependencies(calls: calls)
            dependencies.bootstrapSession = { tokens, _ in bootstrappedTokens = tokens; return true }

            await setAuthState(legacyAuthState)

            #expect(!legacyAuthState.isAccessTokenValid)

            await LegacySessionMigrator.migrateIfNeeded(
                authState: legacyAuthState,
                dependencies: dependencies
            )

            #expect(calls.migrateAccessTokens == ["legacy-refresh-token"])
            #expect(bootstrappedTokens?.accessToken == migratedAccessToken)
        }
    }

    private func makeDependencies(calls: MigrationCalls) -> LegacySessionMigrationDependencies {
        LegacySessionMigrationDependencies(
            doesSuperTokensSessionExist: { false },
            bootstrapSession: { _, _ in true },
            syncRowndAuthStateFromSuperTokens: { condition in
                await MainActor.run { guard condition() else { return false }; syncTestSession(); return true }
            },
            signOut: { attempt in
                await Rownd.signOutForMigrationFailure(attempt: attempt)
            },
            client: LegacySessionMigrationClient(
                migrateHandler: { legacyToken in
                    calls.migrateAccessTokens.append(legacyToken)
                    if !calls.migrateErrors.isEmpty {
                        throw calls.migrateErrors.removeFirst()
                    }
                    guard !calls.migrateResults.isEmpty else { throw RowndError("HTTP 401") }
                    return calls.migrateResults.removeFirst()
                }
            )
        )
    }

    private func withIsolatedStore(_ operation: @escaping @Sendable () async throws -> Void) async throws {
        try await withGlobalTestLock {
            let originalContext = Context.currentContext
            _ = Context(createStore())
            defer { Context.currentContext = originalContext }

            try await operation()
        }
    }

    @MainActor private func setAuthState(_ authState: AuthState) {
        Context.currentContext.store.dispatch(SetAuthState(payload: authState))
    }

    @MainActor private func syncTestSession() {
        setAuthState(AuthState(accessToken: validSuperTokensToken()))
    }

    @MainActor private func currentRefreshToken() -> String? {
        Context.currentContext.store.state.auth.refreshToken
    }

    private func validLegacyToken() -> String {
        generateJwt(
            expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
            appUserId: "app-user-id"
        )
    }

    private func expiredLegacyToken() -> String {
        generateJwt(expires: Date(timeIntervalSinceNow: -3600).timeIntervalSince1970)
    }

    private func validSuperTokensToken() -> String {
        generateJwt(
            expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970,
            sessionHandle: "session-handle"
        )
    }
}

private final class MigrationCalls: @unchecked Sendable {
    var migrateAccessTokens: [String] = []
    var migrateResults: [LegacySessionMigrationResult] = []
    var migrateErrors: [Error] = []
}

private final class LegacyMigrationEventHandler: RowndEventHandlerDelegate {
    var events: [RowndEventType] = []

    func handleRowndEvent(_ event: RowndEvent) { events.append(event.event) }
}

private actor MigrationResponseGate {
    private(set) var callerReturned = false
    private var continuation: CheckedContinuation<LegacySessionMigrationResult, Error>?
    private var startedWaiter: CheckedContinuation<Void, Never>?

    func response() async throws -> LegacySessionMigrationResult {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            startedWaiter?.resume()
            startedWaiter = nil
        }
    }

    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }

    func finish(_ result: Result<LegacySessionMigrationResult, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }

    func markCallerReturned() { callerReturned = true }
}

private final class LegacyRefreshURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var count = 0
    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.count += 1
        Self.lock.unlock()
        let url = request.url!
        let status = Int(URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first!.value!)!
        let headersJSON = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "headers" }?.value
        let headers = headersJSON.flatMap { try? JSONDecoder().decode([String: String].self, from: Data($0.utf8)) }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "body" }?.value ?? "{}"
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
