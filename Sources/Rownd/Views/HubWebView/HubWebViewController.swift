//
//  WebViewController.swift
//  ios native
//
//  Created by Matt Hamann on 6/14/22.
//

import Foundation
import UIKit
import WebKit
import SwiftUI
import ReSwift
import ReSwiftThunk
import AnyCodable
import SuperTokensIOS

public enum HubPageSelector {
    case signIn
    case signOut
    case qrCode
    case manageAccount
    case deepLink
    case unknown
}

private final class InputAccessoryHackHelper: NSObject {
    @objc var inputAccessoryView: AnyObject? { return nil }
}

private final class URLSessionTaskCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var isCancelled = false

    func setTask(_ task: URLSessionTask) {
        lock.lock()
        self.task = task
        let shouldCancel = isCancelled
        lock.unlock()
        if shouldCancel {
            task.cancel()
        }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
    }
}

extension WKWebView {
    func hack_removeInputAccessory() {
        guard let target = scrollView.subviews.first(where: {
            String(describing: type(of: $0)).hasPrefix("WKContent")
        }), let superclass = target.superclass else {
            return
        }

        let noInputAccessoryViewClassName = "\(superclass)_NoInputAccessoryView"
        var newClass: AnyClass? = NSClassFromString(noInputAccessoryViewClassName)

        if newClass == nil, let targetClass = object_getClass(target), let classNameCString = noInputAccessoryViewClassName.cString(using: .ascii) {
            newClass = objc_allocateClassPair(targetClass, classNameCString, 0)

            if let newClass = newClass {
                objc_registerClassPair(newClass)
            }
        }

        guard let noInputAccessoryClass = newClass, let originalMethod = class_getInstanceMethod(InputAccessoryHackHelper.self, #selector(getter: InputAccessoryHackHelper.inputAccessoryView)) else {
            return
        }
        class_addMethod(noInputAccessoryClass.self, #selector(getter: InputAccessoryHackHelper.inputAccessoryView), method_getImplementation(originalMethod), method_getTypeEncoding(originalMethod))
        object_setClass(target, noInputAccessoryClass)
    }
}

public class HubWebViewController: UIViewController, WKUIDelegate {
    static let nativeEmailVerificationEventName = "rownd:native-email-verification"
    private static let offlinePageURL = URL(string: "rownd-offline://retry/")!

    struct HubLoadFailure: Equatable {
        let host: String
        let errorDomain: String
        let errorCode: Int

        var event: RowndEvent {
            RowndEvent(event: .hubLoadFailed, data: [
                "host": AnyCodable(host),
                "error_domain": AnyCodable(errorDomain),
                "error_code": AnyCodable(errorCode)
            ])
        }
    }

    struct NativeEmailVerificationParameters: Equatable {
        let token: String
        let pendingVerificationId: String
    }

    static func canHandleAuthentication(
        on targetPage: HubPageSelector?,
        nativeEmailVerificationOwnsSessionReplacement: Bool = false
    ) -> Bool {
        (targetPage == .signIn || targetPage == .deepLink) &&
            !nativeEmailVerificationOwnsSessionReplacement
    }

    static func shouldForwardHubEvent(_ event: RowndEvent, on targetPage: HubPageSelector?) -> Bool {
        event.event != .signInCompleted || !canHandleAuthentication(on: targetPage)
    }

    static func hubRequest(url: URL) -> URLRequest {
        URLRequest(url: url)
    }

    static func hubLoadFailure(error: Error, configuredURL: URL?) -> HubLoadFailure? {
        let error = error as NSError
        guard error.domain != NSURLErrorDomain || error.code != NSURLErrorCancelled else {
            return nil
        }

        let failingURL = (error.userInfo[NSURLErrorFailingURLErrorKey] as? URL)
            ?? (error.userInfo[NSURLErrorFailingURLStringErrorKey] as? String).flatMap(URL.init(string:))
        let host = failingURL?.host ?? configuredURL?.host ?? "unknown"
        return HubLoadFailure(host: host, errorDomain: error.domain, errorCode: error.code)
    }

    @MainActor static func completeAuthentication(
        store: Store<RowndState>,
        initialJsFunctionArgsAsJson: String,
        currentJsFunctionArgsAsJson: @escaping @MainActor () -> String?,
        hideHub: @escaping @MainActor (@escaping () -> Void) -> Void,
        eventData: [String: String] = [:],
        shouldComplete: @MainActor () -> Bool = { true }
    ) async {
        guard shouldComplete() else { return }
        store.dispatch(UserData.fetch())
        store.dispatch(ResetSignInState())

        // Close the hub as long as no other rownd api was called
        if initialJsFunctionArgsAsJson == currentJsFunctionArgsAsJson() {
            await withCheckedContinuation { continuation in
                hideHub {
                    continuation.resume()
                }
            }
        }

        guard shouldComplete() else { return }
        let signInCompletedData = eventData.reduce(into: [String: AnyCodable?]()) { result, entry in
            result[entry.key] = AnyCodable(entry.value)
        }
        logger.debug("Emitting sign_in_completed from authentication result: user_type=\(eventData["user_type"] ?? "nil") app_variant_user_type=\(eventData["app_variant_user_type"] ?? "nil")")
        RowndEventEmitter.emit(RowndEvent(
            event: .signInCompleted,
            data: signInCompletedData.isEmpty ? nil : signInCompletedData
        ))
    }

    static func completeAuthenticationAfterAdoption(
        succeeded: Bool,
        syncAuthState: () async -> Bool,
        syncFailure: () async -> Void,
        completion: () async -> Void
    ) async {
        guard succeeded else {
            logger.warning("Skipping Hub authentication completion because the SuperTokens session could not be adopted")
            return
        }

        guard await syncAuthState() else {
            logger.warning("Skipping Hub authentication completion: reason=no_access_token_after_session_adoption")
            await syncFailure()
            return
        }
        await completion()
    }

    static func authenticationSyncFailureRequest() -> (arguments: String, script: String)? {
        guard let arguments = try? RowndSignInJsOptions(loginStep: .error).asJsonString() else {
            return nil
        }
        return (arguments, "rownd.requestSignIn(\(arguments))")
    }

    @MainActor private func showAuthenticationSyncFailure(
        navigationGeneration expectedNavigationGeneration: Int,
        authenticationGeneration expectedAuthenticationGeneration: Int
    ) {
        guard navigationGeneration == expectedNavigationGeneration,
              authenticationGeneration == expectedAuthenticationGeneration else {
            return
        }
        guard let request = Self.authenticationSyncFailureRequest() else {
            logger.error("Could not encode the Hub authentication synchronization error state")
            return
        }
        jsFunctionArgsAsJson = request.arguments
        evaluateJavaScript(code: request.script, webView: webView)
    }

    static func nativeEmailVerificationEventScript(
        requestId: String,
        expectedURL: URL,
        status: String? = nil,
        error: String? = nil
    ) -> String? {
        var detail = ["request_id": requestId]
        if let status {
            detail["status"] = status
        }
        if let error {
            detail["error"] = error
        }

        guard let data = try? JSONSerialization.data(withJSONObject: detail),
              let json = String(data: data, encoding: .utf8),
              let expectedURLData = try? JSONSerialization.data(
                withJSONObject: expectedURL.absoluteString,
                options: .fragmentsAllowed
              ),
              let expectedURLJSON = String(data: expectedURLData, encoding: .utf8) else {
            return nil
        }

        return "if (window.location.href === \(expectedURLJSON)) { window.dispatchEvent(new CustomEvent('\(nativeEmailVerificationEventName)', { detail: \(json) })); }"
    }

    private static func effectivePort(scheme: String?, port: Int?) -> Int? {
        if let port, port != 0 {
            return port
        }
        switch scheme?.lowercased() {
        case "https":
            return 443
        case "http":
            return 80
        default:
            return nil
        }
    }

    static func hasTrustedOrigin(_ url: URL?, baseURL: String) -> Bool {
        guard let url,
              let trustedURL = URL(string: baseURL),
              let scheme = url.scheme?.lowercased(),
              let trustedScheme = trustedURL.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              let trustedHost = trustedURL.host?.lowercased() else {
            return false
        }

        return scheme == trustedScheme &&
            host == trustedHost &&
            effectivePort(scheme: scheme, port: url.port) == effectivePort(scheme: trustedScheme, port: trustedURL.port)
    }

    static func hasTrustedSecurityOrigin(_ origin: WKSecurityOrigin, baseURL: String) -> Bool {
        guard let trustedURL = URL(string: baseURL),
              let trustedScheme = trustedURL.scheme?.lowercased(),
              let trustedHost = trustedURL.host?.lowercased() else {
            return false
        }

        return origin.protocol.lowercased() == trustedScheme &&
            origin.host.lowercased() == trustedHost &&
            effectivePort(scheme: origin.protocol, port: origin.port) == effectivePort(scheme: trustedScheme, port: trustedURL.port)
    }

    static func canHandleHubMessage(
        _ message: WKScriptMessage,
        webView: WKWebView,
        baseURL: String = Rownd.config.baseUrl
    ) -> Bool {
        canHandleHubMessage(
            messageWebViewMatches: message.webView === webView,
            isMainFrame: message.frameInfo.isMainFrame,
            securityOriginProtocol: message.frameInfo.securityOrigin.protocol,
            securityOriginHost: message.frameInfo.securityOrigin.host,
            securityOriginPort: message.frameInfo.securityOrigin.port,
            sourceURL: message.frameInfo.request.url,
            currentURL: webView.url,
            baseURL: baseURL
        )
    }

    static func canHandleHubMessage(
        messageWebViewMatches: Bool,
        isMainFrame: Bool,
        securityOriginProtocol: String,
        securityOriginHost: String,
        securityOriginPort: Int,
        sourceURL: URL?,
        currentURL: URL?,
        baseURL: String
    ) -> Bool {
        guard messageWebViewMatches,
              isMainFrame,
              let trustedURL = URL(string: baseURL),
              securityOriginProtocol.lowercased() == trustedURL.scheme?.lowercased(),
              securityOriginHost.lowercased() == trustedURL.host?.lowercased(),
              effectivePort(scheme: securityOriginProtocol, port: securityOriginPort) == effectivePort(scheme: trustedURL.scheme, port: trustedURL.port),
              let sourceURL,
              sourceURL == currentURL else {
            return false
        }

        return hasTrustedOrigin(sourceURL, baseURL: baseURL)
    }

    private static func canHandleOfflineRetryMessage(
        _ message: WKScriptMessage,
        webView: WKWebView
    ) -> Bool {
        message.webView === webView &&
            message.frameInfo.isMainFrame &&
            message.frameInfo.request.url == offlinePageURL &&
            webView.url == offlinePageURL
    }

    static func nativeEmailVerificationParameters(
        on targetPage: HubPageSelector?,
        url: URL?,
        trustedApiDomain: String,
        trustedApiBasePath: String,
        baseURL: String = Rownd.config.baseUrl
    ) -> NativeEmailVerificationParameters? {
        guard targetPage == .deepLink,
              isAllowedNativeEmailVerificationTransport(trustedApiDomain),
              let url,
              hasTrustedOrigin(url, baseURL: baseURL),
              url.path == "/account/verify-email",
              let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let token = singleNonEmptyQueryValue(named: "token", in: queryItems),
              let pendingVerificationId = singleQueryValue(
                named: "rowndPendingVerificationId",
                in: queryItems
              ),
              !pendingVerificationId.isEmpty,
              let apiDomain = singleNonEmptyQueryValue(named: "apiDomain", in: queryItems),
              let apiBasePath = singleNonEmptyQueryValue(named: "apiBasePath", in: queryItems),
              apiDomainMatches(apiDomain, trustedApiDomain: trustedApiDomain),
              normalizedApiBasePath(apiBasePath) == normalizedApiBasePath(trustedApiBasePath) else {
            return nil
        }

        return NativeEmailVerificationParameters(
            token: token,
            pendingVerificationId: pendingVerificationId
        )
    }

    private static func singleQueryValue(named name: String, in queryItems: [URLQueryItem]) -> String? {
        let matches = queryItems.filter { $0.name == name }
        return matches.count == 1 ? matches[0].value : nil
    }

    private static func singleNonEmptyQueryValue(named name: String, in queryItems: [URLQueryItem]) -> String? {
        guard let value = singleQueryValue(named: name, in: queryItems), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func apiDomainMatches(_ apiDomain: String, trustedApiDomain: String) -> Bool {
        guard let candidate = URL(string: apiDomain),
              let trusted = URL(string: trustedApiDomain),
              hasTrustedOrigin(candidate, baseURL: trustedApiDomain) else {
            return false
        }

        return candidate.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ==
            trusted.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) &&
            candidate.query == nil &&
            candidate.fragment == nil
    }

    static func isAllowedNativeEmailVerificationTransport(_ apiDomain: String) -> Bool {
        guard let components = URLComponents(string: apiDomain),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              let url = components.url else {
            return false
        }

        return isAllowedNativeEmailVerificationTransport(url)
    }

    private static func isAllowedNativeEmailVerificationTransport(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              !host.isEmpty else {
            return false
        }

        if scheme == "https" {
            return true
        }
        return scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)
    }

    private static func normalizedApiBasePath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.isEmpty ? "/" : "/\(trimmed)"
    }

    static func canDeliverNativeEmailVerificationResponse(
        on targetPage: HubPageSelector?,
        requestedURL: URL,
        currentURL: URL?,
        requestedNavigationGeneration: Int,
        currentNavigationGeneration: Int,
        baseURL: String = Rownd.config.baseUrl
    ) -> Bool {
        requestedNavigationGeneration == currentNavigationGeneration &&
            requestedURL == currentURL &&
            targetPage == .deepLink &&
            hasTrustedOrigin(currentURL, baseURL: baseURL) &&
            currentURL?.path == "/account/verify-email"
    }

    static func nativeEmailVerificationRequest(
        parameters: NativeEmailVerificationParameters,
        apiDomain: String,
        apiBasePath: String
    ) throws -> URLRequest {
        guard isAllowedNativeEmailVerificationTransport(apiDomain),
              var components = URLComponents(string: apiDomain) else {
            throw RowndError("Invalid native email verification URL")
        }
        let domainPath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let basePath = normalizedApiBasePath(apiBasePath).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [domainPath, basePath, "user/email/verify"]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        components.queryItems = [
            URLQueryItem(name: "rowndPendingVerificationId", value: parameters.pendingVerificationId)
        ]
        guard let url = components.url,
              isAllowedNativeEmailVerificationTransport(url) else {
            throw RowndError("Invalid native email verification URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "method": "token",
            "token": parameters.token
        ])
        return request
    }

    static func nativeEmailVerificationSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        var protocolClasses = configuration.protocolClasses ?? []
        protocolClasses.removeAll { $0 == SuperTokensURLProtocol.self }
        protocolClasses.insert(SuperTokensURLProtocol.self, at: 0)
        configuration.protocolClasses = protocolClasses
        return URLSession(configuration: configuration)
    }

    static func performNativeEmailVerification(
        request: URLRequest,
        session: URLSession,
        getAccessToken: () async -> String? = SuperTokensSessionBridge.getAccessToken,
        getRefreshToken: () -> String? = SuperTokensSessionBridge.getRefreshToken,
        getFrontToken: () -> String? = SuperTokensSessionBridge.getFrontToken,
        syncReplacementState: (String, String?) async throws -> SuperTokensSessionBridge.ReplacementRowndStateSyncResult = {
            try await SuperTokensSessionBridge.syncReplacementRowndStateFromSuperTokens(
                expectedAccessToken: $0,
                expectedPreviousRowndAccessToken: $1
            )
        },
        scheduleProfileRetry: (SuperTokensSessionBridge.StableSessionIdentity) async -> Void = {
            await UserData.scheduleProfileHydrationRetry(for: $0)
        }
    ) async throws -> (Data, HTTPURLResponse) {
        let previousAccessToken = await getAccessToken()
        let cancellation = URLSessionTaskCancellation()
        let result: (Data, URLResponse) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request) { data, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let data, let response else {
                        continuation.resume(throwing: RowndError("Email verification returned no response"))
                        return
                    }
                    continuation.resume(returning: (data, response))
                }
                cancellation.setTask(task)
                task.resume()
            }
        } onCancel: {
            cancellation.cancel()
        }

        guard let response = result.1 as? HTTPURLResponse,
              (200...299).contains(response.statusCode),
              let payload = try JSONSerialization.jsonObject(with: result.0) as? [String: Any],
              payload["status"] as? String == "OK" else {
            throw RowndError("Email verification failed")
        }

        guard let replacementAccessToken = response.value(forHTTPHeaderField: "st-access-token"),
              !replacementAccessToken.isEmpty,
              replacementAccessToken != previousAccessToken,
              let replacementStableIdentity = SuperTokensSessionBridge.stableSessionIdentity(
                from: replacementAccessToken
              ),
              let currentAccessToken = await getAccessToken(),
              SuperTokensSessionBridge.stableSessionIdentity(from: currentAccessToken)
                == replacementStableIdentity,
              let refreshToken = getRefreshToken(),
              !refreshToken.isEmpty,
              let frontToken = getFrontToken(),
              !frontToken.isEmpty else {
            throw RowndError("Email verification did not establish a replacement session")
        }
        let syncResult = try await syncReplacementState(
            replacementAccessToken,
            previousAccessToken
        )
        if syncResult == .profileUnavailable {
            await scheduleProfileRetry(replacementStableIdentity)
        }
        return (result.0, response)
    }

    let webConfiguration = WKWebViewConfiguration()
    let userController = WKUserContentController()
    lazy var webView: WKWebView = WKWebView(frame: .zero, configuration: webConfiguration)

    var url: URL?
    var hubViewController: HubViewProtocol?
    var jsFunctionArgsAsJson: String = "{}"
    private var navigationGeneration = 0
    private var authenticationGeneration = 0
    private var isInvalidated = false
    private var nativeEmailVerificationRequestId: String?
    private var nativeEmailVerificationTask: Task<Void, Never>?
    private(set) var nativeEmailVerificationOwnsSessionReplacement = false

    init() {
        super.init(nibName: nil, bundle: nil)

        setup()
    }

    required init?(coder: NSCoder) {
        super.init(nibName: nil, bundle: nil)
        setup()
    }

    private func setup() {
        userController.addUserScript(WKUserScript(
            source: "window.__rowndNativeEmailVerificationBridge = true;",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        userController.add(self, name: "rowndIosSDK")
        webConfiguration.userContentController = userController

        // Request mobile view
        let pref = WKWebpagePreferences.init()
        pref.preferredContentMode = .mobile
        webConfiguration.defaultWebpagePreferences = pref

        webView.customUserAgent = Constants.DEFAULT_WEB_USER_AGENT
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.scrollView.isScrollEnabled = false
        webView.isOpaque = false
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }
    }

    func setUrl(url: URL) {
        guard !isInvalidated else { return }
        self.url = url
        guard isViewLoaded else { return }

        let shouldReload = webView.url == url
        self.startLoading(force: shouldReload)
    }

    private func startLoading(force: Bool = false) {
        guard !isInvalidated, let url = self.url else { return }

        if webView.isLoading {
            guard force || webView.url != url else { return }
            webView.stopLoading()
        }

        let hubRequest = Self.hubRequest(url: url)
        logger.debug("Loading Hub URL in webview: \(Redact.urlForLogging(url))")
        webView.load(hubRequest)
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
    }

    public override func loadView() {
        webView.backgroundColor = UIColor.clear
        webView.scrollView.backgroundColor = UIColor.clear
        webView.hack_removeInputAccessory()
        webView.alpha = 0
        self.modalPresentationStyle = .pageSheet
        view = webView
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        startLoading()
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        invalidateNativeEmailVerificationRequests()
    }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        invalidateNativeEmailVerificationRequests()
        // Break the handler/owner cycles and retire the page's in-memory session.
        userController.removeScriptMessageHandler(forName: "rowndIosSDK")
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.loadHTMLString("", baseURL: nil)
        hubViewController = nil
    }
}

extension HubWebViewController: WKScriptMessageHandler, WKNavigationDelegate {
    private func evaluateJavaScript(code: String, webView: WKWebView) {
        guard !isInvalidated else { return }
        let wrappedJs = """
            if (typeof rownd !== 'undefined') {
                \(code)
            } else if (typeof window !== 'undefined' && Array.isArray(window._rphConfig)) {
                window._rphConfig.push(['onLoaded', () => {
                    \(code)
                }]);
            }
        """

        logger.trace("Evaluating Hub script")

        webView.evaluateJavaScript(wrappedJs) { (result, error) in
            if error == nil {
                logger.trace("JavaScript evaluation finished with result: \(String(describing: result))")
            } else {
                logger.error("Hub JavaScript evaluation failed: \(String(describing: error))")
            }
        }
    }

    func invalidateNativeEmailVerificationRequests() {
        navigationGeneration &+= 1
        nativeEmailVerificationTask?.cancel()
        nativeEmailVerificationTask = nil
        nativeEmailVerificationRequestId = nil
        nativeEmailVerificationOwnsSessionReplacement = false
    }

    private func verifyEmail(requestId: String, requestedURL: URL) {
        let requestedNavigationGeneration = navigationGeneration
        nativeEmailVerificationTask?.cancel()
        nativeEmailVerificationRequestId = requestId

        guard let parameters = claimNativeEmailVerificationOwnership(for: requestedURL) else {
            sendNativeEmailVerificationResponse(
                requestId: requestId,
                requestedURL: requestedURL,
                requestedNavigationGeneration: requestedNavigationGeneration,
                error: "Invalid email verification request"
            )
            return
        }

        nativeEmailVerificationTask = Task { [weak self] in
            do {
                let request = try Self.nativeEmailVerificationRequest(
                    parameters: parameters,
                    apiDomain: Rownd.config.supertokens.apiDomain,
                    apiBasePath: Rownd.config.supertokens.apiBasePath
                )
                _ = try await Self.performNativeEmailVerification(
                    request: request,
                    session: Self.nativeEmailVerificationSession()
                )
                guard !Task.isCancelled else { return }
                self?.sendNativeEmailVerificationResponse(
                    requestId: requestId,
                    requestedURL: requestedURL,
                    requestedNavigationGeneration: requestedNavigationGeneration,
                    status: "OK"
                )
            } catch {
                guard !Task.isCancelled else { return }
                logger.warning("Native email verification failed: \(String(describing: error))")
                self?.sendNativeEmailVerificationResponse(
                    requestId: requestId,
                    requestedURL: requestedURL,
                    requestedNavigationGeneration: requestedNavigationGeneration,
                    error: "Email verification failed"
                )
            }
        }
    }

    func claimNativeEmailVerificationOwnership(
        for requestedURL: URL
    ) -> NativeEmailVerificationParameters? {
        guard let parameters = Self.nativeEmailVerificationParameters(
            on: hubViewController?.targetPage,
            url: requestedURL,
            trustedApiDomain: Rownd.config.supertokens.apiDomain,
            trustedApiBasePath: Rownd.config.supertokens.apiBasePath
        ) else {
            return nil
        }
        nativeEmailVerificationOwnsSessionReplacement = true
        return parameters
    }

    @MainActor private func sendNativeEmailVerificationResponse(
        requestId: String,
        requestedURL: URL,
        requestedNavigationGeneration: Int,
        status: String? = nil,
        error: String? = nil
    ) {
        guard nativeEmailVerificationRequestId == requestId,
              Self.canDeliverNativeEmailVerificationResponse(
                on: hubViewController?.targetPage,
                requestedURL: requestedURL,
                currentURL: webView.url,
                requestedNavigationGeneration: requestedNavigationGeneration,
                currentNavigationGeneration: navigationGeneration,
                baseURL: Rownd.config.baseUrl
              ),
              let script = Self.nativeEmailVerificationEventScript(
                requestId: requestId,
                expectedURL: requestedURL,
                status: status,
                error: error
              ) else {
            return
        }
        evaluateJavaScript(code: script, webView: webView)
        nativeEmailVerificationTask = nil
        nativeEmailVerificationRequestId = nil
    }

    private func handleMailToUrl() {
        let gmailUrl = URL(string: "googlegmail://")
        if let gmailUrl = gmailUrl, UIApplication.shared.canOpenURL(gmailUrl) {
            UIApplication.shared.open(gmailUrl, options: [:], completionHandler: nil)
            return
        }

        let outlookUrl = URL(string: "ms-outlook://")
        if let outlookUrl = outlookUrl, UIApplication.shared.canOpenURL(outlookUrl) {
            UIApplication.shared.open(outlookUrl, options: [:], completionHandler: nil)
            return
        }

        let yahooUrl = URL(string: "ymail://")
        if let yahooUrl = yahooUrl, UIApplication.shared.canOpenURL(yahooUrl) {
            UIApplication.shared.open(yahooUrl, options: [:], completionHandler: nil)
            return
        }
        UIApplication.shared.open(URL(string: "message://")!, options: [:], completionHandler: nil)
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if let url = navigationAction.request.url,
           !Self.hasTrustedOrigin(url, baseURL: Rownd.config.baseUrl),
           !(url.scheme == "https" && url.host == "www.google.com" && url.path.hasPrefix("/recaptcha")),
           await UIApplication.shared.open(url) {
            return .cancel
        } else {
            return .allow
        }
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences, decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
            if let url = navigationAction.request.url,
               url.scheme == "mailto" {
                handleMailToUrl()
                decisionHandler(.cancel, preferences)
            } else {
                decisionHandler(.allow, preferences)
            }
    }

    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // This function is called whenever the Webview attempts to navigate to a different url
        if navigationAction.targetFrame == nil {
            let url = navigationAction.request.url
            if UIApplication.shared.canOpenURL(url!) {
                if url?.absoluteString != "mailto:" {
                    UIApplication.shared.open(url!, options: [:], completionHandler: nil)
                    return nil
                }
                handleMailToUrl()
                return nil
            }
        }
        return nil
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation) {
        // This function is called when the webview finishes navigating to the webpage.
        // We use this to send data to the webview when it's loaded.

        webViewOnLoad(webView: webView, targetPage: nil, jsFnOptions: nil)
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation) {
        invalidateNativeEmailVerificationRequests()
    }

    public func webViewOnLoad(webView: WKWebView, targetPage: HubPageSelector?, jsFnOptions: Encodable?) {
        Task { @MainActor in
            webView.isOpaque = false
            webView.backgroundColor = UIColor.clear
            webView.scrollView.backgroundColor = UIColor.clear

            guard Self.hasTrustedOrigin(webView.url, baseURL: Rownd.config.baseUrl) else {
                self.animateInContent()
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
                self.animateInContent()
            }

            self.setFeatureFlagsJS()

            if let jsFnOptions = jsFnOptions {
                do {
                    self.jsFunctionArgsAsJson = try jsFnOptions.asJsonString()
                } catch {
                    logger.error("Failed to encode JS options to pass to function: \(String(describing: error))")
                }
            }

            switch targetPage ?? self.hubViewController?.targetPage {
            case .signOut:
                self.evaluateJavaScript(code: "rownd.signOut({\"show_success\":true})", webView: webView)
            case .signIn, .unknown:
                self.evaluateJavaScript(code: "rownd.requestSignIn(\(self.jsFunctionArgsAsJson))", webView: webView)
            case .qrCode:
                self.evaluateJavaScript(code: "rownd.generateQrCode(\(self.jsFunctionArgsAsJson))", webView: webView)
            case .manageAccount:
                self.evaluateJavaScript(code: "rownd.user.manageAccount()", webView: webView)
            case .deepLink:
                break
            case .none:
                return
            }
        }
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation, withError error: Error) {
        handleProvisionalNavigationFailure(error, in: webView)
    }

    func handleProvisionalNavigationFailure(_ error: Error, in webView: WKWebView) {
        guard let failure = Self.hubLoadFailure(error: error, configuredURL: url) else { return }

        logger.error("Hub load failed: host=\(failure.host) error_domain=\(failure.errorDomain) error_code=\(failure.errorCode)")
        RowndEventEmitter.emit(failure.event)

        let store = Context.currentContext.store
        webView.loadHTMLString(
            NoInternetHTML(
                appConfig: store.state.appConfig,
                host: failure.host,
                errorCode: failure.errorCode
            ),
            baseURL: Self.offlinePageURL
        )
    }

    private func setFeatureFlagsJS() {
        let frameworkFeaturesString = String(describing: getFrameworkFeatures())
        let code = """
            if (typeof rownd !== 'undefined' && rownd.setSessionStorage) {
                rownd.setSessionStorage("rph_feature_flags", `\(frameworkFeaturesString)`)
            }
        """
        evaluateJavaScript(code: code, webView: webView)
    }

    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let permit = SuperTokensSessionBridge.captureAuthOperationPermit()
        guard !isInvalidated, !Rownd.isSigningOut else { return }
        // This function handles the events coming from javascript. We'll configure the javascript side of this later.
        // We can access properties through the message body, like this:
        guard let response = message.body as? String else { return }

        logger.trace("Received message from hub: \(Redact.redactSensitiveKeys(in: response))")

        let store = Context.currentContext.store

        do {
            let hubMessage = try RowndHubInteropMessage.fromJson(message: response)

            let canHandleMessage = hubMessage.type == .tryAgain
                ? Self.canHandleOfflineRetryMessage(message, webView: webView)
                : Self.canHandleHubMessage(message, webView: webView)
            if !canHandleMessage {
                logger.warning("Ignoring Hub message outside the trusted main frame")
                return
            }

            logger.debug("Received message from hub with type: \(String(describing: hubMessage.type))")

            switch hubMessage.type {
            case .authentication:
                guard case .authentication(let authMessage) = hubMessage.payload else { return }
                let targetPage = hubViewController?.targetPage
                guard Self.canHandleAuthentication(
                    on: targetPage,
                    nativeEmailVerificationOwnsSessionReplacement: nativeEmailVerificationOwnsSessionReplacement
                ) else {
                    logger.debug("Ignoring Hub authentication message for targetPage=\(String(describing: targetPage)) native_email_verification_owns_session_replacement=\(self.nativeEmailVerificationOwnsSessionReplacement)")
                    return
                }
                logger.debug("Handling Hub authentication message: targetPage=\(String(describing: targetPage)) user_type=\(authMessage.userType ?? "nil") app_variant_user_type=\(authMessage.appVariantUserType ?? "nil")")
                let initialJsFunctionArgsAsJson = self.jsFunctionArgsAsJson
                self.authenticationGeneration &+= 1
                let authenticationNavigationGeneration = self.navigationGeneration
                let authenticationGeneration = self.authenticationGeneration

                Task.detached(priority: .userInitiated) { [weak self] in
                    let sessionAdopted = SuperTokensSessionBridge.bootstrapSession(
                        accessToken: authMessage.accessToken,
                        refreshToken: authMessage.refreshToken,
                        frontToken: authMessage.frontToken,
                        antiCSRF: authMessage.antiCSRF,
                        permit: permit
                    )
                    await Self.completeAuthenticationAfterAdoption(
                        succeeded: sessionAdopted,
                        syncAuthState: {
                            await SuperTokensSessionBridge.syncRowndAuthStateFromSuperTokens(
                                afterTokenRead: {},
                                commitIf: { SuperTokensSessionBridge.isAuthOperationPermitValid(permit) }
                            )
                        },
                        syncFailure: { [weak self] in
                            await self?.showAuthenticationSyncFailure(
                                navigationGeneration: authenticationNavigationGeneration,
                                authenticationGeneration: authenticationGeneration
                            )
                        },
                        completion: {
                            await Self.completeAuthentication(
                                store: store,
                                initialJsFunctionArgsAsJson: initialJsFunctionArgsAsJson,
                                currentJsFunctionArgsAsJson: { [weak self] in self?.jsFunctionArgsAsJson },
                                hideHub: { [weak self] completion in
                                    guard let hubViewController = self?.hubViewController else {
                                        completion()
                                        return
                                    }
                                    hubViewController.hide(completion: completion)
                                },
                                eventData: authMessage.signInCompletedEventData,
                                shouldComplete: { SuperTokensSessionBridge.isAuthOperationPermitValid(permit) }
                            )
                        }
                    )
                }
            case .closeHubViewController:
                DispatchQueue.main.async {
                    self.hubViewController?.hide()
                }
            case .userDataUpdate:
                guard case .userDataUpdate(let userDataMessage) = hubMessage.payload else { return }
                guard hubViewController?.targetPage == .manageAccount else { return }
                DispatchQueue.main.async {
                    store
                        .dispatch(
                            SetUserState(payload: userDataMessage.toUserState())
                        )
                }

            case .triggerSignInWithApple:
                var signInWithAppleMessage: MessagePayload.TriggerSignInWithAppleMessage?
                if case .triggerSignInWithApple(let message) = hubMessage.payload {
                    signInWithAppleMessage = message
                }
                //                self.hubViewController?.hide()
                Rownd.requestSignIn(
                    with: .appleId,
                    signInOptions: RowndSignInOptions(
                        intent: signInWithAppleMessage?.intent
                    ),
                    initiatedByHub: true
                )

            case .triggerSignInWithGoogle:
                var signInWithGoogleMessage: MessagePayload.TriggerSignInWithGoogleMessage?
                if case .triggerSignInWithGoogle(let message) = hubMessage.payload {
                    signInWithGoogleMessage = message
                }
                Rownd.requestSignIn(with: RowndSignInHint.googleId, signInOptions: RowndSignInOptions(intent: signInWithGoogleMessage?.intent, hint: signInWithGoogleMessage?.hint), initiatedByHub: true)

            case .signOut:
                // Occasionally, the hub may send a sign-out message due to expired token
                // or possible race condition. This check prevents accidental sign-outs
                // from occurring
                var signOutMessage: MessagePayload.SignOutMessage?
                if case .signOut(let message) = hubMessage.payload {
                    signOutMessage = message
                }

                if hubViewController?.targetPage != .signOut &&
                    signOutMessage?.wasUserInitiated != true {
                    return;
                }

                Rownd.signOut()
            case .tryAgain:
                startLoading()
            case .hubLoaded:
                self.animateInContent()

            case .hubResize:
                guard case .hubResize(let hubResizeMessage) = hubMessage.payload else { return }
                if let doubleValue = Double(hubResizeMessage.height ?? "") {
                    let cgFloatValue = CGFloat(doubleValue)
                    self.hubViewController?.updateBottomSheetHeight(cgFloatValue)
                } else {
                    logger.error("Invalid string format for Hub Resize.")
                }

            case .canTouchBackgroundToDismiss:
                guard case .canTouchBackgroundToDismiss(let canDismissMessage) = hubMessage.payload else { return }
                if canDismissMessage.enable == "false" {
                    self.hubViewController?.canTouchDimmingBackgroundToDismiss(false)
                    return
                }
                self.hubViewController?.canTouchDimmingBackgroundToDismiss(true)
                break
            case .event:
                guard case .event(let eventMessage) = hubMessage.payload else { return }
                let targetPage = self.hubViewController?.targetPage
                logger.debug("Received Hub event message: event=\(eventMessage.event.rawValue) targetPage=\(String(describing: targetPage))")
                // Authentication completion is emitted after native session adoption and
                // Hub dismissal. Forwarding the Hub's duplicate event can release it as
                // soon as the token becomes valid, while the Hub is still presented.
                guard Self.shouldForwardHubEvent(eventMessage, on: targetPage) else { return }
                logger.debug("Forwarding Hub event message: event=\(eventMessage.event.rawValue)")
                RowndEventEmitter.emit(eventMessage)
                break
            case .unknown:
                break
            case .authChallengeInitiated:
                guard case .authChallengeInitiated(let authChallengeMessage) = hubMessage.payload else { return }
                DispatchQueue.main.async {
                    var newAuthState = Context.currentContext.store.state.auth
                    newAuthState.challengeId = authChallengeMessage.challengeId
                    newAuthState.userIdentifier = authChallengeMessage.userIdentifier
                    Context.currentContext.store.dispatch(
                        SetAuthState(payload: newAuthState)
                    )
                }
                break
            case .authChallengeCleared:
                DispatchQueue.main.async {
                    var newAuthState = Context.currentContext.store.state.auth
                    newAuthState.challengeId = nil
                    newAuthState.userIdentifier = nil

                    Context.currentContext.store.dispatch(
                        SetAuthState(payload: newAuthState)
                    )
                }
                break;
            case .verifyEmail:
                guard case .verifyEmail(let request) = hubMessage.payload,
                      !request.requestId.isEmpty,
                      message.webView === webView,
                      message.frameInfo.isMainFrame,
                      Self.hasTrustedSecurityOrigin(
                        message.frameInfo.securityOrigin,
                        baseURL: Rownd.config.baseUrl
                      ),
                      let requestedURL = message.frameInfo.request.url,
                      requestedURL == webView.url,
                      hubViewController?.targetPage == .deepLink,
                      requestedURL.path == "/account/verify-email" else {
                    logger.warning("Ignoring unauthorized native email-verification request")
                    return
                }
                verifyEmail(requestId: request.requestId, requestedURL: requestedURL)
            }
        } catch {
            logger.debug("Failed to decode incoming interop message: \(String(describing: error))")
        }
    }

    private func animateInContent() {
        UIView.animate(withDuration: 1.0) {
            self.webView.alpha = 1.0
            self.hubViewController?.setLoading(false)
        }
    }
}
