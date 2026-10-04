//
//  AppDelegate.swift
//  ios native
//
//  Created by Matt Hamann on 6/23/22.
//

import Foundation
import SwiftUI
import Rownd
import Lottie
import WidgetKit
import AnyCodable
import WebKit

struct E2EHarnessConfig: Decodable {
    struct SuperTokens: Decodable {
        struct AppInfo: Decodable {
            let apiDomain: String
            let apiBasePath: String
        }

        let appInfo: AppInfo
    }

    let apiUrl: String
    let appKey: String
    let hubBaseUrl: String
    let supertokens: SuperTokens
}

@MainActor
final class E2EReadiness: ObservableObject {
    enum OnboardingState: String {
        case idle
        case started
        case advanced
    }

    static let shared = E2EReadiness()

    @Published private(set) var isReady = false
    @Published private(set) var signInCompletedCount = 0
    @Published private(set) var onboardingState = OnboardingState.idle
    @Published private(set) var userType = "not-recorded"
    @Published private(set) var appVariantUserType = "not-recorded"
    @Published private(set) var hadPresentedControllerAtOnboardingStart: Bool?

    private init() {}

    func markReady() {
        isReady = true
    }

    func record(_ event: RowndEvent, hadPresentedControllerAtReceipt: Bool) {
        if event.event == .signInCompleted {
            signInCompletedCount += 1
            userType = event.data?["user_type"]??.value as? String ?? "missing"
            appVariantUserType = event.data?["app_variant_user_type"]??.value as? String ?? "missing"
            hadPresentedControllerAtOnboardingStart = hadPresentedControllerAtReceipt
            onboardingState = .started
        }
    }

    func advanceOnboarding() {
        guard onboardingState == .started else { return }
        onboardingState = .advanced
    }
}

final class E2EEventRecorder: RowndEventHandlerDelegate {
    static let shared = E2EEventRecorder()

    private init() {}

    func handleRowndEvent(_ event: RowndEvent) {
        let hadPresentedController = Self.capturePresentedControllerState()
        Task { @MainActor in
            E2EReadiness.shared.record(
                event,
                hadPresentedControllerAtReceipt: hadPresentedController
            )
        }
    }

    private static func capturePresentedControllerState() -> Bool {
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                hasPresentedController()
            }
        }

        return DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                hasPresentedController()
            }
        }
    }

    @MainActor private static func hasPresentedController() -> Bool {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .contains { $0.rootViewController?.presentedViewController != nil }
    }
}

enum E2ESupport {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["ROWND_E2E"] == "1"
    }

    static var configURL: URL {
        URL(string: ProcessInfo.processInfo.environment["ROWND_E2E_CONFIG_URL"] ?? "http://127.0.0.1:3100/config")!
    }

    static var apiURL: URL? {
        guard let url = UserDefaults.standard.string(forKey: "ROWND_E2E_API_URL") else { return nil }
        return URL(string: url)
    }

    static func loadConfig() async throws -> E2EHarnessConfig {
        let (data, _) = try await URLSession.shared.data(from: configURL)
        return try JSONDecoder().decode(E2EHarnessConfig.self, from: data)
    }

    static func sessionHandle(from accessToken: String?) -> String? {
        accessTokenClaims(from: accessToken)?["sessionHandle"] as? String
    }

    static func accessTokenExpiresAt(from accessToken: String?) -> Double? {
        accessTokenClaims(from: accessToken)?["exp"] as? Double
    }

    private static func accessTokenClaims(from accessToken: String?) -> [String: Any]? {
        guard let accessToken else { return nil }
        let parts = accessToken.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    static func configureRownd(launchOptions: [UIApplication.LaunchOptionsKey: Any]?) async {
        do {
            let shouldResetSession = ProcessInfo.processInfo.environment["ROWND_E2E_RESET_SESSION"] == "1"
            if shouldResetSession {
                await clearWebsiteData()
            }

            let config = try await loadConfig()
            UserDefaults.standard.set(config.apiUrl, forKey: "ROWND_E2E_API_URL")

            Rownd.config.baseUrl = config.hubBaseUrl
            Rownd.config.subdomainExtension = ExampleAppConfig.subdomainExtension
            Rownd.config.appGroupPrefix = ExampleAppConfig.appGroupPrefix
            Rownd.config.enableDebugMode = ExampleAppConfig.enableDebugMode
            Rownd.config.enableSmartLinkPasteBehavior = false
            Rownd.config.customizations = AppCustomizations()
            Rownd.config.customizations.loadingAnimation = LottieAnimation.named("loading")
            Rownd.addEventHandler(RowndEventHandler())
            Rownd.addEventHandler(E2EEventRecorder.shared)
            try removeInstallationMarkersIfRequested()
            try seedLegacyAuthStateIfRequested()

            let clearSessionOnNewInstallation = ProcessInfo.processInfo.environment[
                "ROWND_E2E_CLEAR_SESSION_ON_NEW_INSTALLATION"
            ] == "1"

            await Rownd.configure(
                launchOptions: launchOptions,
                appKey: config.appKey,
                supertokens: RowndSuperTokensConfig(
                    appName: "Rownd iOS E2E",
                    apiDomain: config.supertokens.appInfo.apiDomain,
                    apiBasePath: config.supertokens.appInfo.apiBasePath,
                    clearSessionOnNewInstallation: clearSessionOnNewInstallation
                )
            )

            if shouldResetSession {
                await resetSessionAfterStartup()
            }

            if let deepLink = ProcessInfo.processInfo.environment["ROWND_E2E_DEEP_LINK"] {
                guard let deepLinkURL = URL(string: deepLink),
                      Rownd.handleSmartLink(url: deepLinkURL) else {
                    throw E2EError.invalidDeepLink
                }
            }

            await E2EReadiness.shared.markReady()
        } catch {
            fatalError("Failed to configure Rownd E2E harness: \(error)")
        }
    }

    @MainActor
    private static func clearWebsiteData() async {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                modifiedSince: .distantPast
            ) {
                continuation.resume()
            }
        }
    }

    private static func resetSessionAfterStartup() async {
        await Rownd.signOut()
        // An authenticated startup can still have a profile request in flight.
        try? await Task.sleep(nanoseconds: 500_000_000)
        await Rownd.signOut()
    }

    static func resetHarness() async throws {
        guard let apiURL = apiURL else { return }
        var request = URLRequest(url: apiURL.appendingPathComponent("reset"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        try requireOK(data: data, response: response)
    }

    static func createSession() async throws {
        guard let apiURL = apiURL else { throw E2EError.missingApiURL }
        let environment = ProcessInfo.processInfo.environment
        let email = environment["ROWND_E2E_EMAIL"] ?? "ios-e2e-user@example.com"
        let firstName = environment["ROWND_E2E_FIRST_NAME"] ?? "Existing"
        let expiringSession = environment["ROWND_E2E_EXPIRING_SESSION"] == "1"
        let path = expiringSession ? "test/expiring-session" : "test/profile-session"
        var request = URLRequest(url: apiURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("header", forHTTPHeaderField: "st-auth-mode")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "email": email,
            "firstName": firstName,
            "accessTokenValidity": 90
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        try requireOK(data: data, response: response)
        _ = try await Rownd.getAccessToken(throwIfMissing: true)
    }

    static func updateProfile() async throws {
        guard let apiURL = apiURL else { throw E2EError.missingApiURL }
        var request = URLRequest(url: apiURL.appendingPathComponent("auth/plugin/rownd/user"))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "data": [
                "first_name": "E2E"
            ]
        ])

        _ = try await URLSession.shared.data(for: request)
        Rownd.user.set(data: [
            "first_name": AnyCodable("E2E")
        ])
    }

    private static func requireOK(data: Data, response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode),
              let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              payload["status"] as? String == "OK" else {
            throw E2EError.unexpectedResponse
        }
    }

    private static func seedLegacyAuthStateIfRequested() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let accessToken = environment["ROWND_E2E_LEGACY_ACCESS_TOKEN"],
              let refreshToken = environment["ROWND_E2E_LEGACY_REFRESH_TOKEN"] else {
            return
        }

        var didSeed = false
        for url in stateStorageURLs() where FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            try seededStateData(data, accessToken: accessToken, refreshToken: refreshToken)
                .write(to: url, options: .atomic)
            didSeed = true
        }

        if let defaults = UserDefaults(suiteName: "io.rownd.sdk"),
           let state = defaults.string(forKey: "RowndState"),
           let data = state.data(using: .utf8) {
            let seeded = try seededStateData(data, accessToken: accessToken, refreshToken: refreshToken)
            defaults.set(String(decoding: seeded, as: UTF8.self), forKey: "RowndState")
            didSeed = true
        }

        guard didSeed else { throw E2EError.missingPersistedState }
    }

    private static func removeInstallationMarkersIfRequested() throws {
        guard ProcessInfo.processInfo.environment["ROWND_E2E_SIMULATE_NEW_INSTALLATION"] == "1" else {
            return
        }

        for directory in Set(stateStorageURLs().map { $0.deletingLastPathComponent() }) {
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            for url in try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ) where url.lastPathComponent.hasPrefix("io.rownd.sdk.installation-marker.v1-") {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    private static func seededStateData(
        _ data: Data,
        accessToken: String,
        refreshToken: String
    ) throws -> Data {
        guard var state = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var auth = state["auth"] as? [String: Any] else {
            throw E2EError.invalidPersistedState
        }

        auth["access_token"] = accessToken
        auth["refresh_token"] = refreshToken
        auth["is_verified_user"] = true
        auth["has_previously_signed_in"] = true
        state["auth"] = auth
        return try JSONSerialization.data(withJSONObject: state)
    }

    private static func stateStorageURLs() -> [URL] {
        var urls: [URL] = []
        if let sharedURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "\(ExampleAppConfig.appGroupPrefix).io.rownd.sdk"
        ) {
            urls.append(sharedURL.appendingPathComponent("RowndState"))
        }
        if let applicationSupportURL = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) {
            urls.append(applicationSupportURL.appendingPathComponent("io.rownd.sdk/RowndState"))
        }
        return urls
    }
}

enum E2EError: Error {
    case invalidDeepLink
    case invalidPersistedState
    case missingApiURL
    case missingPersistedState
    case unexpectedResponse
}

struct E2EStatusView: View {
    @StateObject var state = Rownd.getInstance().state().subscribe { $0 }
    @StateObject private var readiness = E2EReadiness.shared

    var body: some View {
        if E2ESupport.isEnabled {
            VStack {
                Text(readiness.isReady ? "ready" : "loading")
                    .accessibilityIdentifier("e2e-sdk-state")
                Text(state.current.auth.isAuthenticated ? "authenticated" : "signed-out")
                    .accessibilityIdentifier("e2e-auth-state")
                Text(state.current.auth.isAccessTokenValid ? "valid" : "invalid")
                    .accessibilityIdentifier("e2e-access-token-validity")
                Text(E2ESupport.sessionHandle(from: state.current.auth.accessToken) ?? "no-session")
                    .accessibilityIdentifier("e2e-session-handle")
                    .accessibilityValue(String(E2ESupport.accessTokenExpiresAt(from: state.current.auth.accessToken) ?? 0))
                Text(cachedUserEmail)
                    .accessibilityIdentifier("e2e-cached-user-email")
                Text((state.current.user.data["user_id"]?.value as? String) ?? "no-user")
                    .accessibilityIdentifier("e2e-user-id")
                Text(state.current.auth.challengeId == nil ? "clear" : "active")
                    .accessibilityIdentifier("e2e-challenge-state")
                Text(String(readiness.signInCompletedCount))
                    .accessibilityIdentifier("e2e-sign-in-completed-count")
                Text(readiness.onboardingState.rawValue)
                    .accessibilityIdentifier("e2e-onboarding-state")
                Text(readiness.userType)
                    .accessibilityIdentifier("e2e-sign-in-user-type")
                Text(readiness.appVariantUserType)
                    .accessibilityIdentifier("e2e-sign-in-app-variant-user-type")
                Text(readiness.hadPresentedControllerAtOnboardingStart.map(String.init) ?? "not-recorded")
                    .accessibilityIdentifier("e2e-modal-at-onboarding-start")
            }
        }
    }

    private var cachedUserEmail: String {
        let email: String? = Rownd.user.get(field: "email")
        return email ?? "no-email"
    }
}

class AppCustomizations: RowndCustomizations {
//    override var sheetBackgroundColor: UIColor {
//        return UIColor(red: 225/255, green: 225/255, blue: 225/255, alpha: 1.0)
//    }
}

class AppDelegate: NSObject, UIApplicationDelegate {

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {

        if E2ESupport.isEnabled {
            Task {
                await E2ESupport.configureRownd(launchOptions: launchOptions)
                WidgetCenter.shared.reloadAllTimelines()
            }

            return true
        }

        Rownd.config.baseUrl = ExampleAppConfig.hubBaseUrl
        Rownd.config.subdomainExtension = ExampleAppConfig.subdomainExtension
        Rownd.config.appGroupPrefix = ExampleAppConfig.appGroupPrefix
        Rownd.config.enableDebugMode = ExampleAppConfig.enableDebugMode

        Rownd.config.customizations = AppCustomizations()
//        Rownd.config.customizations.loadingAnimationUiView = CustomLoadingAnimationView()
        Rownd.config.customizations.loadingAnimation = LottieAnimation.named("loading")

        Rownd.addEventHandler(RowndEventHandler())

        Task {
            await Rownd.configure(
                launchOptions: launchOptions,
                appKey: ExampleAppConfig.appKey,
                supertokens: RowndSuperTokensConfig(
                    appName: "Rownd iOS All Authentication Methods",
                    apiDomain: ExampleAppConfig.apiDomain,
                    apiBasePath: ExampleAppConfig.apiBasePath
                )
            )
            _ = try? await Rownd.getAccessToken()
            WidgetCenter.shared.reloadAllTimelines()
        }

        return true
    }

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        return Rownd.handleSmartLink(url: url)
    }

    func application(_ application: UIApplication,
                     continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
        // Get URL components from the incoming user activity.
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
              let incomingURL = userActivity.webpageURL,
              let components = NSURLComponents(url: incomingURL, resolvingAgainstBaseURL: true) else {
            return false
        }

        return Rownd.handleSignInLink(url: incomingURL)
    }

    func scene(_ scene: UIScene, willConnectTo
               session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {

        // Get URL components from the incoming user activity.
        guard let userActivity = connectionOptions.userActivities.first,
              userActivity.activityType == NSUserActivityTypeBrowsingWeb,
              let incomingURL = userActivity.webpageURL,
              let components = NSURLComponents(url: incomingURL, resolvingAgainstBaseURL: true) else {
            return
        }

        Rownd.handleSignInLink(url: incomingURL)
    }
}
