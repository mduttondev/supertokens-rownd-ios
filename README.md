# Rownd SDK for iOS

The Rownd SDK for iOS provides authentication, account and user profile management, deep linking, and more for native iPhone, iPad, and even macOS applications.

Using the Rownd platform, you can easily bring the same authentication that's on your website to your mobile apps. Or if you only authenticate users on your mobile apps, you can streamline authentication using Rownd's passwordless sign-in links, one-time codes, or both, delivered by email or SMS.

Once a user is authenticated, you can retrieve and update their profile information on the fly using native APIs. Leverage Rownd's pre-built mobile app components to give users profile management tools.

## Installation

### Swift Package Manager

In Xcode, select your project file, select the main target, then scroll down to the "frameworks" section to add a package dependency to your project. See the [official documentation](https://developer.apple.com/documentation/xcode/adding-package-dependencies-to-your-app) for specific steps.

Enter this as the package repository url:

```
https://github.com/supertokens/supertokens-rownd-ios.git
```

Select the `Rownd` package product and add it to your app target.

### CocoaPods

Add the pod to your `Podfile`:

```ruby
pod 'RowndSupertokens'
```

Then run:

```sh
pod install
```

The CocoaPods package exposes the same Swift module, so app code should still use `import Rownd`.

## Usage

### Integrating the Rownd SDK

The SuperTokens-backed Rownd SDK requires both Rownd and SuperTokens configuration during application launch. In your `AppDelegate`, set the Rownd runtime config first, then call `Rownd.configure()`:

```swift
import Rownd
import UIKit

func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
    let apiDomain = "https://api.example.com"
    let apiBasePath = "/auth"
    Rownd.config.baseUrl = "https://supertokens-hub.sandboxx.us"

    Task {
        await Rownd.configure(
            launchOptions: launchOptions,
            appKey: "YOUR_ROWND_APP_KEY",
            supertokens: RowndSuperTokensConfig(
                appName: "Your App",
                apiDomain: apiDomain,
                apiBasePath: apiBasePath
            )
        )
    }

    return true
}
```

Configuration notes:

- `Rownd.config.baseUrl` should be the Rownd Hub base URL used by the SDK. For example, use `https://supertokens-hub.sandboxx.us` for a custom Hub domain, or `https://rownd-hub.supertokens.com` for the default domain. Set it before calling `Rownd.configure()`.
- `Rownd.config.deepLinkScheme` should be the custom URL scheme your app registers and the SDK accepts, for example `rowndsupertokens` or your app-specific scheme.
- `RowndSuperTokensConfig.apiDomain` should point at the backend that hosts your SuperTokens plugin routes. `Rownd.configure()` also assigns this value to `Rownd.config.apiUrl`.
- `RowndSuperTokensConfig.apiBasePath` must match your backend SuperTokens API base path, usually `/auth`.
- `appVariantId` is optional. Set it when this app belongs to a Rownd app variant so Hub and native Google sign-in include it in authentication requests.
- `Rownd.config.clientDomain` optionally selects a key in the backend Rownd plugin's `clientDomains` map for Hub-generated authentication links. Set it before `Rownd.configure()`. This is a key such as `"mobile_io"`, not a URL. When omitted, mobile Hub requests use the backend's `mobile` entry.
- Set `RowndSuperTokensConfig.clearSessionOnNewInstallation` to `true` to clear retained SuperTokens credentials when the installation marker is missing. In the containing app, this also removes all WebKit data types for the configured `Rownd.config.baseUrl` host. For SuperTokens-managed Hub domains, WebKit may group this data under a managed parent-domain record, in which case data for sibling subdomains in that record is also removed. Custom Hub domains are matched exactly. The setting defaults to `false`, and marker tracking is still established when cleanup is disabled.
- Enabling cleanup in the first marker-aware release also clears existing SuperTokens sessions once. To avoid that adoption-time reset, first release with the default disabled, then enable cleanup after the installed population has established markers. Users who skip the marker-establishing release are still reset when they first launch a cleanup-enabled release.
- Installation cleanup never removes legacy `RowndState`, allowing existing Rownd sessions to migrate to SuperTokens without requiring users to sign in again. SuperTokens-derived compatibility auth is cleared with the native session.
- `Rownd.configure()` reconciles cached Rownd state with the native SuperTokens session before returning. After a session replacement, authentication may be available while profile data is temporarily empty; the SDK retries profile hydration while the app is active.

When sharing sessions with app extensions, configure the same `Rownd.config.appGroupPrefix`, `keychainAccessGroup`, API domain, base path, and installation cleanup setting in the containing app and every extension. The app group shares the installation marker while the Keychain access group shares the credentials. App offloading preserves app data and therefore preserves the session. Deleting the app removes its local marker; retained SuperTokens credentials are cleared on the next containing-app launch when cleanup is enabled.

#### Migrating mobile link domains

Keep the backend plugin's `clientDomains.mobile` set to the existing domain for older app versions, and add a named entry for the new domain:

```ts
clientDomains: {
  mobile: "https://waypoints.rownd-hub.supertokens.com",
  mobile_io: "https://waypoints.rownd-hub.supertokens.io",
}
```

Preserve other client-domain entries. If using the plugin's `resolveConfig`, include the new entry in its returned `clientDomains` too.

New app versions can select the new entry before initialization:

```swift
Rownd.config.baseUrl = "https://rownd-hub.supertokens.io"
Rownd.config.clientDomain = "mobile_io"
Rownd.config.signInLinkPattern = ".*\\.rownd-hub\\.supertokens\\.(com|io)$"
```

Include both link hosts in Associated Domains and serve valid AASA files on both hosts during the transition. Allow the applicable old and new Hub/link origins in backend CORS. `baseUrl` selects the embedded Hub; `clientDomain` independently selects generated link destinations. Keep the existing backend `apiDomain` and `apiBasePath`.

#### Handling deep links and universal links

There are two deep-link values to configure:

- Deep link scheme: the custom URL scheme your app registers and the SDK accepts, for example `rowndsupertokens`.
- Deep link: the verified Universal Link on your custom Hub subdomain, for example `https://your-hub-subdomain.rownd-hub.supertokens.com`.

The Hub can derive the custom scheme fallback from your custom Hub subdomain, so make sure your app's custom URL scheme matches the scheme the Hub will generate.

Add an Associated Domains entitlement for the Rownd hub host used by your app:

```xml
<key>com.apple.developer.associated-domains</key>
<array>
    <string>applinks:your-subdomain.rownd-hub.supertokens.com</string>
</array>
```

Register the custom URL scheme in your app's `Info.plist`:

```xml
<key>CFBundleURLTypes</key>
<array>
    <dict>
        <key>CFBundleURLSchemes</key>
        <array>
            <string>rowndsupertokens</string>
        </array>
    </dict>
</array>
```

The universal-link domain must also serve a valid Apple App Site Association file that includes your app's Team ID and bundle ID. Without that server-side AASA entry, iOS will open the link in the browser instead of delivering it to your app.

Finally, forward custom URL scheme links and universal links to Rownd:

```swift
func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
    Rownd.handleSmartLink(url: url)
}

func application(
    _ application: UIApplication,
    continue userActivity: NSUserActivity,
    restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void
) -> Bool {
    guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
          let url = userActivity.webpageURL else {
        return false
    }

    return Rownd.handleSmartLink(url: url)
}
```

Links delivered while `Rownd.configure()` is still running are queued and handled after configuration completes. `handleSmartLink` returns `false` for URLs that do not match a supported Rownd sign-in or email-verification route, allowing the app to route them elsewhere.

If you configure values through Xcode scheme environment variables, remember those variables are only present when launching from Xcode. Universal links that launch an already installed app will use values from code defaults, build settings, or `Info.plist`.

After initialization, your app will typically call `Rownd.requestSignIn()` at some point, if the user is not already authenticated. This will display the Rownd interface for authenticating the user. Once they complete the sign-in process, an access token and the user's profile information will be available to your app.

#### Legacy session migration

`await Rownd.configure(...)` finishes legacy migration before returning. If a migration request fails, the SDK clears only that attempt's legacy credentials and cached profile, persists normal signed-out state, and emits the normal sign-out event. This includes HTTP errors, incomplete or invalid session responses, failed native adoption, and exhausted network/timeout retries. HTTP 409 succeeds only when a usable native SuperTokens session exists. A concurrent usable native session is preserved and synchronized; newer legacy credentials are untouched. The completed attempt's `auth.isLoading` is false. Apps with their own startup loader should finish it when configuration returns and use the usual signed-out flow, including `Rownd.requestSignIn()`.

Migration network errors (`URLError`, including timeout) receive one immediate retry: at most two requests per attempt. HTTP and response-validation failures are not retried. Once failed migration credentials are cleared, a later launch does not retry them. Before a migration request is sent, transient legacy-refresh failures and request configuration/construction errors retain credentials; existing invalid-refresh-token HTTP 400/401 handling still signs out. Rotated legacy credentials are persisted before migration and used for its bounded retry, then cleared if that migration fails. Migration transport bypasses response interceptors, and revocable native adoption ownership prevents stale responses from installing or clearing a newer session.

### Handling authentication

Rownd leverages an observeable architecture to expose data to your app. This means that as the Rownd state changes, an app can dynamically update without complicated logic. For example, a view can display different information based on the user's authentication status.

Here's an example SwiftUI view that displays different messages depending on the user's authenticated status:

```swift
import SwiftUI
import Rownd

struct MyView: View {
    @StateObject var authState = Rownd.getInstance().state().subscribe { $0.auth }
    @StateObject var user = Rownd.getInstance().state().subscribe { $0.user.data }

    var body: some View {
        VStack {
            HStack {
                Button(action: {
                    if authState.current.isAuthenticated {
                        Rownd.signOut()
                    } else {
                        Rownd.requestSignIn()
                    }
                },
                       label: {
                    Text(!authState.current.isAuthenticated ? "Sign in" : "Sign out")
                })
                Spacer()
                if authState.current.isAuthenticated {
                    Button(action: {

                    }, label: {
                        Text(user.current?["first_name"]?.value as? String)
                    })
                }
            }
            .padding(.horizontal)
        }
    }
}

struct MyView_Previews: PreviewProvider {
    static var previews: some View {
        MyView()
    }
}
```

#### Example usage outside of SwiftUI

```swift
class Auth {
    private var authState = Rownd.getInstance().state().subscribe { $0.auth }
    private var cancellables = Set<AnyCancellable>()
    init() {
        self.authState.$current
            .sink { [weak self] state in
                // Called whenever the auth state changes
                guard !state.isLoading else { return }

                guard state.auth.isAuthenticated else {
                    return
                }

                // User is authenticated. Change app state accordingly.
                // This is also a good time to get the latest access token.
                let accessToken = await Rownd.getAccessToken()
            }
            .store(in: &cancellables)
    }
}
```

You can subscribe to any state object that Rownd supports. Here's a list of available states and their structures:

#### .auth

```swift
public struct AuthState {
    public var accessToken: String?     // Current, valid access token for the user (valid for one hour)
    public var isAuthenticated: Bool    // Whether the user is currently authenticated
    public var isAccessTokenValid: Bool // Whether the current access token is valid
    public var isVerifiedUser: Bool?    // Whether the current user has verified at least one identifier (e.g., email)
    public var hasPreviouslySignedIn: Bool    // Whether the app has been previously signed in before
}
```

#### .user

```swift
public struct UserState {
    public var id: String?                           // The user's ID as known to Rownd
    public var data: Dictionary<String, AnyCodable>  // Contains key/value pairs for the current user based on your Rownd's app config
}
```

### Getting an access token

Whenever your app needs to make an authenticated request to your backend, you'll need to get an access token. You can do this by calling `await Rownd.getAccessToken(throwIfMissing: true)`. If the user is not authenticated, this function will throw an `AuthenticationError.noAccessTokenPresent` error.

If there is an issue fetching the access token (e.g., during a token refresh), an `AuthenticationError.serverError` or `AuthenticationError.networkConnectionFailure` error will be thrown. Server and network failures are automatically retried before throwing an error.

If the user is signed in, but the refresh token is expired, invalidated, or has been used previously, the user will be signed out and the function will throw an `AuthenticationError.invalidRefreshToken` error.

See the [API reference](#rownd-getaccesstoken-token-string-async-string) for more information.

### Customizing the UI

While most customizations are handled via the [Rownd dashboard](https://app.rownd.io), there are a few things that have to be customized directly in the SDK.

The `RowndCustomizations` class exists to facilitate these customizations. It provides the following properties that may be subclassed or overridden.

- `sheetBackgroundColor: UIColor` (default: `light: .white`, `dark: .systemGray6`; requires subclassing) - Allows changing the background color underlaying the bottom sheet that appears when signing in, managing the user account, etc.
- `sheetCornerBorderRadius: CGFloat` (default: `25.0`) - Modifies the curvature radius of the bottom sheet corners.
- `loadingAnimation: Lottie.Animation?` (default: nil) - Use this animation instead of the system default loading spinner (i.e., `UIActivityIndicatorView` or `ProgressView`). Any animation compatible with [Lottie](https://airbnb.design/lottie/) should work, but will be scaled to fit a 1:1 aspect ratio (usually with a `CGRect` frame width/height of `100`)
- `loadingAnimationUiView: UiView?` (default: nil) - Display this UIView instead of the system default loading spinner. When using this option, you are responsible for starting the animation and ensuring that the view displays the animation vertically and horizontally centered in the view. Rownd will add and remove the view to a parent view as needed. Here's an [example implementation](/example/ios%20native/Views/CustomLoadingAnimationView.swift).

To apply customizations, we recommend subclassing the `RowndCustomizations` class. Here's an example:

```swift
class AppCustomizations : RowndCustomizations {
    override var sheetBackgroundColor: UIColor {
        return UIColor(red: 31/255, green: 37/255, blue: 80.2.7, alpha: 1.0)
    }
}

// AppDelegate.swift
import Rownd

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {

        Rownd.config.customizations = AppCustomizations()   // Apply the customizations

        Task {
            await Rownd.configure(
                launchOptions: launchOptions,
                appKey: "YOUR_ROWND_APP_KEY",
                supertokens: RowndSuperTokensConfig(
                    appName: "Your App",
                    apiDomain: "https://api.example.com",
                    apiBasePath: "/auth"
                )
            )
        }

        return true
    }
}
```

### Usage within app extensions

It's possible to access the Rownd state from within an app extension, like a widget. You'll need to include the Rownd package in the extension's dependencies and set up an app group for data sharing between the app and the extension. Without the app group, extensions will not be able to sync with your app's authentication state.

Follow these steps to configure your app and extension to work with Rownd:

1. Add an [app group](https://developer.apple.com/documentation/xcode/configuring-app-groups) entitlement and a shared [Keychain access group](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps) to both your app and any extensions that will use Rownd.
   This app group **must** be named like this: `<prefix>.io.rownd.sdk`. For example, if you work at a company with the acme.com domain, your app group might look like this: `com.acme.app.io.rownd.sdk`. Rownd will store its data in this app group. Your app should store data in a separate app group to prevent any collisions.

2. In your app's `AppDelegate` file as well as your extension's entry point, set the app group prefix you defined above via `Rownd.config.appGroupPrefix = "<prefix>"` (e.g., `Rownd.config.appGroupPrefix = "com.acme.app"`). Pass the same Keychain access group to `RowndSuperTokensConfig` in both targets.

3. In your extension, call `Rownd.configure()` prior to accessing authentication state. Here's an example:

   ```swift
    Task {
        Rownd.config.appGroupPrefix = "group.rowndexample"
        let rowndState = await Rownd.configure(
            appKey: "YOUR_ROWND_APP_KEY",
            supertokens: RowndSuperTokensConfig(
                appName: "Your App",
                apiDomain: "https://api.example.com",
                apiBasePath: "/auth",
                keychainAccessGroup: "YOUR_TEAM_ID.com.acme.app.shared"
            )
        )

        var authStatus: String = "You are not authenticated. ☹️"
        if rowndState.auth.isAuthenticated == true {
            authStatus = "You are authenticated! 😁"
        }
    }
   ```

<Note>
If you're building widgets that need access to Rownd auth state, you should listen for Rownd auth events and notify `WidgetCenter` that widgets may need updating any time the state changes. That way, they'll re-render while your app is in the foreground and will show an accurate state. Here's a simple example:
```swift
import Foundation
import Combine
import WidgetKit
import Rownd

class SomeClass {
private var authState = Rownd.getInstance().state().subscribe { $0.auth }
private var cancellables = Set<AnyCancellable>()

    init() {
        self.authState
            .$current
            .sink { [weak self] state in
                WidgetCenter.shared.reloadAllTimelines()
            }
            .store(in: &cancellables)
    }

}

````
</Note>

### Events

The Rownd SDK emits lifecycle events that you can listen to within your app. These events are primarily useful for detecting more granular aspects of a user's session (e.g., starting to sign in, completing sign-in, updated profile, etc.).

To listen to events, first create a class that conforms to the `RowndEventHandlerDelegate` protocol. It looks something like this:

```swift
import Foundation
import Rownd

class RowndEventHandler: RowndEventHandlerDelegate {
    func handleRowndEvent(_ event: RowndEvent) {
        switch event.event {
        case .signInCompleted:
            let userType = event.data?["user_type"]
            let appVariantUserType = event.data?["app_variant_user_type"]
            break

        default:
            break
        }
    }
}
````

Next, register the event handler delegate with the Rownd SDK:

```swift
Rownd.addEventHandler(RowndEventHandler())
```

Once the event handler is registered, it will receive events as they occur. The `RowndEvent` object contains the event type and any associated data. The event types are defined in the `RowndEventType` enum.

#### List of events

Here's a list of events that the Rownd SDK emits and the corresponding data that should be present in the event data dictionary. Remember to write your code defensively, as the data dictionary may be missing keys in some cases.

<table>
    <tr>
        <th>Event</th>
        <th>Type</th>
        <th>Payload</th>
    </tr>
    <tr>
        <td>User started signing in</td>
        <td>`.signInStarted`</td>
        <td>

        ```javascript
        {
            method: "google" | "apple" | "phone" | "email" | "anonymous" | etc;
        }
        ```
        </td>
    </tr>

    <tr>
        <td>User signed in successfully</td>
        <td>`.signInCompleted`</td>
        <td>

        ```javascript
        {
            method: "google" | "apple" | "phone" | "email" | "anonymous" | etc,
            user_type: "new_user" | "existing_user",
            app_variant_user_type: "new_user" | "existing_user" | optional
        }
        ```

        <p><code>method</code> is an optional string identifying the sign-in method, including <code>email</code> or <code>phone</code> for passwordless sign-in. It may be absent when the Hub cannot determine the method or an older Hub version does not provide it. Treat missing or unrecognized values as unknown; do not default to <code>email</code>.</p>

        </td>
    </tr>

    <tr>
        <td>User sign in failed</td>
        <td>`.signInFailed`</td>
        <td>

        ```javascript
        {
            reason: String | optional,
            message: String | optional,
            method: "google" | "apple" | optional
        }
        ```

        <p>For native Google and Apple sign-in, a SuperTokens refusal such as <code>SIGN_IN_UP_NOT_ALLOWED</code> sets <code>reason</code> to the server's <code>status</code> and <code>message</code> to the server's <code>reason</code>, both unchanged. Other native failures omit <code>reason</code> and describe the error in <code>message</code>.</p>

        </td>
    </tr>

    <tr>
        <td>Hub failed to load</td>
        <td>`.hubLoadFailed`</td>
        <td>

        ```javascript
        {
            host: String,
            error_domain: String,
            error_code: Number
        }
        ```

        </td>
    </tr>

</table>

### API reference

In addition to the state observable APIs, Rownd provides imperative APIs that you can call to request sign in, get and retrieve user profile information, retrieve a current access token, or encrypt user data with the user's local key.

#### Rownd.requestSignIn() -> Void

Opens the Rownd sign-in dialog for authentication.

#### Rownd.requestSignIn(RowndSignInOptions(postSignInRedirect: "https://my-domain.com")) -> Void

#### Rownd.requestSignIn(RowndSignInOptions(postSignInRedirect: "https://my-domain.com", intent: .signIn)) -> Void

Opens the Rownd sign-in dialog for authentication, as above. The SDK and Hub normally handle redirects using your configured Universal Link and custom scheme fallback. Pass `postSignInRedirect` only when you need to override the default redirect target.

#### Rownd.requestSignIn(with: RowndSignInHint) -> Void

#### Rownd.requestSignIn(with: RowndSignInHint, signInOptions: RowndSignInOptions?) -> Void

Requests a sign-in, but with a specific authentication provider (e.g., Sign in with Apple). Rownd treats this information as a hint. If the specified authentication provider is enabled within your Rownd app configuration, it will be honored. If not, Rownd will fall back to the default flow.

Supported values:

- `.appleId` - Prompt user to sign in with their Apple ID
- `.google` - Prompt user to sign in with their Google account
- `.guest` - Sign in the user anonymously as a guest.

Passkeys, Firebase connection actions, legacy Rownd smart-link auth, and public legacy token exchange are not supported by the SuperTokens-backed SDK.

#### RowndSignInOptions

Some of the `requestSignIn()` methods accept an optional `RowndSignInOptions` parameter. This class contains the following properties:

- `postSignInRedirect: String?` (not recommended) - The SDK and Hub normally handle redirects using your configured Universal Link and custom scheme fallback. Use this only when you need to override the default redirect target. If you provide a custom value, it must still resolve back to your app through a Universal Link or custom URL scheme your app handles.
- `intent: RowndSignInIntent?` - This option applies only when you have opted to split the sign-up/sign-in flow via the Rownd dashboard. Valid values are `.signIn` or `.signUp`. If you don't set this value, the user will be presented with the unified sign-in/sign-up flow.

### Rownd.signOut() -> Void

Starts local sign-out and returns immediately. This API is retained for compatibility, but it is fire-and-forget: SuperTokens may still be building or sending `/auth/signout` after this function returns.

Do not use this overload when your app clears app storage, or other local state immediately after sign-out. Clearing storage too early can remove the tokens before the sign-out request attaches its `Authorization` header.

### Rownd.signOut() async -> Void

Waits for local Rownd sign-out and SuperTokens sign-out to complete before returning. Use this overload before destructive cleanup:

```swift
await Rownd.signOut()
clearAppStorage()
```

If you cannot use Swift concurrency, use the completion overload:

```swift
Rownd.signOut { error in
    guard error == nil else {
        return
    }

    clearAppStorage()
}
```

### Rownd.signOut(scope: RowndSignoutScope) -> Void

Revokes all tokens for the specified user causing them to be signed out on all devices.

Supported values:

- `.all` - All devices

### Rownd.getAccessToken(throwIfMissing: Bool = false) async throws -> String?

Assuming a user is signed-in, returns a valid access token, refreshing the current one if needed.

By default, this function will return `nil` if an access token cannot be returned, either because the user is not signed in or because the refresh token is invalid.

If an access token cannot be returned due to a temporary condition (e.g., inaccessible network), this function will throw an `AuthenticationError` indicating the failure reason (e.g., server or network error).

You may also set `throwIfMissing` to `true` to force an error to be thrown if an access token cannot be returned. This will provide more granular reasons for the failure. The possible error cases for `AuthenticationError` are:

- `.noAccessTokenPresent` - the user is not signed in
- `.invalidRefreshToken(details: String)` - the refresh token was invalid (e.g., the token was expired, revoked, or a previous exchange failed to complete successfully). The user will be signed out.
- `.networkConnectionFailure(details: String)` - a network condition prevented the token from being refreshed, even after several retries and should be re-attempted later
- `.serverError(details: String)` - a server error occurred, or the SDK could not persist compatibility state for the current SuperTokens session; you should try again later

Example:

```swift
    do {
        let accessToken = try await Rownd.getAccessToken(throwIfMissing: true)
    } catch {
        switch error {
        case AuthenticationError.noAccessTokenPresent:
            // The user is not signed in
        case AuthenticationError.invalidRefreshToken(let details):
            // The refresh token was invalid. Request that the user sign in again.
        case AuthenticationError.networkConnectionFailure(let details),
             AuthenticationError.serverError(let details):
            // Alert the user that they should try again due to some recoverable error
            print("Server error occurred: \(details)")
        }
    }
```

#### Rownd.user.get() -> Dictionary\<String, AnyCodable>

Returns the entire user profile as a dictionary object

#### Rownd.user.get\<T>(field: String) -> T?

Returns the value of a specific field in the user's data dictionary. `"id"` is a special case that will return the user's ID, even though it's technically not in the dictionary itself.

Your application code is responsible for knowing which type the value should cast to. If the cast fails or the entry doesn't exist, a `nil` value will be returned.

#### Rownd.user.set(data: Dictionary\<String, AnyCodable>) -> void

Replaces the user's data with that contained in the dictionary. This may overwrite existing values, but must match the schema you defined within your Rownd application dashboard. Any fields that are flagged as `encrypted` will be encrypted on-device prior to storing in Rownd's platform.

Hint: use `AnyCodable.init(value)` to conform your values to the required type.

#### Rownd.user.set(field: String, value: AnyCodable) -> void

Sets a specific user profile field to the provided value, overwriting if a value already exists. If the field is flagged as `encrypted`, it will be encrypted on-device prior to storing in Rownd's platform.

Hint: use `AnyCodable.init(value)` to conform your values to the required type.

## Using Rownd with WKWebView

### Registering a WKWebView with Rownd

The `registerWebView` method enables communication between the Rownd JavaScript SDK and native Rownd iOS SDK.

#### Why Use `registerWebView`?

You should call `registerWebView()` with any web view that loads content containing the Rownd JavaScript SDK. This binding is required for certain operations like signing in with Google, where Google prohibits OAuth2 sign-in from within a web view. Once registered, the web view JavaScript SDK can send messages to the Swift code to perform sign-in with Google natively.

#### Method Signature

```swift
public static func registerWebView(_ webView: WKWebView) -> () -> Void
```

- **Parameter**: `webView` - The `WKWebView` instance you want to register with Rownd.
- **Returns**: A closure that can be called to deregister the web view when it's no longer needed.

#### Example Usage

Here's an example of how you might use `registerWebView` in your app:

```swift
import UIKit
import WebKit
import Rownd

class WebViewController: UIViewController {
    var webView: WKWebView!
    var deregisterWebView: (() -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()

        webView = WKWebView(frame: self.view.bounds)
        self.view.addSubview(webView)

        // Register the web view with Rownd
        deregisterWebView = Rownd.registerWebView(webView)

        // Load a URL that uses the Rownd JavaScript SDK
        if let url = URL(string: "https://your-web-app.com") {
            webView.load(URLRequest(url: url))
        }
    }

    deinit {
        // Deregister the web view when the view controller is deallocated
        deregisterWebView?()
    }
}
```

The example creates a `WKWebView` and registers it with Rownd. The web view loads a URL containing the Rownd JavaScript SDK. When the view controller deallocates, it calls the `deregisterWebView` closure to clean up the registration.
