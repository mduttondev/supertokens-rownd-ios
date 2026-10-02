import Foundation
import Network
import Testing
@testable import SuperTokensIOS
@testable import Rownd

@Suite(.serialized) struct LegacyMigrationTransportTests {
    @Test(arguments: ["valid", "expired", "missing", "empty", "access-only"])
    func directMigrationSendsLegacyBearerAndCompleteHeaders(state: String) async throws {
        try await withTransport { server, storage, interceptions in
            var auth = Context.currentContext.store.state.auth
            if state == "expired" {
                auth.accessToken = generateJwt(expires: Date(timeIntervalSinceNow: -3600).timeIntervalSince1970)
            } else if state == "missing" {
                auth.accessToken = nil
            } else if state == "empty" {
                auth.accessToken = ""
            } else if state == "access-only" {
                auth.refreshToken = nil
            }
            let legacyToken = try #require(auth.refreshToken ?? auth.accessToken)
            let initialAuth = auth
            await MainActor.run { Context.currentContext.store.dispatch(SetAuthState(payload: initialAuth)) }
            let task = Task { await LegacySessionMigrator.migrateIfNeeded(authState: initialAuth) }
            let request = try await server.nextRequest()
            let raw = request.raw.lowercased()
            #expect(raw.hasPrefix("post /auth/plugin/rownd/migrate "))
            #expect(raw.contains("authorization: bearer \(legacyToken.lowercased())\r\n"))
            #expect(raw.contains("rid: session\r\n"))
            #expect(raw.contains("fdi-version: 1.18\r\n"))
            #expect(raw.contains("st-auth-mode: header\r\n"))
            #expect(raw.contains("content-type: application/json\r\n"))
            let headers = try sessionHeaders()
            request.respond(headers: headers)
            await task.value
            #expect(storage.get("st-storage-item-st-access-token") == headers["st-access-token"])
            #expect(Context.currentContext.store.state.auth.refreshToken == nil)
            #expect(interceptions.count == 0)
        }
    }

    @Test func nativeRefreshStorageIsNotUsedAsLegacyCredentials() async throws {
        try await withTransport { _, storage, _ in
            #expect(storage.set("st-storage-item-st-refresh-token", value: "native-refresh"))
            let auth = AuthState()
            await MainActor.run { Context.currentContext.store.dispatch(SetAuthState(payload: auth)) }
            var dependencies = LegacySessionMigrationDependencies()
            dependencies.doesSuperTokensSessionExist = { false }
            dependencies.client = LegacySessionMigrationClient(migrateHandler: { _ in
                Issue.record("Native refresh credentials must not be sent to migration")
                return .sessionAlreadyExists
            })
            await LegacySessionMigrator.migrateIfNeeded(authState: auth, dependencies: dependencies)
            #expect(storage.get("st-storage-item-st-refresh-token") == "native-refresh")
        }
    }

    @Test(arguments: [false, true]) func supersededMigrationCannotInstallIntoNewLegacyFlight(replaceAgain: Bool) async throws {
        let gate = MigrationInstallationGate()
        try await withTransport(installationGate: gate) { server, storage, _ in
            let authA = Context.currentContext.store.state.auth
            let taskA = Task { await LegacySessionMigrator.migrateIfNeeded(authState: authA) }
            let request = try await server.nextRequest()
            request.respond(headers: try sessionHeaders())
            await gate.waitUntilInstalling()
            let authB = AuthState(accessToken: authA.accessToken, refreshToken: "legacy-B")
            await MainActor.run { Context.currentContext.store.dispatch(SetAuthState(payload: authB)) }
            let callsB = InterceptionCounter()
            let failureB = MigrationAdoptionReturnGate()
            var dependenciesB = LegacySessionMigrationDependencies()
            dependenciesB.client = LegacySessionMigrationClient(migrateHandler: { _ in
                callsB.increment()
                await failureB.pause()
                throw RowndError("B's migration request failed")
            })
            let taskB = Task { await LegacySessionMigrator.migrateIfNeeded(authState: authB, dependencies: dependenciesB) }
            // A's waiter returns only once B has retired its still-installing flight.
            await taskA.value
            var expectedAuth = authB
            var latestTask = taskB
            if replaceAgain {
                expectedAuth.refreshToken = "legacy-C"
                let authC = expectedAuth
                await MainActor.run { Context.currentContext.store.dispatch(SetAuthState(payload: authC)) }
                latestTask = Task { await LegacySessionMigrator.migrateIfNeeded(authState: authC, dependencies: dependenciesB) }
                await taskB.value
            }
            gate.release()
            await failureB.waitUntilInstalled()
            #expect(callsB.count == 1)
            #expect(storage.get("st-storage-item-st-access-token") == nil)
            #expect(storage.get("st-storage-item-st-refresh-token") == nil)
            #expect(Context.currentContext.store.state.auth.accessToken == expectedAuth.accessToken)
            #expect(Context.currentContext.store.state.auth.refreshToken == expectedAuth.refreshToken)
            #expect(Context.currentContext.store.state.auth.isLoading)
            failureB.release()
            await latestTask.value
            #expect(Context.currentContext.store.state.auth.accessToken == nil)
            #expect(Context.currentContext.store.state.auth.refreshToken == nil)
            #expect(!Context.currentContext.store.state.auth.isLoading)
        }
    }

    @Test(arguments: [false, true]) func supersededCompletedAdoptionDiscardsOnlyItsOwnSession(nativeReplacement: Bool) async throws {
        try await withTransport { server, storage, _ in
            let gate = MigrationAdoptionReturnGate()
            let authA = Context.currentContext.store.state.auth
            var dependenciesA = LegacySessionMigrationDependencies()
            let bootstrap = dependenciesA.bootstrapSession
            dependenciesA.bootstrapSession = { tokens, attempt in
                let installed = await bootstrap(tokens, attempt)
                await gate.pause()
                return installed
            }
            let taskA = Task { await LegacySessionMigrator.migrateIfNeeded(authState: authA, dependencies: dependenciesA) }
            let request = try await server.nextRequest()
            let headersA = try sessionHeaders()
            request.respond(headers: headersA)
            await gate.waitUntilInstalled()
            #expect(storage.get("st-storage-item-st-access-token") == headersA["st-access-token"])

            let authB = AuthState(accessToken: authA.accessToken, refreshToken: "legacy-B")
            await MainActor.run { Context.currentContext.store.dispatch(SetAuthState(payload: authB)) }
            let nativeB = generateJwt(expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970, sessionHandle: "native-B")
            if nativeReplacement {
                let identity = await SuperTokensSessionBridge.adoptResponseSession(
                    SuperTokensSessionTokens(accessToken: nativeB, refreshToken: "native-refresh-B", frontToken: headersA["front-token"]!, antiCSRF: nil),
                    permit: SuperTokensSessionBridge.captureAuthOperationPermit()
                )
                #expect(identity != nil)
            }
            let callsB = InterceptionCounter()
            let failureB = MigrationAdoptionReturnGate()
            var dependenciesB = LegacySessionMigrationDependencies()
            dependenciesB.client = LegacySessionMigrationClient(migrateHandler: { _ in
                callsB.increment()
                await failureB.pause()
                throw RowndError("B's migration request failed")
            })
            let taskB = Task { await LegacySessionMigrator.migrateIfNeeded(authState: authB, dependencies: dependenciesB) }
            await taskA.value
            if !nativeReplacement {
                await failureB.waitUntilInstalled()
                #expect(Context.currentContext.store.state.auth.accessToken == authB.accessToken)
                #expect(Context.currentContext.store.state.auth.refreshToken == authB.refreshToken)
                #expect(Context.currentContext.store.state.auth.isLoading)
                failureB.release()
            }
            await taskB.value
            gate.release()
            #expect(callsB.count == (nativeReplacement ? 0 : 1))
            #expect(storage.get("st-storage-item-st-access-token") == (nativeReplacement ? nativeB : nil))
            #expect(storage.get("st-storage-item-st-refresh-token") == (nativeReplacement ? "native-refresh-B" : nil))
            #expect(Context.currentContext.store.state.auth.accessToken == (nativeReplacement ? nativeB : nil))
            #expect(!Context.currentContext.store.state.auth.isLoading)
        }
    }

    @Test(arguments: [false, true]) func legacyReplacementAfterAdoptionIsCleanedWithoutSuccessorFlight(pauseDuringSync: Bool) async throws {
        try await withTransport { server, storage, _ in
            let gate = MigrationAdoptionReturnGate()
            let authA = Context.currentContext.store.state.auth
            var dependencies = LegacySessionMigrationDependencies()
            if pauseDuringSync {
                dependencies.syncRowndAuthStateFromSuperTokens = { condition in
                    await SuperTokensSessionBridge.syncRowndAuthStateFromSuperTokens(
                        afterTokenRead: { await gate.pause() }, commitIf: condition
                    )
                }
            } else {
                let bootstrap = dependencies.bootstrapSession
                dependencies.bootstrapSession = { tokens, attempt in
                    let installed = await bootstrap(tokens, attempt)
                    await gate.pause()
                    return installed
                }
            }
            let taskA = Task { await LegacySessionMigrator.migrateIfNeeded(authState: authA, dependencies: dependencies) }
            let request = try await server.nextRequest()
            request.respond(headers: try sessionHeaders())
            await gate.waitUntilInstalled()
            let authB = AuthState(accessToken: authA.accessToken, refreshToken: "legacy-B")
            await MainActor.run { Context.currentContext.store.dispatch(SetAuthState(payload: authB)) }
            gate.release()
            await taskA.value
            #expect(storage.get("st-storage-item-st-access-token") == nil)
            #expect(storage.get("st-storage-item-st-refresh-token") == nil)
            #expect(Context.currentContext.store.state.auth.accessToken == authB.accessToken)
            #expect(Context.currentContext.store.state.auth.refreshToken == authB.refreshToken)
            #expect(!Context.currentContext.store.state.auth.isLoading)
        }
    }

    @Test func defaultTransportCannotResurrectMigrationAfterOrdinarySignOut() async throws {
        try await withTransport { server, storage, interceptions in
            let auth = Context.currentContext.store.state.auth
            let task = Task { await LegacySessionMigrator.migrateIfNeeded(authState: auth) }
            let request = try await server.nextRequest()
            #expect(request.raw.contains("Authorization: Bearer ") || request.raw.contains("authorization: Bearer "))
            let permit = SuperTokensSessionBridge.captureAuthOperationPermit()
            await Rownd.signOut()
            #expect(!SuperTokensSessionBridge.isAuthOperationPermitValid(permit))
            request.respond(headers: try sessionHeaders())
            await task.value
            try await Task.sleep(nanoseconds: 100_000_000)
            #expect(storage.get("st-storage-item-st-access-token") == nil)
            #expect(storage.get("st-storage-item-st-refresh-token") == nil)
            #expect(storage.get("supertokens-ios-fronttoken-key") == nil)
            #expect(Context.currentContext.store.state.auth.accessToken == nil)
            #expect(!Context.currentContext.store.state.auth.isLoading)
            #expect(interceptions.count == 0)
        }
    }

    @Test(arguments: [false, true])
    func invalidMigrationResponseClearsLegacyWithoutSDKMutationAndFreshCredentialsCanMigrate(invalidTokens: Bool) async throws {
        try await withTransport { server, storage, interceptions in
            let original = Context.currentContext.store.state.auth
            let headers = try sessionHeaders()
            let task = Task { await LegacySessionMigrator.migrateIfNeeded(authState: original) }
            let request = try await server.nextRequest()
            var invalidHeaders = headers.filter { $0.key != "st-refresh-token" }
            if invalidTokens {
                invalidHeaders = headers
                invalidHeaders["st-access-token"] = "not-a-session-token"
            }
            request.respond(headers: invalidHeaders)
            await task.value
            #expect(storage.get("st-storage-item-st-access-token") == nil)
            #expect(storage.get("supertokens-ios-fronttoken-key") == nil)
            #expect(storage.get("st-storage-item-st-refresh-token") == nil)
            #expect(Context.currentContext.store.state.auth.accessToken == nil)
            #expect(Context.currentContext.store.state.auth.refreshToken == nil)
            #expect(!Context.currentContext.store.state.auth.isLoading)
            #expect(interceptions.count == 0)
            await LegacySessionMigrator.migrateIfNeeded(authState: original)
            let fresh = AuthState(accessToken: original.accessToken, refreshToken: "fresh-legacy-refresh")
            await MainActor.run { Context.currentContext.store.dispatch(SetAuthState(payload: fresh)) }
            let retry = Task { await LegacySessionMigrator.migrateIfNeeded(authState: fresh) }
            let next = try await server.nextRequest()
            next.respond(headers: headers)
            await retry.value
            #expect(storage.get("st-storage-item-st-access-token") == headers["st-access-token"])
            #expect(storage.get("st-storage-item-st-refresh-token") == headers["st-refresh-token"])
            #expect(!Context.currentContext.store.state.auth.isLoading)
            #expect(Context.currentContext.store.state.auth.isAuthenticated)
            #expect(interceptions.count == 0)
        }
    }

    private func sessionHeaders() throws -> [String: String] {
        let expiry = Date(timeIntervalSinceNow: 3600).timeIntervalSince1970
        let front = try JSONSerialization.data(withJSONObject: ["uid": "1234567890", "ate": Int(expiry * 1000), "up": [:]] as [String: Any])
        return [
            "st-access-token": generateJwt(expires: expiry, sessionHandle: "transport-session"),
            "st-refresh-token": "transport-refresh",
            "front-token": front.base64EncodedString()
        ]
    }

    private func withTransport(
        installationGate: MigrationInstallationGate? = nil,
        _ operation: @escaping (MigrationHTTPServer, InMemorySessionStore, InterceptionCounter) async throws -> Void
    ) async throws {
        try await withGlobalTestLock {
            let server = try await MigrationHTTPServer.start()
            let originalContext = Context.currentContext
            let originalConfig = Rownd.config
            let originalInitialized = Rownd.isSuperTokensInitialized
            let originalStorage = SuperTokensSessionBridge.storageOverride
            let originalExecutor = SuperTokensURLProtocol.networkRequestExecutor
            SuperTokens.resetForTests()
            FrontToken.clearInMemoryCache()
            Rownd.isSuperTokensInitialized = false
            Rownd.config.supertokens = RowndSuperTokensConfig(appName: "Migration transport", apiDomain: server.baseURL, apiBasePath: "/auth")
            _ = try Rownd.initializeSuperTokensIfNeeded()
            let storage = InMemorySessionStore()
            SDKStorage.setTokenStorageForTests(storage)
            if let installationGate {
                SDKStorage.setTokenStorageForTests(GatedMigrationStorage(storage: storage, gate: installationGate))
            }
            SuperTokensSessionBridge.storageOverride = storage
            URLProtocol.registerClass(SuperTokensURLProtocol.self)
            let counter = InterceptionCounter()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = []
            let wireSession = URLSession(configuration: configuration)
            SuperTokensURLProtocol.networkRequestExecutor = { request, completion in
                counter.increment()
                wireSession.dataTask(with: request, completionHandler: completion).resume()
            }
            _ = Context(createStore())
            await MainActor.run {
                Context.currentContext.store.dispatch(SetAuthState(payload: AuthState(
                    accessToken: generateJwt(expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970, appUserId: "legacy"),
                    refreshToken: "legacy-refresh"
                )))
            }
            defer {
                server.stop()
                wireSession.invalidateAndCancel()
                SuperTokensURLProtocol.networkRequestExecutor = originalExecutor
                URLProtocol.unregisterClass(SuperTokensURLProtocol.self)
                SuperTokens.resetForTests()
                SuperTokensSessionBridge.storageOverride = originalStorage
                Context.currentContext = originalContext
                Rownd.config = originalConfig
                Rownd.isSuperTokensInitialized = originalInitialized
            }
            #expect(SuperTokensURLProtocol.canInit(with: URLRequest(url: URL(string: server.baseURL + "/auth/plugin/rownd/migrate")!)))
            try await operation(server, storage, counter)
        }
    }
}

private final class MigrationAdoptionReturnGate: Sendable {
    private let installed = AsyncStream<Void>.makeStream()
    private let resumed = AsyncStream<Void>.makeStream()

    func pause() async {
        installed.continuation.yield(())
        for await _ in resumed.stream { return }
    }

    func waitUntilInstalled() async {
        for await _ in installed.stream { return }
    }

    func release() { resumed.continuation.yield(()) }
}

private final class MigrationInstallationGate: @unchecked Sendable {
    private let entered: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let semaphore = DispatchSemaphore(value: 0)

    init() {
        let stream = AsyncStream<Void>.makeStream()
        entered = stream.stream
        continuation = stream.continuation
    }

    func pause() {
        continuation.yield(())
        #expect(semaphore.wait(timeout: .now() + 10) == .success)
    }

    func waitUntilInstalling() async {
        for await _ in entered { return }
    }

    func release() { semaphore.signal() }
}

private final class GatedMigrationStorage: TokenStorage, @unchecked Sendable {
    let storage: InMemorySessionStore
    let gate: MigrationInstallationGate

    init(storage: InMemorySessionStore, gate: MigrationInstallationGate) {
        self.storage = storage
        self.gate = gate
    }

    func get(_ key: String) -> String? { storage.get(key) }
    func remove(_ key: String) -> Bool { storage.remove(key) }
    func set(_ key: String, value: String) -> Bool {
        if key == "st-storage-item-st-access-token" { gate.pause() }
        return storage.set(key, value: value)
    }
}

private final class InterceptionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func increment() { lock.lock(); defer { lock.unlock() }; value += 1 }
}

private final class MigrationHTTPServer: @unchecked Sendable {
    struct Request: @unchecked Sendable {
        let raw: String
        let connection: NWConnection

        func respond(headers: [String: String]) {
            let body = #"{"status":"OK"}"#
            let fields = headers.map { "\($0.key): \($0.value)\r\n" }.joined()
            let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\(fields)Connection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "io.rownd.tests.migration-server")
    private let requests: AsyncStream<Request>
    private let continuation: AsyncStream<Request>.Continuation
    private(set) var baseURL = ""

    private init(listener: NWListener) {
        self.listener = listener
        var continuation: AsyncStream<Request>.Continuation!
        requests = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    static func start() async throws -> MigrationHTTPServer {
        let listener = try NWListener(using: .tcp, on: .any)
        let server = MigrationHTTPServer(listener: listener)
        listener.newConnectionHandler = { connection in
            connection.start(queue: server.queue)
            server.receive(connection, buffer: Data())
        }
        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    server.baseURL = "http://127.0.0.1:\(listener.port!.rawValue)"
                    continuation.resume(returning: server)
                case .failed(let error):
                    resumed = true
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: server.queue)
        }
    }

    func nextRequest() async throws -> Request {
        try await withThrowingTaskGroup(of: Request.self) { group in
            group.addTask { [requests] in
                for await request in requests { return request }
                throw RowndError("Migration server stopped")
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 3_000_000_000)
                throw RowndError("Timed out waiting for migration request")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    func stop() { listener.cancel(); continuation.finish() }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
            guard error == nil else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            let raw = String(data: buffer, encoding: .utf8) ?? ""
            guard raw.contains("\r\n\r\n") else {
                if !complete { self.receive(connection, buffer: buffer) }
                return
            }
            self.continuation.yield(Request(raw: raw, connection: connection))
        }
    }
}
