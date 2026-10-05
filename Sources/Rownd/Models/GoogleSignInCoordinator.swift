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
    var parent: Rownd
    var intent: RowndSignInIntent?
    var signInClient = SuperTokensThirdPartySignInClient()
    var syncAuthState: () async -> Void = {
        await SuperTokensSessionBridge.syncRowndAuthStateFromSuperTokens()
    }
    var currentAccessToken: () async -> String? = {
        await SuperTokensSessionBridge.getAccessToken()
    }
    var emitEvent: @MainActor (RowndEvent) -> Void = { event in
        RowndEventEmitter.emit(event)
    }

    init(_ parent: Rownd) {
        self.parent = parent
        super.init()
    }

    func signIn(_ intent: RowndSignInIntent?) async {
        await signIn(intent, hint: nil)
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
            emitEvent(.signInStarted(method: .google))

            do {
                let result = try await GIDSignIn.sharedInstance.signIn(
                    withPresenting: rootViewController,
                    hint: hint
                )
                
                guard let idToken = result.user.idToken else {
                    failSignIn(RowndError("Google sign-in did not return an ID token"), webViewId: webViewId)
                    return
                }
                
                logger.debug("Sign-in handshake with Google completed successfully.")
                do {
                    Rownd.customerWebViews.evaluateJavaScript(webViewId: webViewId, code: "window.rownd.requestSignIn({ 'login_step': 'completing' });")
                    
                    _ = try await signInClient.signInWithGoogle(idToken: idToken.tokenString)
                    await syncAuthState()

                    guard let accessToken = await currentAccessToken() else {
                        failSignIn(RowndError("Token response is empty"), webViewId: webViewId)
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
                        Rownd.customerWebViews.evaluateJavaScript(webViewId: webViewId, code: """
                            let url = new URL(window.location.href);
                            let fragmentParts = url.hash?.split(',') || [];
                            fragmentParts.push(`rph_init=\(rphInitString)`);
                            url.hash = fragmentParts.join(',');
                            window.location.replace(url.toString());
                            window.location.reload(); // It would be best if we didn't have to reload, but the Hub has problems handling updated rph_ hash values without doing a full reload.
                        """)
                        return
                    } catch {
                        logger.error("Failed to build rph_init hash string: \(String(describing: error))")
                        failSignIn(error, webViewId: webViewId)
                        return
                    }
                } catch {
                    failSignIn(error, webViewId: webViewId)
                }
            } catch {
                guard !Self.isCancellation(error) else { return }
                failSignIn(error, webViewId: webViewId)
            }
        }
    }

    func signIn(_ intent: RowndSignInIntent?, hint: String?) async {
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
            emitEvent(.signInStarted(method: .google))

            do {
                let result = try await GIDSignIn.sharedInstance.signIn(
                    withPresenting: rootViewController,
                    hint: hint
                )

                guard let idToken = result.user.idToken else {
                    failSignIn(RowndError("Google sign-in did not return an ID token"))
                    return
                }

                logger.debug("Sign-in handshake with Google completed successfully.")
                await completeSignIn(idToken: idToken.tokenString, intent: intent)
            } catch {
                guard !Self.isCancellation(error) else { return }
                failSignIn(error)
            }
        }
    }

    @MainActor func completeSignIn(idToken: String, intent: RowndSignInIntent?) async {
        Rownd.requestSignIn(jsFnOptions: RowndSignInJsOptions(
            loginStep: .completing
        ))

        do {
            let signInResponse = try await signInClient.signInWithGoogle(idToken: idToken)
            await syncAuthState()
            guard await currentAccessToken() != nil else {
                failSignIn(RowndError("Token response is empty"))
                return
            }

            Context.currentContext.store.dispatch(UserData.fetch())
            Context.currentContext.store.dispatch(SetLastSignInMethod(payload: SignInMethodTypes.google))

            Rownd.requestSignIn(
                jsFnOptions: RowndSignInJsOptions(
                    loginStep: .success,
                    intent: intent,
                    userType: signInResponse.userType,
                    appVariantUserType: signInResponse.userType
                )
            )

            emitEvent(RowndEvent(
                event: .signInCompleted,
                data: [
                    "method": AnyCodable(SignInType.google.rawValue),
                    "user_type": AnyCodable(signInResponse.userType.rawValue),
                    "app_variant_user_type": AnyCodable(signInResponse.userType.rawValue)
                ]
            ))
        } catch ApiError.generic(let errorInfo) where errorInfo.code == "E_SIGN_IN_USER_NOT_FOUND" {
            Rownd.requestSignIn(jsFnOptions: RowndSignInJsOptions(
                token: idToken,
                loginStep: .noAccount,
                intent: .signIn
            ))
            logger.error("Google sign-in failed during Rownd token exchange. Error: \(String(describing: errorInfo))")
        } catch {
            failSignIn(error)
        }
    }

    /// Moves the Hub to its error step and emits `signInFailed`; `webViewId` targets a customer web view's Hub.
    @MainActor private func failSignIn(_ error: Error, webViewId: String? = nil) {
        logger.error("Google sign-in failed. Error: \(String(describing: error))")
        if let webViewId {
            Rownd.customerWebViews.evaluateJavaScript(webViewId: webViewId, code: "window.rownd.requestSignIn({ 'login_step': 'error', 'sign_in_type': 'google' });")
        } else {
            Rownd.requestSignIn(jsFnOptions: RowndSignInJsOptions(
                loginStep: .error,
                signInType: .google
            ))
        }
        emitEvent(.signInFailed(method: .google, error: error))
    }

    private static func isCancellation(_ error: Error) -> Bool {
        (error as? GIDSignInError)?.code == .canceled
    }
}
