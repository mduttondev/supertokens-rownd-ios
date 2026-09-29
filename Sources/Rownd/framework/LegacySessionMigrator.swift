import Foundation
import JWTDecode

struct LegacyTokenRefreshHTTPError: Error {
    let statusCode: Int
}

struct LegacyMigrationRequestPreparationError: Error {
    let underlyingError: Error
}

enum LegacySessionMigrationResult: Equatable {
    case migrated(SuperTokensSessionTokens)
    case sessionAlreadyExists
}

struct LegacySessionMigrationClient {
    private static let isolatedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        // Response headers must not mutate native auth before the migration owner is revalidated.
        configuration.protocolClasses = []
        return URLSession(configuration: configuration)
    }()
    private let apiDomainOverride: String?
    private let apiBasePathOverride: String?
    private let legacyApiDomain: String
    private let session: URLSession
    private let refreshLegacyTokenHandler: ((String) async throws -> TokenResponse)?
    private let migrateHandler: ((String) async throws -> LegacySessionMigrationResult)?

    init(
        apiDomain: String? = nil,
        apiBasePath: String? = nil,
        legacyApiDomain: String = "https://api.rownd.io",
        session: URLSession? = nil,
        refreshLegacyTokenHandler: ((String) async throws -> TokenResponse)? = nil,
        migrateHandler: ((String) async throws -> LegacySessionMigrationResult)? = nil
    ) {
        self.apiDomainOverride = apiDomain
        self.apiBasePathOverride = apiBasePath
        self.legacyApiDomain = legacyApiDomain
        self.session = session ?? Self.isolatedSession
        self.refreshLegacyTokenHandler = refreshLegacyTokenHandler
        self.migrateHandler = migrateHandler
    }

    func refreshLegacyToken(refreshToken: String) async throws -> TokenResponse {
        if let refreshLegacyTokenHandler {
            return try await refreshLegacyTokenHandler(refreshToken)
        }

        guard var components = URLComponents(string: legacyApiDomain) else {
            throw RowndError("Invalid legacy Rownd API domain")
        }

        components.path = "/hub/auth/token"
        guard let url = components.url else {
            throw RowndError("Invalid legacy Rownd token refresh URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            TokenRequest(
                refreshToken: refreshToken,
                idToken: nil,
                appId: nil,
                intent: nil,
                intentMismatchBehavior: nil,
                userData: nil,
                instantUserId: nil
            )
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RowndError("Legacy Rownd token refresh returned a non-HTTP response")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw LegacyTokenRefreshHTTPError(statusCode: httpResponse.statusCode)
        }

        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    func migrate(legacyAccessToken: String) async throws -> LegacySessionMigrationResult {
        if let migrateHandler {
            return try await migrateHandler(legacyAccessToken)
        }

        let request: URLRequest
        do {
            request = try migrationRequest(legacyAccessToken: legacyAccessToken)
        } catch {
            throw LegacyMigrationRequestPreparationError(underlyingError: error)
        }

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RowndError("Rownd migration returned a non-HTTP response")
        }

        switch httpResponse.statusCode {
        case 200..<300:
            guard let accessToken = httpResponse.headerValue(named: "st-access-token"), !accessToken.isEmpty else {
                throw RowndError("Rownd migration response did not include st-access-token")
            }
            guard let refreshToken = httpResponse.headerValue(named: "st-refresh-token"), !refreshToken.isEmpty else {
                throw RowndError("Rownd migration response did not include st-refresh-token")
            }
            guard let frontToken = httpResponse.headerValue(named: "front-token"), !frontToken.isEmpty else {
                throw RowndError("Rownd migration response did not include front-token")
            }

            return .migrated(
                SuperTokensSessionTokens(
                    accessToken: accessToken,
                    refreshToken: refreshToken,
                    frontToken: frontToken,
                    antiCSRF: httpResponse.headerValue(named: "anti-csrf")
                )
            )
        case 409:
            return .sessionAlreadyExists
        default:
            throw RowndError("Rownd migration failed with status code \(httpResponse.statusCode)")
        }
    }

    private func migrationRequest(legacyAccessToken: String) throws -> URLRequest {
        let supertokens = try Rownd.requireSuperTokensConfig()
        let apiDomain = apiDomainOverride ?? supertokens.apiDomain
        let apiBasePath = apiBasePathOverride ?? supertokens.apiBasePath

        guard var components = URLComponents(string: apiDomain) else {
            throw RowndError("Invalid SuperTokens apiDomain")
        }
        components.path = apiBasePath + "/plugin/rownd/migrate"
        guard let url = components.url else {
            throw RowndError("Invalid Rownd migration URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(legacyAccessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("session", forHTTPHeaderField: "rid")
        request.setValue("1.18", forHTTPHeaderField: "fdi-version")
        request.setValue("header", forHTTPHeaderField: "st-auth-mode")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        return request
    }
}

struct LegacySessionMigrationDependencies {
    var doesSuperTokensSessionExist: () async -> Bool = SuperTokensSessionBridge.doesSessionExist
    var bootstrapSession: (SuperTokensSessionTokens, LegacyMigrationAttempt) async -> Bool = { tokens, attempt in
        guard await attempt.isCurrent else { return false }
        guard await SuperTokensSessionBridge.adoptResponseSession(
            tokens, permit: attempt.permit, scope: attempt.adoptionScope,
            allowReplacingExistingSession: false
        ) != nil else { return false }
        guard await attempt.isCurrent else {
            await attempt.discardAdoption()
            return false
        }
        return true
    }
    var syncRowndAuthStateFromSuperTokens: (@escaping @MainActor () -> Bool) async -> Bool = { condition in
        await SuperTokensSessionBridge.syncRowndAuthStateFromSuperTokens(afterTokenRead: {}, commitIf: condition)
    }
    var signOut: (LegacyMigrationAttempt) async -> Void = { attempt in
        await Rownd.signOutForMigrationFailure(attempt: attempt)
    }
    var client: LegacySessionMigrationClient = LegacySessionMigrationClient()
}

enum LegacySessionMigrator {
    @MainActor private static let coordinator = LegacySessionMigrationCoordinator()

    static func migrateIfNeeded(
        authState: AuthState,
        dependencies: LegacySessionMigrationDependencies = LegacySessionMigrationDependencies()
    ) async {
        let attempt = await MainActor.run { LegacyMigrationAttempt(auth: authState) }
        await coordinator.run(key: attempt) {
            await performMigrationIfNeeded(attempt: attempt, dependencies: dependencies)
        }
    }

    private static func performMigrationIfNeeded(
        attempt initialAttempt: LegacyMigrationAttempt,
        dependencies: LegacySessionMigrationDependencies
    ) async {
        var attempt = initialAttempt
        guard await attempt.isCurrent, !Task.isCancelled else { return }
        if await syncExistingSession(dependencies, attempt: attempt) { return }
        guard let accessToken = attempt.auth.accessToken, !accessToken.isEmpty,
              !isSuperTokensAccessToken(accessToken) else { return }

        guard await updateAttempt(attempt, update: { $0.isLoading = true }) else { return }

        if !isAccessTokenValid(accessToken) {
            guard let refreshToken = attempt.auth.refreshToken, !refreshToken.isEmpty else {
                await finishInvalidSession(attempt, dependencies: dependencies)
                return
            }

            do {
                let refreshed = try await dependencies.client.refreshLegacyToken(refreshToken: refreshToken)
                guard let refreshedAccessToken = refreshed.accessToken, !refreshedAccessToken.isEmpty else {
                    throw RowndError("Legacy refresh response did not include an access token")
                }
                guard await attempt.isCurrent, !Task.isCancelled else { return }
                if await syncExistingSession(dependencies, attempt: attempt) { return }
                let refreshedRefreshToken = refreshed.refreshToken ?? attempt.auth.refreshToken
                let didUpdate = await updateAttempt(attempt) {
                    $0.accessToken = refreshedAccessToken
                    $0.refreshToken = refreshedRefreshToken
                }
                guard didUpdate else { return }
                let previousAttempt = attempt
                attempt.auth.accessToken = refreshedAccessToken
                attempt.auth.refreshToken = refreshedRefreshToken
                await coordinator.updateKey(from: previousAttempt, to: attempt)
            } catch {
                logger.warning("Failed to refresh legacy Rownd session before migration: \(String(describing: error))")
                await finishInvalidSession(attempt, dependencies: dependencies)
                return
            }
        }

        do {
            let result = try await migrateWithRetry(
                legacyAccessToken: attempt.auth.accessToken!, client: dependencies.client,
                shouldRetry: { [attempt] in await attempt.isCurrent }
            )
            guard await attempt.isCurrent, !Task.isCancelled else { return }
            if await syncExistingSession(dependencies, attempt: attempt) { return }
            guard await attempt.isCurrent, !Task.isCancelled else { return }

            switch result {
            case .migrated(let tokens):
                guard await dependencies.bootstrapSession(tokens, attempt) else {
                    logger.warning("Could not adopt the Rownd migration response as a native session")
                    await finishInvalidSession(attempt, dependencies: dependencies)
                    return
                }
                guard await attempt.isCurrent, !Task.isCancelled else {
                    await attempt.discardAdoption()
                    return
                }
                let completedAttempt = attempt
                if !(await dependencies.syncRowndAuthStateFromSuperTokens({ completedAttempt.isCurrent })) {
                    guard await attempt.isCurrent, !Task.isCancelled else {
                        await attempt.discardAdoption()
                        return
                    }
                    await finishInvalidSession(attempt, dependencies: dependencies)
                }
            case .sessionAlreadyExists:
                // A conflict is only success when a usable native session can be synchronized.
                logger.warning("Rownd migration returned HTTP 409 without a usable native session")
                await finishInvalidSession(attempt, dependencies: dependencies)
            }
        } catch let error as LegacyMigrationRequestPreparationError {
            logger.warning("Could not prepare the Rownd migration request: \(String(describing: error.underlyingError))")
            await finishPreRequestFailure(attempt, dependencies: dependencies)
        } catch {
            logger.warning("Failed to migrate legacy Rownd session: \(String(describing: error))")
            await finishInvalidSession(attempt, dependencies: dependencies)
        }
    }

    @discardableResult
    @MainActor private static func updateAttempt(
        _ attempt: LegacyMigrationAttempt,
        update: (inout AuthState) -> Void
    ) -> Bool {
        guard !Task.isCancelled, attempt.isCurrent,
              !AuthState.isSuperTokensAccessToken(attempt.auth.accessToken) else { return false }
        let store = attempt.context.store
        var current = store.state.auth
        update(&current)
        store.dispatch(SetAuthState(payload: current))
        store.state.saveImmediately()
        return true
    }

    private static func syncExistingSession(
        _ dependencies: LegacySessionMigrationDependencies, attempt: LegacyMigrationAttempt
    ) async -> Bool {
        guard !Task.isCancelled, await attempt.isCurrent else { return true }
        guard await dependencies.doesSuperTokensSessionExist() else { return false }
        guard !Task.isCancelled, await attempt.isCurrent else { return true }
        if !(await dependencies.syncRowndAuthStateFromSuperTokens({ attempt.isCurrent })) {
            await updateAttempt(attempt) {
                $0.isLoading = false
            }
        }
        return true
    }

    private static func finishPreRequestFailure(
        _ attempt: LegacyMigrationAttempt, dependencies: LegacySessionMigrationDependencies
    ) async {
        if await syncExistingSession(dependencies, attempt: attempt) { return }
        await updateAttempt(attempt) {
            $0.isLoading = false
        }
    }

    private static func finishInvalidSession(
        _ attempt: LegacyMigrationAttempt, dependencies: LegacySessionMigrationDependencies
    ) async {
        if await syncExistingSession(dependencies, attempt: attempt) { return }
        guard await attempt.isCurrent, !Task.isCancelled else { return }
        await dependencies.signOut(attempt)
    }

    private static func migrateWithRetry(
        legacyAccessToken: String,
        client: LegacySessionMigrationClient,
        shouldRetry: () async -> Bool
    ) async throws -> LegacySessionMigrationResult {
        guard !Task.isCancelled, await shouldRetry() else { throw CancellationError() }
        do {
            return try await client.migrate(legacyAccessToken: legacyAccessToken)
        } catch {
            guard error is URLError, !Task.isCancelled, await shouldRetry() else {
                throw error
            }
            return try await client.migrate(legacyAccessToken: legacyAccessToken)
        }
    }

    private static func isAccessTokenValid(_ accessToken: String) -> Bool {
        guard let jwt = try? decode(jwt: accessToken), let expiresAt = jwt.expiresAt else {
            return false
        }

        guard let currentDateWithMargin = Calendar.current.date(byAdding: .second, value: 60, to: Date()) else {
            return false
        }

        return currentDateWithMargin < expiresAt
    }

    private static func isSuperTokensAccessToken(_ accessToken: String) -> Bool {
        guard let jwt = try? decode(jwt: accessToken) else { return false }

        return jwt.claim(name: "sessionHandle").string != nil
            || jwt.claim(name: "tId").string != nil
    }
}

@MainActor private final class LegacySessionMigrationCoordinator {
    private final class Flight {
        let id = UUID()
        var key: LegacyMigrationAttempt
        var task: Task<Void, Never>?
        var adoptionCleanup: Task<Void, Never>?
        var waiters: [CheckedContinuation<Void, Never>] = []

        init(key: LegacyMigrationAttempt) { self.key = key }
    }

    private var flight: Flight?

    func run(key: LegacyMigrationAttempt, _ operation: @escaping () async -> Void) async {
        guard key.isCurrent else { return }
        if flight?.key != key {
            let retired = retire()
            let next = Flight(key: key)
            flight = next
            if let retired {
                next.adoptionCleanup = Task {
                    // A later successor must also wait for earlier native adoption cleanup.
                    await retired.adoptionCleanup?.value
                    await SuperTokensSessionBridge.discardSession(in: retired.key.adoptionScope)
                }
            }
            next.task = Task {
                // Drain only a superseded native adoption, never its pending network request.
                // B must not observe A between installation and A's ownership recheck.
                await next.adoptionCleanup?.value
                await operation()
                finish(id: next.id)
            }
        }
        await withCheckedContinuation { flight?.waiters.append($0) }
    }

    func updateKey(from old: LegacyMigrationAttempt, to new: LegacyMigrationAttempt) {
        guard flight?.key == old, new.isCurrent else { return }
        flight?.key = new
    }

    private func retire() -> Flight? {
        guard let retired = flight else { return nil }
        flight = nil
        retired.key.adoptionScope.invalidate()
        retired.task?.cancel()
        retired.waiters.forEach { $0.resume() }
        retired.waiters.removeAll()
        return retired
    }

    private func finish(id: UUID) {
        guard let completed = flight, completed.id == id else { return }
        flight = nil
        completed.waiters.forEach { $0.resume() }
        completed.waiters.removeAll()
    }
}
