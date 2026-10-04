import Foundation
import XCTest

@MainActor
final class RowndRealHubAuthenticationUITests: XCTestCase {
    private let backendURL = URL(
        string: ProcessInfo.processInfo.environment["TEST_BACKEND_URL"] ?? "http://127.0.0.1:3100"
    )!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testEmailOTPFromRealHubEstablishesUsableNativeSessionAndCompletesOnce() async throws {
        let app = try await launchIsolatedApp(resetSession: true)
        let email = uniqueEmail(prefix: "ios-real-hub-otp")

        try startEmailSignIn(email, in: app)
        let capture = try await waitForPasswordlessCapture(email: email)
        let code = try XCTUnwrap(capture["userInputCode"] as? String)

        completeEmailOTP(code, in: app)

        try waitForLabel(app.staticTexts["e2e-auth-state"], equalTo: "authenticated")
        try waitForLabel(app.staticTexts["e2e-challenge-state"], equalTo: "clear")
        try waitForLabel(app.staticTexts["e2e-sign-in-completed-count"], equalTo: "1")
        XCTAssertNotEqual(app.staticTexts["e2e-session-handle"].label, "no-session")

        let protectedButton = app.buttons["e2e-protected-button"]
        try scrollToElement(protectedButton, in: app)
        protectedButton.tap()
        try waitForLabel(app.staticTexts["e2e-scenario-state"], equalTo: "protected_loaded")
        let counters = try await waitForCounters { ($0["protected"] as? Int) == 1 }
        XCTAssertEqual(counters["passwordlessConsume"] as? Int, 1)
    }

    func testExistingPasswordlessUserExplicitSignUpStartsTappableOnboardingAfterHubDismissal() async throws {
        let app = try await launchIsolatedApp(resetSession: true)
        let email = uniqueEmail(prefix: "ios-existing-sign-up")
        let fixture = try await request(
            "POST",
            path: "test/existing-passwordless-user",
            jsonBody: ["email": email]
        )
        let fixtureUserId = try XCTUnwrap(fixture["userId"] as? String)
        XCTAssertEqual(fixture["status"] as? String, "OK")
        XCTAssertEqual(fixture["email"] as? String, email)
        XCTAssertEqual(fixture["sessionHandleCount"] as? Int, 0)

        try startEmailFlow(email, buttonIdentifier: "e2e-sign-up-email-button", in: app)
        let capture = try await waitForPasswordlessCapture(email: email)
        completeEmailOTP(try XCTUnwrap(capture["userInputCode"] as? String), in: app)

        try waitForLabel(app.staticTexts["e2e-auth-state"], equalTo: "authenticated")
        try waitForLabel(app.staticTexts["e2e-user-id"], equalTo: fixtureUserId)
        try waitForLabel(app.staticTexts["e2e-sign-in-completed-count"], equalTo: "1")
        try waitForLabel(app.staticTexts["e2e-onboarding-state"], equalTo: "started")
        try waitForLabel(app.staticTexts["e2e-sign-in-user-type"], equalTo: "existing_user")
        try waitForLabel(app.staticTexts["e2e-sign-in-app-variant-user-type"], equalTo: "existing_user")
        XCTAssertEqual(app.staticTexts["e2e-modal-at-onboarding-start"].label, "false")
        try waitForDisappearance(app.webViews.firstMatch)

        let onboardingButton = app.buttons["e2e-onboarding-continue-button"]
        try scrollToElement(onboardingButton, in: app)
        XCTAssertTrue(onboardingButton.isHittable)
        onboardingButton.tap()
        try waitForLabel(app.staticTexts["e2e-onboarding-state"], equalTo: "advanced")
    }

    func testMagicLinkCompletesThroughCustomSchemeAndReplayDoesNotReplaceSession() async throws {
        guard #available(iOS 16.4, *) else {
            throw XCTSkip("System custom-scheme dispatch requires iOS 16.4 or newer")
        }

        let app = try await launchIsolatedApp(resetSession: true)
        let email = uniqueEmail(prefix: "ios-real-hub-link")
        try startEmailSignIn(email, in: app)
        let capture = try await waitForPasswordlessCapture(email: email)
        let capturedLink = try XCTUnwrap(capture["urlWithLinkCode"] as? String)
        let deepLink = try customSchemeURL(from: capturedLink)
        let webView = app.webViews.firstMatch

        app.open(deepLink)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        try waitForLabel(app.staticTexts["e2e-auth-state"], equalTo: "authenticated")
        try waitForLabel(app.staticTexts["e2e-sign-in-completed-count"], equalTo: "1")
        try waitForDisappearance(webView)
        let sessionHandle = app.staticTexts["e2e-session-handle"].label
        XCTAssertNotEqual(sessionHandle, "no-session")
        _ = try await waitForConsumes(count: 1)

        let protectedButton = app.buttons["e2e-protected-button"]
        try scrollToElement(protectedButton, in: app)
        protectedButton.tap()
        try waitForLabel(app.staticTexts["e2e-scenario-state"], equalTo: "protected_loaded")
        let counters = try await waitForCounters { ($0["protected"] as? Int) == 1 }
        XCTAssertEqual(counters["protected"] as? Int, 1)

        app.open(deepLink)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        let replayObservation = try await request("GET", path: "test/passwordless/consumes/settled")
        XCTAssertEqual(replayObservation["count"] as? Int, 1)
        XCTAssertEqual(replayObservation["changedDuringObservation"] as? Bool, false)
        try waitForLabel(app.staticTexts["e2e-auth-state"], equalTo: "authenticated")
        try waitForLabel(app.staticTexts["e2e-session-handle"], equalTo: sessionHandle)
        try waitForLabel(app.staticTexts["e2e-sign-in-completed-count"], equalTo: "1")
        app.terminate()
    }

    func testNativeLogoutReopensRealHubWithoutStaleSessionRetryAndCanSignInAgain() async throws {
        try await assertNativeLogoutCanSignInAgain(reopenImmediately: false)
    }

    func testSignInRequestedImmediatelyAfterNativeLogoutWaitsForHubCleanup() async throws {
        try await assertNativeLogoutCanSignInAgain(reopenImmediately: true)
    }

    private func assertNativeLogoutCanSignInAgain(reopenImmediately: Bool) async throws {
        let app = try await launchIsolatedApp(resetSession: true)
        let email = uniqueEmail(prefix: "ios-logout-reopen")
        try startEmailSignIn(email, in: app)
        let coldHubCounters = try await request("GET", path: "counters")
        let coldHubRefreshCount = try XCTUnwrap(coldHubCounters["stRefresh"] as? Int)
        let firstCapture = try await waitForPasswordlessCapture(email: email)
        completeEmailOTP(try XCTUnwrap(firstCapture["userInputCode"] as? String), in: app)
        try waitForLabel(app.staticTexts["e2e-auth-state"], equalTo: "authenticated")
        try waitForLabel(app.staticTexts["e2e-sign-in-completed-count"], equalTo: "1")
        try waitForDisappearance(app.webViews.firstMatch)
        let originalSession = app.staticTexts["e2e-session-handle"].label
        let originalUser = app.staticTexts["e2e-user-id"].label
        XCTAssertNotEqual(originalSession, "no-session")

        let beforeLogout = try await request("GET", path: "counters")
        let signOutCount = try XCTUnwrap(beforeLogout["stSignOut"] as? Int)
        let logoutButton = app.buttons[reopenImmediately ? "e2e-sign-out-and-reopen-button" : "e2e-native-sign-out-button"]
        try scrollToElement(logoutButton, in: app)
        logoutButton.tap()
        try waitForLabel(app.staticTexts["e2e-auth-state"], equalTo: "signed-out")
        try waitForLabel(app.staticTexts["e2e-session-handle"], equalTo: "no-session")
        _ = try await waitForCounters { ($0["stSignOut"] as? Int ?? 0) > signOutCount }
        let beforeReopen = beforeLogout

        // Reconfiguring or relaunching here would mask logout's retained WebKit session.
        if !reopenImmediately {
            let getStartedButton = app.buttons["e2e-sign-in-account-button"]
            try scrollToElement(getStartedButton, in: app)
            getStartedButton.tap()
        }
        let webView = app.webViews.firstMatch
        let emailField = webView.textFields.firstMatch
        let emailFormAppeared = emailField.waitForExistence(timeout: 15)

        let settled = try await request("GET", path: "test/passwordless/consumes/settled")
        let afterReopen = try await request("GET", path: "counters")
        let authState = app.staticTexts["e2e-auth-state"].label
        let sessionHandle = app.staticTexts["e2e-session-handle"].label
        let completionCount = app.staticTexts["e2e-sign-in-completed-count"].label
        let diagnostics = XCTAttachment(string: "Before reopening: \(beforeReopen)\nAfter reopening: \(afterReopen)\nConsumes: \(settled)\nAuth: \(authState)\nSession: \(sessionHandle)\nOriginal session: \(originalSession)\nCompletions: \(completionCount)")
        diagnostics.name = "Native logout Hub reopen requests"
        diagnostics.lifetime = .keepAlways
        add(diagnostics)
        guard emailFormAppeared, authState == "signed-out", sessionHandle == "no-session", completionCount == "1" else {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Hub after native logout"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            XCTFail("Hub reopened with stale authentication: emailForm=\(emailFormAppeared), auth=\(authState), session=\(sessionHandle), completions=\(completionCount). Expected an email form, signed-out state, no session, and one prior completion.")
            return
        }
        for counter in ["stRefreshWithCredentials", "legacyRefresh", "migrate", "passwordlessConsume", "passwordlessCreate"] {
            XCTAssertEqual(
                try XCTUnwrap(afterReopen[counter] as? Int),
                try XCTUnwrap(beforeReopen[counter] as? Int),
                "Reopening Hub after native logout attempted \(counter) before user authentication"
            )
        }
        // A fresh WebView may probe for an HttpOnly session with a tokenless refresh.
        // Allow only the same number of probes as the isolated, signed-out startup.
        XCTAssertLessThanOrEqual(
            try XCTUnwrap(afterReopen["stRefresh"] as? Int) - XCTUnwrap(beforeReopen["stRefresh"] as? Int),
            coldHubRefreshCount
        )
        XCTAssertTrue(emailField.isHittable)
        emailField.tap()
        emailField.typeText(email)
        webView.buttons["Continue"].tap()
        try waitForLabel(app.staticTexts["e2e-challenge-state"], equalTo: "active")
        _ = try await waitForCounters { ($0["passwordlessCreate"] as? Int) == 2 }
        let secondCapture = try await waitForPasswordlessCapture(email: email)
        completeEmailOTP(try XCTUnwrap(secondCapture["userInputCode"] as? String), in: app)
        try waitForLabel(app.staticTexts["e2e-auth-state"], equalTo: "authenticated")
        try waitForLabel(app.staticTexts["e2e-challenge-state"], equalTo: "clear")
        try waitForLabel(app.staticTexts["e2e-sign-in-completed-count"], equalTo: "2")
        try waitForDisappearance(webView)
        XCTAssertEqual(app.staticTexts["e2e-user-id"].label, originalUser)
        XCTAssertNotEqual(app.staticTexts["e2e-session-handle"].label, originalSession)
        XCTAssertNotEqual(app.staticTexts["e2e-session-handle"].label, "no-session")

        let protectedButton = app.buttons["e2e-protected-button"]
        try scrollToElement(protectedButton, in: app)
        protectedButton.tap()
        try waitForLabel(app.staticTexts["e2e-scenario-state"], equalTo: "protected_loaded")
        XCTAssertEqual(try protectedResponse(in: app)["userId"] as? String, originalUser)
        let counters = try await request("GET", path: "counters")
        XCTAssertEqual(counters["passwordlessConsume"] as? Int, 2)
    }

    func testRestoredSessionCanSignOutFromRealManageAccountAndStaysSignedOut() async throws {
        let app = try await launchIsolatedApp(resetSession: true)
        let createSessionButton = app.buttons["e2e-create-session-button"]
        try scrollToElement(createSessionButton, in: app)
        createSessionButton.tap()
        try waitForLabel(app.staticTexts["e2e-auth-state"], equalTo: "authenticated")
        let sessionHandle = app.staticTexts["e2e-session-handle"].label
        XCTAssertNotEqual(sessionHandle, "no-session")

        app.terminate()
        app.launchEnvironment.removeValue(forKey: "ROWND_E2E_RESET_SESSION")
        app.launch()
        try waitForLabel(app.staticTexts["e2e-sdk-state"], equalTo: "ready")
        try waitForLabel(app.staticTexts["e2e-auth-state"], equalTo: "authenticated")
        XCTAssertEqual(app.staticTexts["e2e-session-handle"].label, sessionHandle)

        let manageAccountButton = app.buttons["e2e-manage-account-button"]
        try scrollToElement(manageAccountButton, in: app)
        manageAccountButton.tap()
        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.staticTexts["Your profile"].waitForExistence(timeout: 15))
        let signOutButton = webView.buttons["Sign out"].firstMatch
        XCTAssertTrue(signOutButton.waitForExistence(timeout: 10))
        let signOutCountBefore = (try await request("GET", path: "counters"))["stSignOut"] as? Int ?? 0
        signOutButton.tap()

        try waitForLabel(app.staticTexts["e2e-auth-state"], equalTo: "signed-out")
        try waitForLabel(app.staticTexts["e2e-session-handle"], equalTo: "no-session")
        _ = try await waitForCounters { ($0["stSignOut"] as? Int ?? 0) > signOutCountBefore }

        app.terminate()
        app.launch()
        try waitForLabel(app.staticTexts["e2e-sdk-state"], equalTo: "ready")
        try waitForLabel(app.staticTexts["e2e-auth-state"], equalTo: "signed-out")
        try waitForLabel(app.staticTexts["e2e-session-handle"], equalTo: "no-session")
    }

    func testExpiredSessionRefreshesAfterColdRelaunch() async throws {
        try await assertExpiredSessionRelaunch(refreshUnavailable: false)
    }

    func testRefreshOutageDuringColdRelaunchPreservesLoginAndRecovers() async throws {
        try await assertExpiredSessionRelaunch(refreshUnavailable: true)
    }

    private func assertExpiredSessionRelaunch(refreshUnavailable: Bool) async throws {
        let app = try await launchIsolatedApp(resetSession: true, expiringSession: true)
        let createButton = app.buttons["e2e-create-session-button"]
        try scrollToElement(createButton, in: app)
        createButton.tap()
        try waitForLabel(app.staticTexts["e2e-scenario-state"], equalTo: "e2e_session_created")
        try waitForLabel(app.staticTexts["e2e-auth-state"], equalTo: "authenticated")
        let sessionHandle = app.staticTexts["e2e-session-handle"].label
        XCTAssertNotEqual(sessionHandle, "no-session")
        let expiration = try XCTUnwrap(app.staticTexts["e2e-session-handle"].value as? String)
        let expiresAt = Date(timeIntervalSince1970: try XCTUnwrap(Double(expiration)))
        XCTAssertGreaterThan(expiresAt.timeIntervalSince1970, 0)
        app.terminate()

        // The fixture still issues a 90-second token (> Rownd's 60-second margin).
        // UI interaction and process shutdown have already consumed part of its lifetime.
        let remaining = max(0, expiresAt.timeIntervalSinceNow + 1)
        print("Waiting \(remaining)s for the Core-issued token to expire")
        try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        let beforeRelaunch = try await request("GET", path: "counters")
        XCTAssertEqual(beforeRelaunch["stRefresh"] as? Int, 0)
        _ = try await request("POST", path: "test/refresh-availability", jsonBody: ["unavailable": refreshUnavailable])
        app.launch()
        try waitForLabel(app.staticTexts["e2e-sdk-state"], equalTo: "ready")
        try waitForLabel(app.staticTexts["e2e-auth-state"], equalTo: "authenticated")
        try waitForLabel(app.staticTexts["e2e-session-handle"], equalTo: sessionHandle)

        if refreshUnavailable {
            _ = try await waitForCounters { ($0["stRefresh"] as? Int ?? 0) > 0 }
            _ = try await request("POST", path: "test/refresh-availability", jsonBody: ["unavailable": false])
            let resolveButton = app.buttons["e2e-resolve-access-token-button"]
            try scrollToElement(resolveButton, in: app)
            resolveButton.tap()
            try waitForLabel(app.staticTexts["e2e-access-token-resolution"], equalTo: "succeeded")
        }

        let protectedButton = app.buttons["e2e-protected-button"]
        try scrollToElement(protectedButton, in: app)
        protectedButton.tap()
        try waitForLabel(app.staticTexts["e2e-scenario-state"], equalTo: "protected_loaded")
        try waitForLabel(app.staticTexts["e2e-session-handle"], equalTo: sessionHandle)
        let counters = try await request("GET", path: "counters")
        XCTAssertGreaterThan(try XCTUnwrap(counters["stRefresh"] as? Int), 0)
        XCTAssertEqual(counters["createSession"] as? Int, 1)
        XCTAssertEqual(counters["passwordlessConsume"] as? Int, 0)
        XCTAssertEqual(counters["legacyRefresh"] as? Int, 0)
        app.terminate()
        app.launch()
        try waitForLabel(app.staticTexts["e2e-sdk-state"], equalTo: "ready")
        try waitForLabel(app.staticTexts["e2e-session-handle"], equalTo: sessionHandle)
        try waitForLabel(app.staticTexts["e2e-auth-state"], equalTo: "authenticated")
    }

    func testExistingSuperTokensSessionReplacesPersistedLegacyTokenOnRelaunch() async throws {
        let app = try await launchIsolatedApp(resetSession: true)
        app.terminate()
        _ = try await request("POST", path: "reset")

        let fixture = try await request("POST", path: "test/legacy-session")
        let userId = try XCTUnwrap(fixture["userId"] as? String)
        let legacyAccessToken = try XCTUnwrap(fixture["accessToken"] as? String)
        let legacyRefreshToken = try XCTUnwrap(fixture["refreshToken"] as? String)
        let email = try XCTUnwrap(fixture["email"] as? String)
        XCTAssertEqual(fixture["sessionHandleCount"] as? Int, 0)

        app.launchEnvironment["ROWND_E2E_EMAIL"] = email
        app.launch()
        app.launchEnvironment.removeValue(forKey: "ROWND_E2E_EMAIL")

        try waitForLabel(app.staticTexts["e2e-sdk-state"], equalTo: "ready")
        try waitForLabel(app.staticTexts["e2e-auth-state"], equalTo: "signed-out")
        let createSessionButton = app.buttons["e2e-create-session-button"]
        try scrollToElement(createSessionButton, in: app)
        createSessionButton.tap()
        try waitForLabel(app.staticTexts["e2e-access-token-validity"], equalTo: "valid")
        let sessionHandle = app.staticTexts["e2e-session-handle"].label
        XCTAssertNotEqual(sessionHandle, "no-session")

        let protectedButton = app.buttons["e2e-protected-button"]
        try scrollToElement(protectedButton, in: app)
        protectedButton.tap()
        try waitForLabel(app.staticTexts["e2e-scenario-state"], equalTo: "protected_loaded")
        XCTAssertTrue(app.staticTexts["e2e-protected-result"].label.contains(userId))

        let createdSessionCounters = try await request("GET", path: "counters")
        XCTAssertEqual(createdSessionCounters["createSession"] as? Int, 1)
        XCTAssertEqual(createdSessionCounters["migrate"] as? Int, 0)

        app.terminate()
        app.launchEnvironment["ROWND_E2E_LEGACY_ACCESS_TOKEN"] = legacyAccessToken
        app.launchEnvironment["ROWND_E2E_LEGACY_REFRESH_TOKEN"] = legacyRefreshToken
        app.launch()
        removeLegacySeedEnvironment(from: app)

        try waitForLabel(app.staticTexts["e2e-sdk-state"], equalTo: "ready")
        try waitForLabel(app.staticTexts["e2e-auth-state"], equalTo: "authenticated")
        let secondLaunch = try await waitForAccessTokenResolution(in: app)
        let secondLaunchCounters = try await request("GET", path: "counters")
        XCTAssertEqual(secondLaunchCounters["migrate"] as? Int, 0)
        XCTAssertEqual(
            secondLaunch.validity,
            "valid",
            "Startup exposed the persisted legacy Rownd token instead of reconciling the existing SuperTokens session"
        )
        XCTAssertEqual(secondLaunch.sessionHandle, sessionHandle)

        app.terminate()
        app.launch()
        try waitForLabel(app.staticTexts["e2e-sdk-state"], equalTo: "ready")
        try waitForLabel(app.staticTexts["e2e-access-token-validity"], equalTo: "valid")
        try waitForLabel(app.staticTexts["e2e-session-handle"], equalTo: sessionHandle)
        let finalCounters = try await request("GET", path: "counters")
        XCTAssertEqual(finalCounters["createSession"] as? Int, 1)
        XCTAssertEqual(finalCounters["migrate"] as? Int, 0)
    }

    func testClearSessionOnNewInstallationClearsNativeSession() async throws {
        let app = try await launchIsolatedApp(resetSession: true)
        let createSessionButton = app.buttons["e2e-create-session-button"]
        try scrollToElement(createSessionButton, in: app)
        createSessionButton.tap()
        try waitForLabel(app.staticTexts["e2e-auth-state"], equalTo: "authenticated")
        let originalSessionHandle = app.staticTexts["e2e-session-handle"].label
        XCTAssertNotEqual(originalSessionHandle, "no-session")

        app.terminate()
        app.launchEnvironment["ROWND_E2E_CLEAR_SESSION_ON_NEW_INSTALLATION"] = "1"
        app.launchEnvironment["ROWND_E2E_SIMULATE_NEW_INSTALLATION"] = "1"
        app.launch()
        removeNewInstallationEnvironment(from: app)
        try waitForLabel(app.staticTexts["e2e-sdk-state"], equalTo: "ready")
        try waitForLabel(app.staticTexts["e2e-auth-state"], equalTo: "signed-out")
        try waitForLabel(app.staticTexts["e2e-session-handle"], equalTo: "no-session")
    }

    func testNewInstallationCleanupRunsBeforeLegacyMigrationAndPreservesMigratedSession() async throws {
        let app = try await launchIsolatedApp(resetSession: true)
        let createSessionButton = app.buttons["e2e-create-session-button"]
        try scrollToElement(createSessionButton, in: app)
        createSessionButton.tap()
        try waitForLabel(app.staticTexts["e2e-auth-state"], equalTo: "authenticated")
        try waitForLabel(app.staticTexts["e2e-access-token-validity"], equalTo: "valid")
        let retainedSessionHandle = app.staticTexts["e2e-session-handle"].label
        XCTAssertNotEqual(retainedSessionHandle, "no-session")

        app.terminate()
        let fixture = try await request("POST", path: "test/unmigrated-legacy-session")
        let userId = try XCTUnwrap(fixture["userId"] as? String)
        let legacyAccessToken = try XCTUnwrap(fixture["accessToken"] as? String)
        let legacyRefreshToken = try XCTUnwrap(fixture["refreshToken"] as? String)
        XCTAssertEqual(fixture["sessionHandleCount"] as? Int, 0)

        app.launchEnvironment["ROWND_E2E_LEGACY_ACCESS_TOKEN"] = legacyAccessToken
        app.launchEnvironment["ROWND_E2E_LEGACY_REFRESH_TOKEN"] = legacyRefreshToken
        app.launchEnvironment["ROWND_E2E_CLEAR_SESSION_ON_NEW_INSTALLATION"] = "1"
        app.launchEnvironment["ROWND_E2E_SIMULATE_NEW_INSTALLATION"] = "1"
        app.launch()
        removeLegacySeedEnvironment(from: app)
        app.launchEnvironment.removeValue(forKey: "ROWND_E2E_SIMULATE_NEW_INSTALLATION")

        try waitForLabel(app.staticTexts["e2e-sdk-state"], equalTo: "ready")
        let counters = try await waitForCounters { ($0["migrate"] as? Int) == 1 }
        try waitForLabel(app.staticTexts["e2e-auth-state"], equalTo: "authenticated")
        XCTAssertEqual(counters["migrate"] as? Int, 1)
        XCTAssertEqual(counters["legacyRefresh"] as? Int, 0)
        XCTAssertEqual(counters["createSession"] as? Int, 1)

        let protectedButton = app.buttons["e2e-protected-button"]
        try scrollToElement(protectedButton, in: app)
        protectedButton.tap()
        try waitForLabel(app.staticTexts["e2e-scenario-state"], equalTo: "protected_loaded")
        let migratedProtected = try protectedResponse(in: app)
        XCTAssertEqual(migratedProtected["userId"] as? String, userId)
        let migratedPayload = try XCTUnwrap(migratedProtected["accessTokenPayload"] as? [String: Any])
        let migratedSessionHandle = try XCTUnwrap(migratedPayload["sessionHandle"] as? String)
        XCTAssertNotEqual(migratedSessionHandle, retainedSessionHandle)

        app.terminate()
        app.launch()
        removeNewInstallationEnvironment(from: app)

        try waitForLabel(app.staticTexts["e2e-sdk-state"], equalTo: "ready")
        try waitForLabel(app.staticTexts["e2e-auth-state"], equalTo: "authenticated")

        let preservedProtectedButton = app.buttons["e2e-protected-button"]
        try scrollToElement(preservedProtectedButton, in: app)
        preservedProtectedButton.tap()
        try waitForLabel(app.staticTexts["e2e-scenario-state"], equalTo: "protected_loaded")
        let preservedProtected = try protectedResponse(in: app)
        XCTAssertEqual(preservedProtected["userId"] as? String, userId)
        let preservedPayload = try XCTUnwrap(preservedProtected["accessTokenPayload"] as? [String: Any])
        XCTAssertEqual(preservedPayload["sessionHandle"] as? String, migratedSessionHandle)

        let finalCounters = try await request("GET", path: "counters")
        XCTAssertEqual(finalCounters["migrate"] as? Int, 1)
        XCTAssertEqual(finalCounters["createSession"] as? Int, 1)
    }

    func testInstallationCleanupPreventsRetainedHubSessionResurrection() async throws {
        try await assertHubDoesNotResurrectSession()
    }

    private func launchIsolatedApp(resetSession: Bool, expiringSession: Bool = false) async throws -> XCUIApplication {
        let app = XCUIApplication()
        app.terminate()
        addTeardownBlock { app.terminate() }
        _ = try await request("POST", path: "reset")
        app.launchEnvironment = [
            "ROWND_E2E": "1",
            "ROWND_E2E_CONFIG_URL": backendURL.appendingPathComponent("config").absoluteString,
        ]
        if resetSession {
            app.launchEnvironment["ROWND_E2E_RESET_SESSION"] = "1"
        }
        if expiringSession {
            app.launchEnvironment["ROWND_E2E_EXPIRING_SESSION"] = "1"
        }
        app.launch()
        app.launchEnvironment.removeValue(forKey: "ROWND_E2E_RESET_SESSION")
        try waitForLabel(app.staticTexts["e2e-sdk-state"], equalTo: "ready")
        if resetSession {
            try waitForLabel(app.staticTexts["e2e-auth-state"], equalTo: "signed-out")
        }
        return app
    }

    private func startEmailSignIn(_ email: String, in app: XCUIApplication) throws {
        try startEmailFlow(email, buttonIdentifier: "e2e-sign-in-email-button", in: app)
    }

    private func startEmailFlow(
        _ email: String,
        buttonIdentifier: String,
        in app: XCUIApplication
    ) throws {
        try waitForLabel(app.staticTexts["e2e-challenge-state"], equalTo: "clear")
        let signInButton = app.buttons[buttonIdentifier]
        try scrollToElement(signInButton, in: app)
        signInButton.tap()

        let webView = app.webViews.firstMatch
        let emailField = webView.textFields.firstMatch
        XCTAssertTrue(emailField.waitForExistence(timeout: 15))
        emailField.tap()
        emailField.typeText(email)
        let continueButton = webView.buttons["Continue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 10))
        continueButton.tap()
        try waitForLabel(app.staticTexts["e2e-challenge-state"], equalTo: "active")
    }

    private func completeEmailOTP(_ code: String, in app: XCUIApplication) {
        let webView = app.webViews.firstMatch
        let useCodeButton = webView.buttons["Use a code instead"]
        XCTAssertTrue(useCodeButton.waitForExistence(timeout: 10))
        useCodeButton.tap()
        let codeField = webView.textFields.firstMatch
        XCTAssertTrue(codeField.waitForExistence(timeout: 10))
        codeField.tap()
        codeField.typeText(code)
        let continueButton = webView.buttons["Continue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 10))
        continueButton.tap()
    }

    private func removeLegacySeedEnvironment(from app: XCUIApplication) {
        app.launchEnvironment.removeValue(forKey: "ROWND_E2E_LEGACY_ACCESS_TOKEN")
        app.launchEnvironment.removeValue(forKey: "ROWND_E2E_LEGACY_REFRESH_TOKEN")
    }

    private func removeNewInstallationEnvironment(from app: XCUIApplication) {
        app.launchEnvironment.removeValue(forKey: "ROWND_E2E_CLEAR_SESSION_ON_NEW_INSTALLATION")
        app.launchEnvironment.removeValue(forKey: "ROWND_E2E_SIMULATE_NEW_INSTALLATION")
    }

    private func assertHubDoesNotResurrectSession() async throws {
        let app = try await launchIsolatedApp(resetSession: true)
        let email = uniqueEmail(prefix: "ios-installation-cleanup")

        try startEmailSignIn(email, in: app)
        let capture = try await waitForPasswordlessCapture(email: email)
        completeEmailOTP(try XCTUnwrap(capture["userInputCode"] as? String), in: app)
        try waitForLabel(app.staticTexts["e2e-auth-state"], equalTo: "authenticated")
        try waitForLabel(app.staticTexts["e2e-sign-in-completed-count"], equalTo: "1")
        try waitForDisappearance(app.webViews.firstMatch)
        let authenticatedUserId = app.staticTexts["e2e-user-id"].label

        let authenticatedCounters = try await request("GET", path: "counters")
        let authenticatedConsumeCount = authenticatedCounters["passwordlessConsume"] as? Int ?? 0
        let authenticatedMigrateCount = authenticatedCounters["migrate"] as? Int ?? 0
        XCTAssertGreaterThan(authenticatedConsumeCount, 0)
        XCTAssertEqual(authenticatedMigrateCount, 0, "Passwordless authentication unexpectedly involved migration")

        app.terminate()
        app.launchEnvironment["ROWND_E2E_CLEAR_SESSION_ON_NEW_INSTALLATION"] = "1"
        app.launchEnvironment["ROWND_E2E_SIMULATE_NEW_INSTALLATION"] = "1"
        app.launch()
        removeNewInstallationEnvironment(from: app)

        try waitForLabel(app.staticTexts["e2e-sdk-state"], equalTo: "ready")
        try waitForLabel(app.staticTexts["e2e-auth-state"], equalTo: "signed-out")
        try waitForLabel(app.staticTexts["e2e-session-handle"], equalTo: "no-session")
        try waitForLabel(app.staticTexts["e2e-sign-in-completed-count"], equalTo: "0")

        let countersBeforeOpeningHub = try await request("GET", path: "counters")
        let consumeCountBeforeOpeningHub = countersBeforeOpeningHub["passwordlessConsume"] as? Int ?? 0
        let migrateCountBeforeOpeningHub = countersBeforeOpeningHub["migrate"] as? Int ?? 0
        XCTAssertEqual(consumeCountBeforeOpeningHub, authenticatedConsumeCount)
        XCTAssertEqual(migrateCountBeforeOpeningHub, authenticatedMigrateCount)

        let signInButton = app.buttons["e2e-sign-in-account-button"]
        try scrollToElement(signInButton, in: app)
        signInButton.tap()
        try waitForLabel(app.staticTexts["e2e-scenario-state"], equalTo: "modal_open_requested")
        let webView = app.webViews.firstMatch
        let webViewAppeared = webView.waitForExistence(timeout: 15)

        let settled = try await request("GET", path: "test/passwordless/consumes/settled")
        let finalCounters = try await request("GET", path: "counters")
        let authState = app.staticTexts["e2e-auth-state"].label
        let sessionHandle = app.staticTexts["e2e-session-handle"].label
        let completionCount = app.staticTexts["e2e-sign-in-completed-count"].label
        let userId = app.staticTexts["e2e-user-id"].label
        let scenarioState = app.staticTexts["e2e-scenario-state"].label
        let remainedSignedOut = app.state == .runningForeground
            && scenarioState == "modal_open_requested"
            && webViewAppeared
            && webView.exists
            && authState == "signed-out"
            && sessionHandle == "no-session"
            && completionCount == "0"
            && (settled["count"] as? Int) == consumeCountBeforeOpeningHub
            && (settled["changedDuringObservation"] as? Bool) == false
            && (finalCounters["migrate"] as? Int) == migrateCountBeforeOpeningHub

        if !remainedSignedOut {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Session resurrection state"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        XCTAssertTrue(
            remainedSignedOut,
            """
            Hub did not remain signed out without user interaction.
            appState=\(app.state.rawValue)
            scenario=\(scenarioState)
            webViewAppeared=\(webViewAppeared)
            webViewExists=\(webView.exists)
            auth=\(authState)
            session=\(sessionHandle)
            completion=\(completionCount)
            userId=\(userId)
            authenticatedUserId=\(authenticatedUserId)
            settled=\(settled)
            counters=\(finalCounters)
            """
        )
    }

    private func waitForAccessTokenResolution(
        in app: XCUIApplication,
        timeout: TimeInterval = 2
    ) async throws -> (validity: String, sessionHandle: String) {
        let validity = app.staticTexts["e2e-access-token-validity"]
        let sessionHandle = app.staticTexts["e2e-session-handle"]
        XCTAssertTrue(validity.waitForExistence(timeout: timeout))
        XCTAssertTrue(sessionHandle.waitForExistence(timeout: timeout))

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if validity.label == "valid" {
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        return (validity.label, sessionHandle.label)
    }

    private func customSchemeURL(from link: String) throws -> URL {
        let source = try XCTUnwrap(URLComponents(string: link))
        var deepLink = URLComponents()
        deepLink.scheme = "rowndsupertokens"
        deepLink.host = "account"
        deepLink.path = "/login"
        deepLink.queryItems = source.queryItems
        deepLink.fragment = source.fragment
        return try XCTUnwrap(deepLink.url)
    }

    private func scrollToElement(_ element: XCUIElement, in app: XCUIApplication) throws {
        let scrollView = app.scrollViews.firstMatch
        for _ in 0..<8 {
            if element.exists,
               element.isHittable,
               element.frame.minY >= app.frame.minY,
               element.frame.maxY <= app.frame.maxY - 20 {
                return
            }
            if element.exists && element.frame.minY < app.frame.minY {
                scrollView.swipeDown()
            } else {
                scrollView.swipeUp()
            }
        }
        guard element.exists && element.isHittable else { throw RealHubUITestError.elementNotHittable }
    }

    private func waitForLabel(
        _ element: XCUIElement,
        equalTo label: String,
        timeout: TimeInterval = 20
    ) throws {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND label == %@", label),
            object: element
        )
        guard XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed else {
            throw RealHubUITestError.timedOut
        }
    }

    private func protectedResponse(in app: XCUIApplication) throws -> [String: Any] {
        let label = app.staticTexts["e2e-protected-result"].label
        guard let body = label.split(separator: "\n", maxSplits: 1).last,
              let data = String(body).data(using: .utf8),
              let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RealHubUITestError.unexpectedResponse
        }
        return response
    }

    private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval = 10) throws {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: element
        )
        guard XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed else {
            throw RealHubUITestError.timedOut
        }
    }

    private func waitForPasswordlessCapture(email: String) async throws -> [String: Any] {
        try await poll(path: "test/passwordless/latest") {
            $0["status"] as? String == "OK" && $0["email"] as? String == email
        }
    }

    private func uniqueEmail(prefix: String) -> String {
        let suffix = UUID().uuidString.lowercased().replacingOccurrences(
            of: "[0-9]",
            with: "x",
            options: .regularExpression
        )
        return "\(prefix)-\(suffix)@example.com"
    }

    private func waitForConsumes(count: Int) async throws -> [String: Any] {
        try await poll(path: "test/passwordless/consumes") { ($0["count"] as? Int ?? 0) >= count }
    }

    private func waitForCounters(
        predicate: @escaping ([String: Any]) -> Bool
    ) async throws -> [String: Any] {
        try await poll(path: "counters", predicate: predicate)
    }

    private func poll(
        path: String,
        timeout: TimeInterval = 15,
        predicate: @escaping ([String: Any]) -> Bool
    ) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let response = try await request("GET", path: path)
            if predicate(response) { return response }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw RealHubUITestError.timedOut
    }

    private func request(
        _ method: String,
        path: String,
        jsonBody: [String: Any]? = nil
    ) async throws -> [String: Any] {
        var request = URLRequest(url: backendURL.appendingPathComponent(path))
        request.httpMethod = method
        if let jsonBody {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode),
              let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RealHubUITestError.unexpectedResponse
        }
        return payload
    }
}

private enum RealHubUITestError: Error {
    case elementNotHittable
    case timedOut
    case unexpectedResponse
}
