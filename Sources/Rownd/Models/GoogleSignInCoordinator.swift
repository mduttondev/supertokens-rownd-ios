//
//  GoogleSignInCoordinator.swift
//  Rownd
//
//  Created by Matt Hamann on 4/4/23.
//

import Foundation
import GoogleSignIn
import UIKit
import AnyCodable
import JWTDecode

class GoogleSignInCoordinator: NSObject {
    @MainActor private var currentAttemptID: UUID?
    var parent: Rownd
    var intent: RowndSignInIntent?
    var signInWithGoogle: (String) async throws -> SuperTokensThirdPartySignInResponse
    var syncAuthState: () async -> Bool = {
        await SuperTokensSessionBridge.syncRowndAuthStateFromSuperTokens()
    }
    var currentAccessToken: () async -> String? = {
        await SuperTokensSessionBridge.getAccessToken()
    }
    var emitEvent: @MainActor (RowndEvent) -> Void = { event in
        RowndEventEmitter.emit(event)
    }
    var dispatchSignInActions: @MainActor () -> Void = {
        Context.currentContext.store.dispatch(UserData.fetch())
        Context.currentContext.store.dispatch(SetLastSignInMethod(payload: SignInMethodTypes.google))
    }
    var evaluateCustomerWebViewJavaScript: @MainActor (String, String) -> Void = { webViewId, code in
        Rownd.customerWebViews.evaluateJavaScript(webViewId: webViewId, code: code)
    }

    init(_ parent: Rownd, signInClient: SuperTokensThirdPartySignInClient = SuperTokensThirdPartySignInClient()) {
        self.parent = parent
        self.signInWithGoogle = { idToken in
            try await signInClient.signInWithGoogle(idToken: idToken)
        }
        super.init()
    }

    func signIn(_ intent: RowndSignInIntent?) async {
        await signIn(intent, hint: nil, emitsSignInStarted: true)
    }

    func defaultSignInFlow() {
        logger.error("Falling back to default sign flow")
        Rownd.requestSignIn(RowndSignInOptions(intent: intent))
    }

    /// Sign in funciton for customer-provided web views
    func signIn(webViewId: String, intent: RowndSignInIntent?, hint: String?) -> Void {
        let googleConfig = Context.currentContext.store.state.appConfig.config?.hub?.auth?.signInMethods?.google

        guard let iosClientId = googleConfig?.iosClientId, let serverClientId = googleConfig?.serverClientId else {
            logger.error("Google sign-in config missing required properties")
            return
        }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(
            clientID: iosClientId,
            serverClientID: serverClientId
        )

        Task { @MainActor in
            guard let rootViewController = parent.getRootViewController() else {
                logger.error("Failed to retrieve root view controller")
                return
            }
            // The Hub in the customer web view has already dispatched its own start event.
            let attemptID = beginAttempt(emitsSignInStarted: false)

            do {
                let result = try await GIDSignIn.sharedInstance.signIn(
                    withPresenting: rootViewController,
                    hint: hint
                )
                
                guard let idToken = result.user.idToken else {
                    failSignIn(RowndError("Google sign-in did not return an ID token"), attemptID: attemptID, webViewId: webViewId)
                    return
                }

                logger.debug("Sign-in handshake with Google completed successfully.")
                await completeSignIn(idToken: idToken.tokenString, webViewId: webViewId, attemptID: attemptID)
            } catch {
                guard !Self.isCancellation(error) else { return }
                failSignIn(error, attemptID: attemptID, webViewId: webViewId)
            }
        }
    }

    @MainActor func completeSignIn(idToken: String, webViewId: String, attemptID: UUID) async {
        evaluateCustomerWebViewJavaScript(webViewId, "window.rownd.requestSignIn({ 'login_step': 'completing' });")

        do {
            let signInResponse = try await signInWithGoogle(idToken)
            guard await syncAuthState(), let accessToken = await currentAccessToken() else {
                failSignIn(Self.authSyncFailure, attemptID: attemptID, webViewId: webViewId)
                return
            }
            guard isCurrentAttempt(attemptID) else {
                // Signinup already adopted the session, so report it natively without reloading the newer flow's page.
                reportSignInCompleted(signInResponse)
                return
            }

            // Reload the web view page with rph_init appended to the URL fragment in order
            // to complete the sign-in
            do {
                let jwt = try decode(jwt: accessToken)
                let appId = jwt.audience?.first(where: {
                    return $0.starts(with: "app:")
                })?.replacingOccurrences(of: "app:", with: "")
                let appUserId = jwt.claim(name: "https://auth.rownd.io/app_user_id")

                let rphInit = RphInit(
                    accessToken: accessToken,
                    refreshToken: SuperTokensSessionBridge.getRefreshToken(),
                    frontToken: SuperTokensSessionBridge.getFrontToken(),
                    antiCSRF: SuperTokensSessionBridge.getAntiCSRF(),
                    appId: appId ?? Context.currentContext.store.state.appConfig.id,
                    appUserId: appUserId.string
                )

                let rphInitString = try rphInit.valueForURLFragment()
                evaluateCustomerWebViewJavaScript(webViewId, """
                    let url = new URL(window.location.href);
                    let fragmentParts = url.hash?.split(',') || [];
                    fragmentParts.push(`rph_init=\(rphInitString)`);
                    url.hash = fragmentParts.join(',');
                    window.location.replace(url.toString());
                    window.location.reload(); // It would be best if we didn't have to reload, but the Hub has problems handling updated rph_ hash values without doing a full reload.
                """)
            } catch {
                logger.error("Failed to build rph_init hash string: \(String(describing: error))")
                failSignIn(error, attemptID: attemptID, webViewId: webViewId)
            }
        } catch {
            failSignIn(error, attemptID: attemptID, webViewId: webViewId)
        }
    }

    func signIn(_ intent: RowndSignInIntent?, hint: String?, emitsSignInStarted: Bool) async {
        let googleConfig = Context.currentContext.store.state.appConfig.config?.hub?.auth?.signInMethods?.google
        guard googleConfig?.enabled == true, let googleConfig = googleConfig else {
            logger.error("Google sign-in is not enabled in the backend app config. Expected /plugin/rownd/app-config to include config.hub.auth.sign_in_methods.google.enabled=true.")
            defaultSignInFlow()
            return
        }

        if googleConfig.serverClientId == nil ||
            googleConfig.serverClientId == "" ||
            googleConfig.iosClientId == nil ||
            googleConfig.iosClientId == "" {
            logger.error("Cannot sign in with Google. Missing client configuration")
            defaultSignInFlow()
            return
        }

        let reversedClientId = googleConfig.iosClientId!.split(separator: ".").reversed().joined(separator: ".")
        if let url = NSURL(string: reversedClientId + "://") {
            if await UIApplication.shared.canOpenURL(url as URL) == false {
                logger.error("Cannot sign in with Google. \(String(describing: reversedClientId)) is not defined in URL schemes")
                defaultSignInFlow()
                return
            }
        }

        GIDSignIn.sharedInstance.configuration = GIDConfiguration(
            clientID: (googleConfig.iosClientId)!,   // (IOS)
            serverClientID: googleConfig.serverClientId  // (Web)
        )

        Task { @MainActor in
            guard let rootViewController = parent.getRootViewController() else {
                logger.error("Failed to retrieve root view controller")
                defaultSignInFlow()
                return
            }
            let attemptID = beginAttempt(emitsSignInStarted: emitsSignInStarted)

            do {
                let result = try await GIDSignIn.sharedInstance.signIn(
                    withPresenting: rootViewController,
                    hint: hint
                )

                guard let idToken = result.user.idToken else {
                    failSignIn(RowndError("Google sign-in did not return an ID token"), attemptID: attemptID)
                    return
                }

                logger.debug("Sign-in handshake with Google completed successfully.")
                await completeSignIn(idToken: idToken.tokenString, intent: intent, attemptID: attemptID)
            } catch {
                guard !Self.isCancellation(error) else { return }
                failSignIn(error, attemptID: attemptID)
            }
        }
    }

    /// Starts a Google attempt that supersedes any earlier one; only direct SDK calls emit `signInStarted`.
    @MainActor func beginAttempt(emitsSignInStarted: Bool) -> UUID {
        let attemptID = UUID()
        currentAttemptID = attemptID
        if emitsSignInStarted {
            emitEvent(.signInStarted(method: .google))
        }
        return attemptID
    }

    @MainActor func completeSignIn(idToken: String, intent: RowndSignInIntent?, attemptID: UUID) async {
        let hubRequestID = UUID()
        Rownd.requestSignInForNativeCompletion(
            jsFnOptions: RowndSignInJsOptions(loginStep: .completing),
            requestID: hubRequestID
        )

        do {
            let signInResponse = try await signInWithGoogle(idToken)
            guard await syncAuthState(), await currentAccessToken() != nil else {
                failSignIn(Self.authSyncFailure, attemptID: attemptID, hubRequestID: hubRequestID)
                return
            }
            // Signinup already adopted the session, so a superseded attempt still reports it; only the Hub UI stays scoped.
            if isCurrentAttempt(attemptID) {
                Rownd.updateSignInForNativeCompletion(
                    jsFnOptions: RowndSignInJsOptions(
                        loginStep: .success,
                        intent: intent,
                        userType: signInResponse.userType,
                        appVariantUserType: signInResponse.userType
                    ),
                    requestID: hubRequestID
                )
            }
            reportSignInCompleted(signInResponse)
        } catch ApiError.generic(let errorInfo) where errorInfo.code == "E_SIGN_IN_USER_NOT_FOUND" {
            logger.error("Google sign-in failed during Rownd token exchange. Error: \(String(describing: errorInfo))")
            guard isCurrentAttempt(attemptID) else { return }
            Rownd.updateSignInForNativeCompletion(
                jsFnOptions: RowndSignInJsOptions(
                    token: idToken,
                    loginStep: .noAccount,
                    intent: .signIn
                ),
                requestID: hubRequestID
            )
        } catch {
            failSignIn(error, attemptID: attemptID, hubRequestID: hubRequestID)
        }
    }

    @MainActor private func isCurrentAttempt(_ attemptID: UUID) -> Bool {
        currentAttemptID == attemptID
    }

    @MainActor private func reportSignInCompleted(_ signInResponse: SuperTokensThirdPartySignInResponse) {
        dispatchSignInActions()
        emitEvent(RowndEvent(
            event: .signInCompleted,
            data: [
                "method": AnyCodable(SignInType.google.rawValue),
                "user_type": AnyCodable(signInResponse.userType.rawValue),
                "app_variant_user_type": AnyCodable(signInResponse.userType.rawValue)
            ]
        ))
    }

    /// Emits `signInFailed` for the current attempt; the error step lands only while its Hub request is still active.
    @MainActor private func failSignIn(_ error: Error, attemptID: UUID, hubRequestID: UUID? = nil) {
        logger.error("Google sign-in failed. Error: \(String(describing: error))")
        guard isCurrentAttempt(attemptID) else { return }
        let errorOptions = RowndSignInJsOptions(loginStep: .error, signInType: .google)
        if let hubRequestID {
            Rownd.updateSignInForNativeCompletion(jsFnOptions: errorOptions, requestID: hubRequestID)
        } else {
            Rownd.requestSignIn(jsFnOptions: errorOptions)
        }
        emitEvent(.signInFailed(method: .google, error: error))
    }

    @MainActor private func failSignIn(_ error: Error, attemptID: UUID, webViewId: String) {
        logger.error("Google sign-in failed. Error: \(String(describing: error))")
        guard isCurrentAttempt(attemptID) else { return }
        evaluateCustomerWebViewJavaScript(webViewId, "window.rownd.requestSignIn({ 'login_step': 'error', 'sign_in_type': 'google' });")
        emitEvent(.signInFailed(method: .google, error: error))
    }

    private static let authSyncFailure = RowndError("Rownd auth state did not sync after Google sign-in")

    private static func isCancellation(_ error: Error) -> Bool {
        (error as? GIDSignInError)?.code == .canceled
    }
}
