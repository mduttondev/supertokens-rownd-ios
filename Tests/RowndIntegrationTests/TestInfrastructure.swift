import Foundation
import Testing
@testable import SuperTokensIOS

@testable import Rownd

struct TestInfrastructure {
    private static let sessionStorage = InMemorySuperTokensSessionStorage()

    static let backendURL = URL(
        string: ProcessInfo.processInfo.environment["TEST_BACKEND_URL"] ?? "http://127.0.0.1:3100"
    )!
    static let supertokensConfig = RowndSuperTokensConfig(
        appName: "Rownd iOS Integration Tests",
        apiDomain: backendURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
        apiBasePath: "/auth"
    )

    static func prepare() async throws {
        try await waitForBackend()
        try await waitForHub()
        try await drainProfileOperations()
        try await resetBackend()

        Rownd.config.supertokens = supertokensConfig
        _ = try Rownd.initializeSuperTokensIfNeeded()
        SDKStorage.setTokenStorageForTests(sessionStorage)
        SuperTokensSessionBridge.storageOverride = sessionStorage
        _ = SDKStorage.clearSessionStorage()

        if await SuperTokensSessionBridge.doesSessionExist() {
            await SuperTokensSessionBridge.signOut()
        }
        SuperTokensSessionBridge.clearLocalSessionArtifacts()
    }

    static func waitForBackend(timeout: TimeInterval = 30) async throws {
        try await waitForHealth(url: backendURL.appendingPathComponent("health"), timeout: timeout)
    }

    static func waitForHub(timeout: TimeInterval = 30) async throws {
        let configURL = backendURL.appendingPathComponent("config")
        let (data, response) = try await URLSession.shared.data(from: configURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw RowndError("Failed to load the integration harness config")
        }

        let config = try JSONDecoder().decode(HarnessConfig.self, from: data)
        guard let hubURL = URL(string: config.hubHealthUrl) else {
            throw RowndError("The integration harness returned an invalid Hub health URL")
        }
        try await waitForHealth(url: hubURL, timeout: timeout)
    }

    static func waitForHealth(url: URL, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if let (_, response) = try? await URLSession.shared.data(from: url),
                (response as? HTTPURLResponse)?.statusCode == 200
            {
                return
            }

            try await Task.sleep(nanoseconds: 300_000_000)
        }

        throw RowndError("Timed out waiting for \(url.absoluteString)")
    }

    static func resetBackend() async throws {
        var request = URLRequest(url: backendURL.appendingPathComponent("reset"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)

        let (_, response) = try await URLSession.shared.data(for: request)
        let statusCode = try #require((response as? HTTPURLResponse)?.statusCode)
        try #require(statusCode == 200)
    }

    static func drainProfileOperations() async throws {
        var request = URLRequest(url: backendURL.appendingPathComponent("test/drain-profile-operations"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        let (_, response) = try await URLSession.shared.data(for: request)
        try #require((response as? HTTPURLResponse)?.statusCode == 200)
        // The backend can finish before the SDK applies the response to its shared store.
        // Also wait here after a failed test, before clearing counters or session storage.
        try await waitForUserLoadingToFinish()
    }

    static func waitForUserLoadingToFinish() async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while ProcessInfo.processInfo.systemUptime < deadline {
            if await MainActor.run(body: { !Context.currentContext.store.state.user.isLoading }) {
                return
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw RowndError("Timed out draining SDK profile operations; user.isLoading remains true; reset refused")
    }

}

private struct HarnessConfig: Decodable {
    let hubHealthUrl: String
}

private final class InMemorySuperTokensSessionStorage: TokenStorage, SuperTokensSessionStorage {
    private var values: [String: String] = [:]

    func get(_ name: String) -> String? {
        values[name]
    }

    func set(_ name: String, value: String) -> Bool {
        values[name] = value
        return true
    }

    func remove(_ key: String) -> Bool {
        values.removeValue(forKey: key)
        return true
    }

}
