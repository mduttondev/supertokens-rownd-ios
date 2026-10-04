
# Testing the Rownd SDK

## Running tests

Run the tests by changing the target to `RowndTests` or running individual test suites and functions within their respective files.

### Integration and E2E tests

The normal E2E suite requires Node.js 22 or newer, Xcode 26.0.1, Docker, an `iPhone 17` simulator, and a sibling `../supertokens-rownd-hub` checkout. CI uses Hub commit `2146e7ad6f67473d7d5aadab2f94cc5373c5ff0b`; use that revision when reproducing release failures. Install dependencies in both repositories, then run:

```sh
npm ci
npm ci --prefix ../supertokens-rownd-hub
npm run test:e2e
```

Run the same package and unit tests as the PR check with `npm run test:pr`. Run the complete release suite with `npm run test:all`.

Run `npm run test:cocoapods` to install the local pod into generated static-library, static-framework, and dynamic-framework consumers and exercise the vendored bottom sheet on an iOS simulator. Set `COCOAPODS_RUNTIME_DESTINATION` to use a simulator other than `iPhone 17`. Set `KEEP_COCOAPODS_RUNTIME_FIXTURE=1` to retain each consumer under `$TMPDIR/rownd-cocoapods-runtime/<linkage>` for debugging.

The E2E runner builds and starts the Hub automatically. Set `IOS_LOCAL_HUB_REPO` to use a different checkout path or `E2E_HUB_PORT` to change its port.

The default run executes the dedicated `RowndIntegration` package scheme, then builds the `RowndE2E` example workspace scheme once for hosted example, standard UI, and Safari phases using `test-without-building`. All four phases share one Hub/backend lifetime, with backend resets between phases and native/WebKit state reset by each UI test. Each phase gets a unique xcresult under `IOS_E2E_UI_RESULTS_DIR` (default: `$TMPDIR/ios-e2e-results`). Build products stay local under `IOS_E2E_DERIVED_DATA` (default: `$TMPDIR/ios-e2e-derived-data`, separate `integration` and `example` subdirectories); they are rebuilt before each run and never uploaded to CI caches. The separate package/unit jobs retain `RowndTests`, `AnyCodableTests`, and `GzipTests` coverage.

The package and example workspaces intentionally keep their existing lockfiles: they currently select different Lottie, ReSwift, GoogleSignIn, and transitive dependency versions. Sharing their compiled SDK would silently change integration coverage. Only example/unit/UI/Safari builds are reused; a common DerivedData path cannot make differing dependency graphs interchangeable.

The default runner resolves both simulator destinations to UDIDs before building. `name=...,OS=...` honors the full runtime version, including patch versions; omitted OS or `OS=latest` selects the newest available matching runtime. Same-name devices on the same runtime require an explicit `id=...`. Xcode and simulator boot commands then use the same resolved device, including for the Safari override.

The main UI script waits for `iPhone 17` to finish booting before Xcode installs its test runner. Earlier Xcode stages can shut the simulator down; installing the runner during SpringBoard startup can leave a stale installation placeholder and fail launch with `Busy` / `Application failed preflight checks`.

Run `npm run test:e2e:refresh` for the session-expiry regression suite. It exercises real Core-issued access tokens, automatic refresh, a temporary refresh HTTP 503, and a revoked session. Two XCUITests terminate the example app until the actual token expiration plus a one-second boundary margin, then verify cold-launch refresh and outage recovery using persisted native credentials. The fixture retains its 90-second lifetime, above the SDK's 60-second proactive-refresh margin. Allow several minutes for the suite.

The harness uses a named Core app so expiry fixtures can temporarily change access-token validity through the Core API. Refresh-token validity stays at `144000` **minutes** (100 days); access-token validity returns to `3600` **seconds** before refresh. See [the investigation](../docs/session-refresh-investigation.md) for the failure mechanism and reproduction details.

To run only a selected UI script while still starting its Hub and backend dependencies, set `IOS_E2E_ONLY_UI=1` together with `IOS_E2E_UI_SCRIPT`.

This starts the local Hub, SuperTokens Core, and backend harness before running the native integration suite, hosted example test, and rendered XCUITests. The UI suite covers Hub OTP and magic-link authentication through the WKWebView bridge, restored-session sign-out, relaunch reconciliation of persisted legacy Rownd state against an existing SuperTokens session without remigration, and pending-email verification. Run UI and Safari tests through the E2E runner so it can manage their dependencies and cleanup.

The default runner includes Safari as a separate phase after standard UI tests. To run only the Safari custom-scheme handoff:

```sh
IOS_E2E_ONLY_UI=1 IOS_E2E_UI_SCRIPT=test:e2e:safari-handoff npm run test:e2e
```

Use a simulator with only one app registered for `rowndsupertokens://`. Older example installations such as `io.rownd.ios-native` can claim the same scheme as `com.bogdancarpusor.rowndexample`, causing Safari to open the wrong app. Set `IOS_E2E_SAFARI_DESTINATION` to select an isolated simulator without changing existing devices:

```sh
IOS_E2E_SAFARI_DESTINATION='platform=iOS Simulator,id=<simulator-uuid>' \
  IOS_E2E_ONLY_UI=1 IOS_E2E_UI_SCRIPT=test:e2e:safari-handoff npm run test:e2e
```

The `test:e2e:local-plugin` and `test:e2e:safari-handoff:local-plugin` commands additionally require a plugin checkout at `../../../supertokens-plugins/packages/rownd-nodejs` with its dependencies installed.

The test opens the generated verification link in Safari, confirms the browser-to-app handoff, and verifies replacement-session adoption and the persisted email. The normal suite also verifies custom-scheme delivery with XCTest system dispatch. The Android browser test similarly verifies Chrome-to-app dispatch separately from native verification and replacement-session adoption.

The native-email compatibility workflow runs its stale-authentication and Safari cases together via `test:e2e:ui:native-email-verification`, sharing one build and backend lifetime while each test resets app/backend state.

### CI download caches

- Docker tools: only the three pinned download archives, keyed by runner OS/architecture and the setup script. Checksums are verified even on hits; executables and VM disks are excluded.
- Swift: bare repositories and binary artifacts only, keyed by OS/architecture, Xcode, workspace, package manifest, and lockfiles. Exact hits skip remote package updates; related lockfile revisions can reuse downloads but still update repositories. Uploads stop above 768 MiB; checkouts and DerivedData are excluded. `IOS_SWIFTPM_CACHE` supplies the resolver/build download directory.
- Release and native-email verification CI prefetch Docker images after Docker setup and before simulator boot using `bash .github/scripts/prefetch-e2e-images.sh`. Sequential pulls have a separate 15-minute step limit: cold Postgres/Core downloads took roughly eight minutes and exhausted the backend's 600-second startup budget when pulled on demand. Prefetch honors `E2E_CORE_IMAGE` (tag or digest), defaults to the harness's Core image, and includes `postgres:14` and the locked Testcontainers Ryuk image. Locally available images are reused. Keep these defaults aligned when updating the harness or Testcontainers. Image archiving remains disabled: a cold Intel CI run exhausted the setup deadline creating an archive and never uploaded it.

The prefetch limit is part of the existing overall job budget (75 minutes for release E2E, 60 for native-email verification), not additional time beyond it. Backend/container readiness deadlines remain 600/180 seconds. Local harness runs still pull missing images on demand; run the prefetch script first to separate downloads from startup.

CI simulator provisioning prefers an available iPhone 17 runtime matching the SDK. After a failed readiness check, it shuts down only the selected device and creates a fresh `Rownd CI fallback` device on the newest supported alternate runtime (or the same runtime if no alternate exists). It exports only the UDID that passes readiness. The workflow enforces a ten-minute provisioning limit; discovery, diagnostics, and cleanup can reduce the time available for the second attempt. No devices are erased or deleted and CoreSimulator is not restarted globally.

Compare GitHub cache restore/save and resolver durations against cold download time before increasing these budgets. Local measurements cannot establish GitHub transfer cost; avoid expanding these caches to build products or entire tool/VM directories.

## Writing tests

We have previously written tests using the XCTesting framework, but have switched to the newer and better [Swift Testing](https://developer.apple.com/documentation/testing/) library. Write new tests using this library.

## Mocking network requests

[Mocker](https://github.com/WeTransfer/Mocker) allows us to mock network requests and responses. See examples in the Tests/RowndTests/AuthTests.swift
