# Changelog

## <small>0.2.7 (2026-10-04)</small>

* ci: allow sufficient time for Swift dependency resolution ([eb44310](https://github.com/supertokens/supertokens-rownd-ios/commit/eb44310))
* ci: isolate CocoaPods checks and diagnose E2E startup timeouts ([45f82a1](https://github.com/supertokens/supertokens-rownd-ios/commit/45f82a1))
* ci: provision iOS simulator and target its exact device ID ([89751e3](https://github.com/supertokens/supertokens-rownd-ios/commit/89751e3))
* ci: recover stuck simulators and remove costly image archiving ([34060d1](https://github.com/supertokens/supertokens-rownd-ios/commit/34060d1))
* ci: resolve diagnostics directory in step environment ([9f20323](https://github.com/supertokens/supertokens-rownd-ios/commit/9f20323))
* ci: retain UI test results and trace authentication requests ([ea7dbc9](https://github.com/supertokens/supertokens-rownd-ios/commit/ea7dbc9))
* ci: retry simulator boot and await integration request completion ([1ec5f43](https://github.com/supertokens/supertokens-rownd-ios/commit/1ec5f43))
* ci: reuse E2E builds and backend with targeted dependency caches ([2fb37fd](https://github.com/supertokens/supertokens-rownd-ios/commit/2fb37fd))
* ci: serialize expiry fixtures and capture E2E failure diagnostics ([47937ad](https://github.com/supertokens/supertokens-rownd-ios/commit/47937ad))
* ci: use prebuilt Docker tools and reserve E2E diagnostic headroom ([214c640](https://github.com/supertokens/supertokens-rownd-ios/commit/214c640))
* test: allow network-backed Apple completion time in CI ([fb56015](https://github.com/supertokens/supertokens-rownd-ios/commit/fb56015))
* test: await profile hydration retry cleanup before assertions ([af3f690](https://github.com/supertokens/supertokens-rownd-ios/commit/af3f690))
* improv: migrate legacy Rownd sessions directly with refresh tokens ([dca05c8](https://github.com/supertokens/supertokens-rownd-ios/commit/dca05c8))
* fix: preserve newer state and harden E2E container startup ([000cebf](https://github.com/supertokens/supertokens-rownd-ios/commit/000cebf))
* fix: synchronize network time with bounded NTP queries ([905eff0](https://github.com/supertokens/supertokens-rownd-ios/commit/905eff0))

## <small>0.2.6 (2026-09-29)</small>

* fix: clear legacy session when token refresh fails ([2b0087b](https://github.com/supertokens/supertokens-rownd-ios/commit/2b0087b))

## <small>0.2.5 (2026-09-28)</small>

* ci: expose Colima socket to release test harness ([95bd10b](https://github.com/supertokens/supertokens-rownd-ios/commit/95bd10b))
* fix: preserve hydrated identity during token reads and session reloads ([f73fe6c](https://github.com/supertokens/supertokens-rownd-ios/commit/f73fe6c))

## <small>0.2.4 (2026-09-23)</small>

* fix: clear .io Hub website data on sign-out ([06b0b30](https://github.com/supertokens/supertokens-rownd-ios/commit/06b0b30))

## <small>0.2.3 (2026-09-22)</small>

* fix: include Hub sign-in method in completion events ([22db78b](https://github.com/supertokens/supertokens-rownd-ios/commit/22db78b))

## <small>0.2.2 (2026-09-18)</small>

* fix: validate access token structure before decoding ([7ce7ea0](https://github.com/supertokens/supertokens-rownd-ios/commit/7ce7ea0))

## <small>0.2.1 (2026-09-17)</small>

* improv: support named mobile client domains ([e2230d4](https://github.com/supertokens/supertokens-rownd-ios/commit/e2230d4))

## 0.2.0 (2026-09-16)

* feat(offline): suggest turning off a VPN on the connection failure screen ([0425d78](https://github.com/supertokens/supertokens-rownd-ios/commit/0425d78))

## <small>0.1.16 (2026-09-11)</small>

* test: add native verification compatibility matrix ([7a59308](https://github.com/supertokens/supertokens-rownd-ios/commit/7a59308))
* test: cover native email verification ordering ([33f3329](https://github.com/supertokens/supertokens-rownd-ios/commit/33f3329))
* test: reproduce stale Hub auth after email verification ([0f73f9c](https://github.com/supertokens/supertokens-rownd-ios/commit/0f73f9c))
* test: stabilize iOS full-suite verification ([96d4d60](https://github.com/supertokens/supertokens-rownd-ios/commit/96d4d60))
* fix: clear failed legacy migrations without replacing newer sessions ([19f4e6e](https://github.com/supertokens/supertokens-rownd-ios/commit/19f4e6e))
* fix: clear Hub session on native logout ([e011174](https://github.com/supertokens/supertokens-rownd-ios/commit/e011174))
* fix: preserve iOS sessions during temporary refresh failures ([91573fd](https://github.com/supertokens/supertokens-rownd-ios/commit/91573fd))
* fix: reject stale auth during native email verification ([abd9550](https://github.com/supertokens/supertokens-rownd-ios/commit/abd9550))
* chore: fix example ([c689adf](https://github.com/supertokens/supertokens-rownd-ios/commit/c689adf))

## <small>0.1.15 (2026-08-31)</small>

* fix: preserve session after email verification handoff ([de1bf58](https://github.com/supertokens/supertokens-rownd-ios/commit/de1bf58))

## <small>0.1.14 (2026-08-31)</small>

* fix: harden session adoption and profile hydration ([e8843ae](https://github.com/supertokens/supertokens-rownd-ios/commit/e8843ae))
* fix: improve Hub navigation failure handling ([c1773f8](https://github.com/supertokens/supertokens-rownd-ios/commit/c1773f8))
* fix: Persist verified email state on iOS ([b4b83c4](https://github.com/supertokens/supertokens-rownd-ios/commit/b4b83c4))
* fix: publish Apple auth after Hub dismissal ([6f3e2fb](https://github.com/supertokens/supertokens-rownd-ios/commit/6f3e2fb))
* test: cover cleanup before legacy migration ([d9f6329](https://github.com/supertokens/supertokens-rownd-ios/commit/d9f6329))
* test: Cover email state after cold relaunch ([819ea06](https://github.com/supertokens/supertokens-rownd-ios/commit/819ea06))

## <small>0.1.13 (2026-08-27)</small>

* fix: clear retained Hub session on reinstall ([d7a6737](https://github.com/supertokens/supertokens-rownd-ios/commit/d7a6737))
* fix: dismiss auth hub before sign-in completion ([b446ffd](https://github.com/supertokens/supertokens-rownd-ios/commit/b446ffd))

## <small>0.1.12 (2026-08-26)</small>

* fix: initialize sessions before installation cleanup ([c444a35](https://github.com/supertokens/supertokens-rownd-ios/commit/c444a35))

## <small>0.1.11 (2026-08-25)</small>

* test: avoid replacing key window in Apple dismissal tests ([9c86e36](https://github.com/supertokens/supertokens-rownd-ios/commit/9c86e36))
* test: Confirm that you can close the email verification webview ([e51981b](https://github.com/supertokens/supertokens-rownd-ios/commit/e51981b))
* test: cover Apple sign-in Hub dismissal ([827ffa8](https://github.com/supertokens/supertokens-rownd-ios/commit/827ffa8))
* test: Extend e2e tests ([35a896a](https://github.com/supertokens/supertokens-rownd-ios/commit/35a896a))
* test: Speed up tests ([032c5ce](https://github.com/supertokens/supertokens-rownd-ios/commit/032c5ce))
* chore: Bump version ([ecede9e](https://github.com/supertokens/supertokens-rownd-ios/commit/ecede9e))
* chore: Cleanup release and ci ([6d7bbf9](https://github.com/supertokens/supertokens-rownd-ios/commit/6d7bbf9))
* chore: Update scheme ([832f0b4](https://github.com/supertokens/supertokens-rownd-ios/commit/832f0b4))
* fix: dismiss Apple sign-in modal before completion ([f4343ac](https://github.com/supertokens/supertokens-rownd-ios/commit/f4343ac))
* fix: Fix rownd lazy migration regression ([bbf7595](https://github.com/supertokens/supertokens-rownd-ios/commit/bbf7595))
* fix: harden Apple sign-in Hub lifecycle ([42b31a6](https://github.com/supertokens/supertokens-rownd-ios/commit/42b31a6))
* fix: prevent auth sync from racing with sign-out ([9494d3f](https://github.com/supertokens/supertokens-rownd-ios/commit/9494d3f))
* fix: prevent overlapping auth state races ([43c4676](https://github.com/supertokens/supertokens-rownd-ios/commit/43c4676))
* fix: require Apple client type before sign-in ([a78fec8](https://github.com/supertokens/supertokens-rownd-ios/commit/a78fec8))
* fix: require auth state sync before completion ([42ee1b3](https://github.com/supertokens/supertokens-rownd-ios/commit/42ee1b3))
* fix: support formatted SDK version declarations ([0106212](https://github.com/supertokens/supertokens-rownd-ios/commit/0106212))
* fix: support vendored bottom sheet in CocoaPods ([b69e90e](https://github.com/supertokens/supertokens-rownd-ios/commit/b69e90e))
* ci: tryfix ([9a45fa7](https://github.com/supertokens/supertokens-rownd-ios/commit/9a45fa7))
* ci: use local rownd hub ([b2ca6e9](https://github.com/supertokens/supertokens-rownd-ios/commit/b2ca6e9))

## <small>0.1.8 (2026-08-11)</small>

* chore: Update the supertokens-ios version ([663c1b9](https://github.com/supertokens/supertokens-rownd-ios/commit/663c1b9))
* test: Fix e2e test setup ([7140278](https://github.com/supertokens/supertokens-rownd-ios/commit/7140278))
* fix: Handle native pending email verification ([5575f89](https://github.com/supertokens/supertokens-rownd-ios/commit/5575f89))

## <small>0.1.7 (2026-08-07)</small>

* chore: Fix packages ([91516b1](https://github.com/supertokens/supertokens-rownd-ios/commit/91516b1))
* fix: install/clear/read Hub sessions through the core SDK (single source of truth) ([79b3d38](https://github.com/supertokens/supertokens-rownd-ios/commit/79b3d38))
* fix: serialize bridge session operations and green the session test suite ([bc24da0](https://github.com/supertokens/supertokens-rownd-ios/commit/bc24da0))

## <small>0.1.6 (2026-08-07)</small>

* chore: bump version ([ba21240](https://github.com/supertokens/supertokens-rownd-ios/commit/ba21240))
* test: Add complete email change E2E coverage ([bd1d072](https://github.com/supertokens/supertokens-rownd-ios/commit/bd1d072))
* fix: Add appVariantId in config and send it during login requests ([b6b3d5e](https://github.com/supertokens/supertokens-rownd-ios/commit/b6b3d5e))
* fix: Adopt OTP sessions over existing native sessions ([e42bd33](https://github.com/supertokens/supertokens-rownd-ios/commit/e42bd33))
* fix: Scope and reconcile profile updates ([76737cc](https://github.com/supertokens/supertokens-rownd-ios/commit/76737cc))

## <small>0.1.5 (2026-07-31)</small>

* fix: Add appVariantId in config and send it during login requests ([b6b3d5e](https://github.com/supertokens/supertokens-rownd-ios/commit/b6b3d5e))

## <small>0.1.4 (2026-07-27)</small>

* fix: mark session clear as opt in and prevent rownd session removal ([bda8f2f](https://github.com/supertokens/supertokens-rownd-ios/commit/bda8f2f))
* chore: release v0.1.3 ([fa36084](https://github.com/supertokens/supertokens-rownd-ios/commit/fa36084))

## <small>0.1.2 (2026-07-09)</small>

* chore: Add debug logs ([a969845](https://github.com/supertokens/supertokens-rownd-ios/commit/a969845))

## <small>0.1.1 (2026-07-06)</small>

* chore: Rename cocoapod package ([adba350](https://github.com/supertokens/supertokens-rownd-ios/commit/adba350))

## Unreleased

* fix: publish Apple authenticated state only after the authentication Hub is dismissed
* fix: reconcile native sessions and retry profile hydration without exposing stale account data
* security: optionally clear retained SuperTokens sessions on markerless launches without removing legacy Rownd migration state
* breaking: require SuperTokens configuration and remove unsupported legacy auth paths
* breaking: remove native passkey APIs/routes and Firebase connection-action APIs/routes from the SuperTokens-backed SDK
* breaking: remove legacy smart-link auth and public legacy token exchange APIs



## <small>3.14.10 (2026-03-18)</small>

* chore: add .claude config and update Package.resolved ([d53df6d](https://github.com/rownd/ios/commit/d53df6d))
* fix(instant): retain InstantUsers to prevent premature subscription cancellation ([d39d7b4](https://github.com/rownd/ios/commit/d39d7b4))

## <small>3.14.9 (2026-02-27)</small>

* fix: restore backward compatibility in state subscription API (#123) ([0a3c97f](https://github.com/rownd/ios/commit/0a3c97f)), closes [#123](https://github.com/rownd/ios/issues/123)

## <small>3.14.8 (2026-02-20)</small>

* fix(state): stale pointer access could cause app crashes (#121) ([7fe6b4a](https://github.com/rownd/ios/commit/7fe6b4a))

## <small>3.14.7 (2026-02-17)</small>

* chore: upgrade lottie-ios dependency to ~> 4.5.0 ([2f19487](https://github.com/rownd/ios/commit/2f19487))

## <small>3.14.6 (2025-12-02)</small>

* fix(store): prevent stale state listeners from crashing apps (#119) ([3eff869](https://github.com/rownd/ios/commit/3eff869)), closes [#119](https://github.com/rownd/ios/issues/119)

## <small>3.14.5 (2025-11-06)</small>

* chore: add automations coordinator tests ([3e74bfb](https://github.com/rownd/ios/commit/3e74bfb))
* fix(automations): process may crash during init (#118) ([78dc6cc](https://github.com/rownd/ios/commit/78dc6cc)), closes [#118](https://github.com/rownd/ios/issues/118)

## <small>3.14.4 (2025-11-04)</small>

* fix(state): ensure subscribers exist before unsubscribing (#117) ([b35987b](https://github.com/rownd/ios/commit/b35987b)), closes [#117](https://github.com/rownd/ios/issues/117)

## <small>3.14.3 (2025-10-27)</small>

* fix: always cancel and unsubscribe clock sync task (#115) ([38a7cd8](https://github.com/rownd/ios/commit/38a7cd8)), closes [#115](https://github.com/rownd/ios/issues/115)

## <small>3.14.2 (2025-06-30)</small>

* fix: run waitForClockSync on main thread ([070b236](https://github.com/rownd/ios/commit/070b236))

## <small>3.14.1 (2025-06-30)</small>

* fix: catch errors throw while waiting for clock sync (#114) ([47875de](https://github.com/rownd/ios/commit/47875de)), closes [#114](https://github.com/rownd/ios/issues/114)

## 3.14.0 (2025-05-13)

* fix(auth): wait for clock sync prior to exchanging access token (#113) ([2bd86bc](https://github.com/rownd/ios/commit/2bd86bc)), closes [#113](https://github.com/rownd/ios/issues/113)
* feat: support registering native bindings for a customer web view (#111) ([ad8e7a5](https://github.com/rownd/ios/commit/ad8e7a5)), closes [#111](https://github.com/rownd/ios/issues/111)

## <small>3.13.2 (2025-04-21)</small>

* fix(instant): option to force instant users to add an identity (#112) ([a74b151](https://github.com/rownd/ios/commit/a74b151)), closes [#112](https://github.com/rownd/ios/issues/112)

## <small>3.13.1 (2025-04-04)</small>

* fix: error descriptions, disabling clipboard, ui controller threading (#110) ([146e1d5](https://github.com/rownd/ios/commit/146e1d5)), closes [#110](https://github.com/rownd/ios/issues/110)
* chore: add app clip example ([743ec04](https://github.com/rownd/ios/commit/743ec04))

## 3.13.0 (2025-03-21)

* feat: support custom uiviews for loading animations (#109) ([1ab2cc8](https://github.com/rownd/ios/commit/1ab2cc8)), closes [#109](https://github.com/rownd/ios/issues/109)
* fix(apple): include apple user data to token request (#108) ([301a712](https://github.com/rownd/ios/commit/301a712)), closes [#108](https://github.com/rownd/ios/issues/108)

## <small>3.12.2 (2025-03-05)</small>

* fix: spm does not resolve local packages (#107) ([c946e32](https://github.com/rownd/ios/commit/c946e32)), closes [#107](https://github.com/rownd/ios/issues/107)

## <small>3.12.1 (2025-03-05)</small>

* fix(auth): add details to refresh token errors ([7297ff8](https://github.com/rownd/ios/commit/7297ff8))

## 3.12.0 (2025-03-05)

* feat(auth): opt-in to throwing on unavailable token; fix some crashes (#106) ([27b009e](https://github.com/rownd/ios/commit/27b009e)), closes [#106](https://github.com/rownd/ios/issues/106)
* chore: add signout api documentation (#105) ([c033add](https://github.com/rownd/ios/commit/c033add)), closes [#105](https://github.com/rownd/ios/issues/105)

## 3.11.0 (2025-02-07)

* fix(sign-out): ios may ignore sign-out messages in some cases (#104) ([de87199](https://github.com/rownd/ios/commit/de87199)), closes [#104](https://github.com/rownd/ios/issues/104)
* feat: support signing users out of all sessions (#103) ([9383f50](https://github.com/rownd/ios/commit/9383f50)), closes [#103](https://github.com/rownd/ios/issues/103)

## <small>3.10.8 (2025-01-24)</small>

* fix(appleid): update profile data when state is valid (#102) ([245ee16](https://github.com/rownd/ios/commit/245ee16)), closes [#102](https://github.com/rownd/ios/issues/102)

## <small>3.10.7 (2025-01-24)</small>

* fix(init): no need to wait for clock sync during boot ([2797056](https://github.com/rownd/ios/commit/2797056))

## <small>3.10.6 (2025-01-23)</small>

* fix(events): wait for isAccessTokenValid before propagating .signInComplete (#101) ([da12133](https://github.com/rownd/ios/commit/da12133)), closes [#101](https://github.com/rownd/ios/issues/101)

## <small>3.10.5 (2025-01-21)</small>

* fix(auth): handle previously initiated auth challenges (#100) ([8418c7e](https://github.com/rownd/ios/commit/8418c7e)), closes [#100](https://github.com/rownd/ios/issues/100)

## <small>3.10.4 (2025-01-10)</small>

* chore(test): throw when no token is present after sign in ([fe6cc3f](https://github.com/rownd/ios/commit/fe6cc3f))
* fix(events): fire sign-in events after auth events ([ef0fa83](https://github.com/rownd/ios/commit/ef0fa83))

## <small>3.10.3 (2025-01-09)</small>

* fix(tokkens): include app key in token requests (#98) ([4bda382](https://github.com/rownd/ios/commit/4bda382)), closes [#98](https://github.com/rownd/ios/issues/98)
* Draft: add app_variant_user_type to sign in event (#97) ([90254dd](https://github.com/rownd/ios/commit/90254dd)), closes [#97](https://github.com/rownd/ios/issues/97)

## <small>3.10.2 (2024-12-06)</small>

* fix(sign out): main thread hang (#96) ([bbb662d](https://github.com/rownd/ios/commit/bbb662d)), closes [#96](https://github.com/rownd/ios/issues/96)

## <small>3.10.1 (2024-11-27)</small>

* fix(auth): computed property not triggering state observers (#95) ([4ccfa46](https://github.com/rownd/ios/commit/4ccfa46)), closes [#95](https://github.com/rownd/ios/issues/95)
* fetch user profile before saving apple user data (#94) ([dcba80b](https://github.com/rownd/ios/commit/dcba80b)), closes [#94](https://github.com/rownd/ios/issues/94)

## 3.10.0 (2024-11-13)

* fix(logs): missing redact for app container logs ([91feaf5](https://github.com/rownd/ios/commit/91feaf5))
* feat: add api for checking if authenticated and has user data (#93) ([178b239](https://github.com/rownd/ios/commit/178b239)), closes [#93](https://github.com/rownd/ios/issues/93)

## 3.9.0 (2024-11-01)

* chore: update release deps ([c9ddc50](https://github.com/rownd/ios/commit/c9ddc50))
* chore: update resolved packages ([0435fa1](https://github.com/rownd/ios/commit/0435fa1))
* fix: close bottom sheet controller before hub view controller (#92) ([50abb33](https://github.com/rownd/ios/commit/50abb33)), closes [#92](https://github.com/rownd/ios/issues/92)
* fix(appex): Prevent race conditions between app extensions which might lead to a sign-out (#89) ([bbb4a86](https://github.com/rownd/ios/commit/bbb4a86)), closes [#89](https://github.com/rownd/ios/issues/89)
* feat(magic): handle generic deep links (#91) ([a6a1c6b](https://github.com/rownd/ios/commit/a6a1c6b)), closes [#91](https://github.com/rownd/ios/issues/91)
* remove instances of transfer key (#85) ([6b1d21f](https://github.com/rownd/ios/commit/6b1d21f)), closes [#85](https://github.com/rownd/ios/issues/85)
* Sign in fallback (#88) ([380f54e](https://github.com/rownd/ios/commit/380f54e)), closes [#88](https://github.com/rownd/ios/issues/88)

## [3.8.2](https://github.com/rownd/ios/compare/3.8.1...3.8.2) (2024-10-15)


### Bug Fixes

* decoding is loading within user state ([#87](https://github.com/rownd/ios/issues/87)) ([0e9c1ec](https://github.com/rownd/ios/commit/0e9c1ec6e7425a4374fedb2095908991e4307dcb))

## [3.8.1](https://github.com/rownd/ios/compare/3.8.0...3.8.1) (2024-10-11)


### Bug Fixes

* reduce ntp sync delay ([3c1f502](https://github.com/rownd/ios/commit/3c1f5022b931617f62866e5758c716879130c4ca))

# [3.8.0](https://github.com/rownd/ios/compare/3.7.0...3.8.0) (2024-09-18)


### Bug Fixes

* package resolved ([6d64fd9](https://github.com/rownd/ios/commit/6d64fd935de0a7eb7dee790c1fcf68159740cf63))


### Features

* handle unique automation schemas with a default fallback ([#83](https://github.com/rownd/ios/issues/83)) ([d1ee2dc](https://github.com/rownd/ios/commit/d1ee2dc0b8a44b693af7348ce5d2fe4bfd21fee0))

# [3.7.0](https://github.com/rownd/ios/compare/3.6.0...3.7.0) (2024-07-18)


### Bug Fixes

* disable verified magic link as sign in link ([#81](https://github.com/rownd/ios/issues/81)) ([3e2de09](https://github.com/rownd/ios/commit/3e2de097f4c2741e1b4bbb5c8f2c1102be5d3588))


### Features

* handle mail to links ([#82](https://github.com/rownd/ios/issues/82)) ([a5eb392](https://github.com/rownd/ios/commit/a5eb3928dd3c9fad7e7adc7e1ec828fe75ae424a))

# [3.6.0](https://github.com/rownd/ios/compare/3.5.1...3.6.0) (2024-07-12)


### Bug Fixes

* remove public ([86355fc](https://github.com/rownd/ios/commit/86355fc613709ccc70159a629f807b78dde938fb))
* revert back to optional ([dc205a9](https://github.com/rownd/ios/commit/dc205a96e36ad4e158e172460259199771f6ff84))


### Features

* improve rownd passkey apis ([4f37708](https://github.com/rownd/ios/commit/4f3770805790e5ba9d2bf85e26559d8541717994))

## [3.5.1](https://github.com/rownd/ios/compare/3.5.0...3.5.1) (2024-07-08)


### Bug Fixes

* user data response type ([#79](https://github.com/rownd/ios/issues/79)) ([7a63c13](https://github.com/rownd/ios/commit/7a63c137994232b592f8d0d4a0c01f606ae1165e))

# [3.5.0](https://github.com/rownd/ios/compare/3.4.0...3.5.0) (2024-06-25)


### Features

* make is loading user public ([823596a](https://github.com/rownd/ios/commit/823596abcf9bd949363699273b495b71944add56))

# [3.4.0](https://github.com/rownd/ios/compare/3.3.0...3.4.0) (2024-06-07)


### Features

* remove unused "redacted" user field ([3d9275f](https://github.com/rownd/ios/commit/3d9275f74ace30c8f89458782dc8babb75bc5a0b))

# [3.3.0](https://github.com/rownd/ios/compare/3.2.0...3.3.0) (2024-05-22)


### Features

* **events:** emit events that occur during the auth lifecycle ([#74](https://github.com/rownd/ios/issues/74)) ([69cd18c](https://github.com/rownd/ios/commit/69cd18c8bde93717838ddf1546ec8857711cdb69))

# [3.2.0](https://github.com/rownd/ios/compare/3.1.0...3.2.0) (2024-05-04)


### Features

* support for app groups ([#73](https://github.com/rownd/ios/issues/73)) ([4dbee05](https://github.com/rownd/ios/commit/4dbee05d1a4d87c7f9eb836782145271089e97b9))

# [3.1.0](https://github.com/rownd/ios/compare/3.0.3...3.1.0) (2024-04-24)


### Features

* update lottie version ([#70](https://github.com/rownd/ios/issues/70)) ([77def64](https://github.com/rownd/ios/commit/77def642d2a3e09dd94f75d9e4849077aa60bc9a))
* update package.resolved ([b96063c](https://github.com/rownd/ios/commit/b96063c8a84e184ae1dc22c488f7cccf539c38e1))

## [3.0.3](https://github.com/rownd/ios/compare/3.0.2...3.0.3) (2024-04-12)


### Bug Fixes

* **auth:** handle longer ntp clock sync window ([#69](https://github.com/rownd/ios/issues/69)) ([a520815](https://github.com/rownd/ios/commit/a5208159c1d66f670bd10d247a9ae876f6f5e64b))
* decoding app config automations ([#67](https://github.com/rownd/ios/issues/67)) ([ca4f3e0](https://github.com/rownd/ios/commit/ca4f3e050940fa69633f1189bd1c940a70bb6932))

## [3.0.2](https://github.com/rownd/ios/compare/3.0.1...3.0.2) (2024-02-27)


### Bug Fixes

* app config not loading when unknown automations are present ([e0bab57](https://github.com/rownd/ios/commit/e0bab57d6bcb33fba35f0bc0c3d5d5122b0df160))

## [3.0.1](https://github.com/rownd/ios/compare/3.0.0...3.0.1) (2024-01-23)


### Bug Fixes

* moved google sign-in hint public ([fbd88a3](https://github.com/rownd/ios/commit/fbd88a355eb54947cfdde5e8aaf0b6a259ecab26))


### Features

* pass down google sign in hint ([cb5ccc5](https://github.com/rownd/ios/commit/cb5ccc5d6c596f876edac56785f4a6e9f77a322b))

# [3.0.0](https://github.com/rownd/ios/compare/2.9.0...3.0.0) (2023-12-14)

# [2.9.0](https://github.com/rownd/ios/compare/2.8.3...2.9.0) (2023-12-14)


### Bug Fixes

* enforce dark/light background from appConfig ([#64](https://github.com/rownd/ios/issues/64)) ([217aa79](https://github.com/rownd/ios/commit/217aa79c3c0514d3c612f5c2d9ece6c456e669f6))
* removed ios automation id ([f1f6fcf](https://github.com/rownd/ios/commit/f1f6fcf84bea9e28359553f55281f2bfbc7bacfc))


### Features

* **app-config:** added automations to app-config ([52da0f0](https://github.com/rownd/ios/commit/52da0f06d6b205a76b7bf2c20580ceed58ac0c9a))
* **automations:** added automations ([26bf1b2](https://github.com/rownd/ios/commit/26bf1b21f2e91c8e16c98b669cead1cb4b6eb280))
* **meta data:** added ability to save and fetch meta data ([d5f8440](https://github.com/rownd/ios/commit/d5f8440dee562651a28dc2b50ed1bb3ac38f3985))
* **meta data:** added ability to save and fetch meta data ([c036d41](https://github.com/rownd/ios/commit/c036d4104a892891a8dfc95e79b9fba76e1ca1a3))
* **passkeys:** passkey reducer ([6d73b46](https://github.com/rownd/ios/commit/6d73b462326507b5f56ba385b6542c26c8fd48af))
* **passkeys:** passkey reducer ([08b03ee](https://github.com/rownd/ios/commit/08b03eeb546a30f2f698efb738b1ce01b4f64777))
* prevent hub from closing if another rownd api was called ([65012bc](https://github.com/rownd/ios/commit/65012bc0de21dd4411d20eda98e73f5a96569976))
* removed sodium package ([#63](https://github.com/rownd/ios/issues/63)) ([13b1da7](https://github.com/rownd/ios/commit/13b1da70752e14f75db50b4305739e45f88ebd9e))
* **utils:** debounce and time utils ([3049038](https://github.com/rownd/ios/commit/30490381b9cfd4725e4fe34e7b8c4006f67df9d4))

## [2.8.3](https://github.com/rownd/ios/compare/2.8.2...2.8.3) (2023-11-21)


### Features

* allow opening gmail, outlook, and yahoo as email providers ([d7e423e](https://github.com/rownd/ios/commit/d7e423eaa8670b1b3ee55da61ac7c8a09605f6e6))

## [2.8.2](https://github.com/rownd/ios/compare/2.8.1...2.8.2) (2023-10-23)


### Bug Fixes

* esnure init uiViewController is on main thread ([#60](https://github.com/rownd/ios/issues/60)) ([5508ff8](https://github.com/rownd/ios/commit/5508ff8d99c457318291b2fc7878ca3ce9ffc127))

## [2.8.1](https://github.com/rownd/ios/compare/2.8.0...2.8.1) (2023-09-11)


### Bug Fixes

* downgrade lottie version for current customer ([#58](https://github.com/rownd/ios/issues/58)) ([7d93894](https://github.com/rownd/ios/commit/7d938941364698790e634b7578bbdf136ba9b6e7))
* library fixes for lottie pod ([96df1bf](https://github.com/rownd/ios/commit/96df1bf70f1cd79fb9f8b676d9654587e24d6b2f))

# [2.8.0](https://github.com/rownd/ios/compare/2.7.0...2.8.0) (2023-09-07)


### Bug Fixes

* error message wording ([b07b709](https://github.com/rownd/ios/commit/b07b709167f1f030701f1a208923efe920ab481c))


### Features

* rownd firebase api for grabbing firebase idToken for authenticated user ([82ad694](https://github.com/rownd/ios/commit/82ad694090269eafb14186f4621b3e7ffecd5e34))

# [2.7.0](https://github.com/rownd/ios/compare/2.6.1...2.7.0) (2023-08-21)


### Bug Fixes

* bumped podspec version ([cf8a217](https://github.com/rownd/ios/commit/cf8a217bfb8640239ca85bb1219a2af1692dda19))


### Features

* bumped lottie version to 4.2.0 ([1aa1681](https://github.com/rownd/ios/commit/1aa16819a4e30d08ce2909aa75d7142adcacef1c))

## [2.6.1](https://github.com/rownd/ios/compare/2.6.0...2.6.1) (2023-06-13)

## [2.5.4](https://github.com/rownd/ios/compare/2.5.3...2.5.4) (2023-04-25)


### Bug Fixes

* **ui:** wrong rootvc sometimes selected for bottom sheet ([5a5ab16](https://github.com/rownd/ios/commit/5a5ab162bf9e8bda94d4a4a2e241e6aaae339092))

## [2.5.3](https://github.com/rownd/ios/compare/2.5.2...2.5.3) (2023-04-17)


### Bug Fixes

* **paste:** result might be nil after successful detection ([6fd429c](https://github.com/rownd/ios/commit/6fd429c88965a04125fff72e86d833a55531c329))

## [2.5.2](https://github.com/rownd/ios/compare/2.5.1...2.5.2) (2023-04-17)


### Bug Fixes

* **auth:** passkey and social sign-in flow improvements ([#49](https://github.com/rownd/ios/issues/49)) ([888cfb1](https://github.com/rownd/ios/commit/888cfb12877cd6116a8c0a6bee59778a41408520))
* **offline:** honor light/dark colors as applicable ([d192bc0](https://github.com/rownd/ios/commit/d192bc0584ceaddc1cc6b5aed181ff709e6ca405))
* **paste:** only grab from pasteboard if it prob has a url ([5149b67](https://github.com/rownd/ios/commit/5149b67bb2bfd87530e8909b27d0aa136654c9b7))

## [2.5.1](https://github.com/rownd/ios/compare/2.5.0...2.5.1) (2023-04-07)


### Bug Fixes

* **store:** failed to decode state after upgrade ([c2631e3](https://github.com/rownd/ios/commit/c2631e3508c317e96cdf75851657958fea68f75b))

# [2.5.0](https://github.com/rownd/ios/compare/2.4.1...2.5.0) (2023-04-06)


### Bug Fixes

* **auth:** social sign-in can block touch input ([#48](https://github.com/rownd/ios/issues/48)) ([50d132b](https://github.com/rownd/ios/commit/50d132be7be5a1d14e4391c036faeb954cdf4f3b))
* keyboardWillShow delegate gets triggered everytime ([#47](https://github.com/rownd/ios/issues/47)) ([d7c3d3c](https://github.com/rownd/ios/commit/d7c3d3c560f0eabd26caf071d33c62e1f861d11e))


### Features

* **passkeys:** meet server requirements ([#46](https://github.com/rownd/ios/issues/46)) ([17a2861](https://github.com/rownd/ios/commit/17a2861bca7e4091fc25251e42c4685242ad3599))
* recieved message from hub to disable webview loading ([#43](https://github.com/rownd/ios/issues/43)) ([c708bed](https://github.com/rownd/ios/commit/c708bed923f1f22d77d32a47a497e08ae69c8061)), closes [#44](https://github.com/rownd/ios/issues/44)

## [2.4.1](https://github.com/rownd/ios/compare/2.4.0...2.4.1) (2023-02-10)


### Bug Fixes

* pass down intent from hub to apple/google sign-in ([#42](https://github.com/rownd/ios/issues/42)) ([54c0def](https://github.com/rownd/ios/commit/54c0defe585c5d1549e77ceaae6433ffdf2f0ccd))

# [2.4.0](https://github.com/rownd/ios/compare/2.3.0...2.4.0) (2023-01-31)


### Bug Fixes

* **auth:** token sign-in may not work ([ebe593d](https://github.com/rownd/ios/commit/ebe593da95be008294dd0e097bc03e3a68c86e62))


### Features

* support split sign in/up flow ([#40](https://github.com/rownd/ios/issues/40)) ([282544c](https://github.com/rownd/ios/commit/282544cac330ecfa0b5222c4a9b717db4826d507))

# [2.3.0](https://github.com/rownd/ios/compare/2.2.2...2.3.0) (2023-01-23)


### Features

* **auth:** support third-party token exchange ([#41](https://github.com/rownd/ios/issues/41)) ([bd8ff45](https://github.com/rownd/ios/commit/bd8ff4584d5744b31a78e923afa65de7365b15a7))

## [2.2.2](https://github.com/rownd/ios/compare/2.2.1...2.2.2) (2023-01-06)

## [2.2.1](https://github.com/rownd/ios/compare/2.2.0...2.2.1) (2023-01-06)


### Bug Fixes

* **auth:** sign-in with Apple occasionally fails due to race condition ([#37](https://github.com/rownd/ios/issues/37)) ([6e5a910](https://github.com/rownd/ios/commit/6e5a910dd7e1a165c554efe34616cd25669e4660))
* **test:** intermittently failing auth test ([bbb4a90](https://github.com/rownd/ios/commit/bbb4a903e5534a5040f68b7f8d2a491e025fe3f3))

# [2.2.0](https://github.com/rownd/ios/compare/2.1.0...2.2.0) (2022-12-15)


### Features

* **users:** auto sign out if account is not found ([#36](https://github.com/rownd/ios/issues/36)) ([f9f1717](https://github.com/rownd/ios/commit/f9f1717e2d796bc65b1d2f17b488988cdd686abd))
* **auth:** support signing in using Passkeys ([#34](https://github.com/rownd/ios/pull/34)) ([7e3943c](https://github.com/rownd/ios/commit/7e3943ca86ab6e2fdec279944dace917dd64234d))

# [2.1.0](https://github.com/rownd/ios/compare/2.0.3...2.1.0) (2022-12-07)


### Features

* **auth:** try to use ntp for time checking token exp ([#33](https://github.com/rownd/ios/issues/33)) ([16cfcd9](https://github.com/rownd/ios/commit/16cfcd9faf8f1f1d7045ee46586524739af4d92b))

## [2.0.3](https://github.com/rownd/ios/compare/2.0.2...2.0.3) (2022-11-21)


### Bug Fixes

* **refresh:** prevent sign-outs on non-400 http statuses ([8af36fb](https://github.com/rownd/ios/commit/8af36fb04d62429632be1a9ee7f4c68744469193))

## [2.0.2](https://github.com/rownd/ios/compare/2.0.1...2.0.2) (2022-11-15)


### Bug Fixes

* **state:** crash during auth state sync ([c02ded4](https://github.com/rownd/ios/commit/c02ded4d0713efc8ae2280ba29d988da09529cb8))


### Features

* **ui:** increase initial bottomsheet height ([adeadb9](https://github.com/rownd/ios/commit/adeadb936e07c21003597f183cdf4761ce01d7c4))

## [2.0.1](https://github.com/rownd/ios/compare/2.0.0...2.0.1) (2022-11-14)


### Bug Fixes

* **refresh:** ensure authenticator always reflects current state ([#30](https://github.com/rownd/ios/issues/30)) ([e3a9856](https://github.com/rownd/ios/commit/e3a98564fea1a655be8bc554949a403cc46b7021))

# [2.0.0](https://github.com/rownd/ios/compare/1.13.0...2.0.0) (2022-11-11)


### Features

* **auth:** prevent sign-outs during poor network conditions ([#28](https://github.com/rownd/ios/issues/28)) ([a605b84](https://github.com/rownd/ios/commit/a605b844c79e651fb46317df6e001b3f2cc709b1))
* **email:** enable button to open email from app ([#25](https://github.com/rownd/ios/issues/25)) ([1d3c963](https://github.com/rownd/ios/commit/1d3c9635a64d3f3fc7071a4433b3f22138b1271b))

# [1.13.0](https://github.com/rownd/ios/compare/1.12.4...1.13.0) (2022-11-02)

## [1.12.4](https://github.com/rownd/ios/compare/1.12.3...1.12.4) (2022-10-25)

## [1.12.3](https://github.com/rownd/ios/compare/1.12.2...1.12.3) (2022-10-18)


### Bug Fixes

* **auth:** race condition preventing user data fetch ([#21](https://github.com/rownd/ios/issues/21)) ([44279c4](https://github.com/rownd/ios/commit/44279c40b192c0a8c362512e024e9de02ed235a7))

## [1.12.2](https://github.com/rownd/ios/compare/1.12.1...1.12.2) (2022-10-18)


### Bug Fixes

* **auth:** properly handle concurrent refresh token requests ([#20](https://github.com/rownd/ios/issues/20)) ([d655b9f](https://github.com/rownd/ios/commit/d655b9f2d6b24efde48e4138a1e514d0fed70236))

## [1.12.1](https://github.com/rownd/ios/compare/1.12.0...1.12.1) (2022-10-16)


### Bug Fixes

* **state:** handle fresh install case where store load fails ([930e088](https://github.com/rownd/ios/commit/930e088fd3eb4c80cc731bebb6c41a7e1340fba8))

# [1.12.0](https://github.com/rownd/ios/compare/1.11.0...1.12.0) (2022-10-14)


### Features

* **auth:** add flag to determine whether the access token is valid ([d086255](https://github.com/rownd/ios/commit/d086255d036c539f5fe51191a02ae80e719bfa02))

# [1.11.0](https://github.com/rownd/ios/compare/1.10.2...1.11.0) (2022-10-14)


### Features

* **state:** detect when sdk has finished initializing ([5f24e9f](https://github.com/rownd/ios/commit/5f24e9f122025fe4766e8baf93ae997812d8edfe))

# [1.10.0](https://github.com/rownd/ios/compare/1.9.1...1.10.0) (2022-10-12)


### Bug Fixes

* **build:** xcodeproj corruption ([f4c882e](https://github.com/rownd/ios/commit/f4c882ee2ab598483d97e1bf92388bf809c07da5))
* **google:** don't close hub if error ([#19](https://github.com/rownd/ios/issues/19)) ([7bbd6b0](https://github.com/rownd/ios/commit/7bbd6b07af4118d092fca2ea5c40c156d6c760d1))
* ui inconsistencies & crash in key xfer ([85e40c2](https://github.com/rownd/ios/commit/85e40c2da1eba845ffaabb41d853af45e95b218b))


### Features

* add sign in with google ([#17](https://github.com/rownd/ios/issues/17)) ([fdf5a8a](https://github.com/rownd/ios/commit/fdf5a8a786727164f0958c87a90355bc39fb919d))
* **google:** use iosClientConfig from AppConfig ([#18](https://github.com/rownd/ios/issues/18)) ([a92a0c9](https://github.com/rownd/ios/commit/a92a0c912af4a72f2e56d76711097a3d9d368fad))

## [1.9.1](https://github.com/rownd/ios/compare/1.9.0...1.9.1) (2022-10-02)


### Bug Fixes

* **auth:** working sign-in links ([15476f7](https://github.com/rownd/ios/commit/15476f7967060168e2457e32aab3d3b27e68456e))

# [1.9.0](https://github.com/rownd/ios/compare/1.8.4...1.9.0) (2022-09-28)


### Features

* **customizations:** support lottie animated loading indicators ([#16](https://github.com/rownd/ios/issues/16)) ([1580297](https://github.com/rownd/ios/commit/15802975a5bd25967ad74a348a5435b613b41de6))

## [1.8.4](https://github.com/rownd/ios/compare/1.8.3...1.8.4) (2022-09-26)


### Bug Fixes

* **state:** occasional crash during async state updates ([8fd78bd](https://github.com/rownd/ios/commit/8fd78bdf15db50efda7616fc29192ffa26a7de6f))

## [1.8.3](https://github.com/rownd/ios/compare/1.8.2...1.8.3) (2022-09-22)


### Bug Fixes

* **auth:** decoding issue during token refresh ([a7aaae2](https://github.com/rownd/ios/commit/a7aaae2419875c6c046d1005a3be67018bbc3c95))

## [1.8.2](https://github.com/rownd/ios/compare/1.8.1...1.8.2) (2022-09-19)


### Bug Fixes

* concurrent mutation errors during react native build ([dd5b900](https://github.com/rownd/ios/commit/dd5b900825f488463920df28404e9008da6ca3b5))

## [1.8.1](https://github.com/rownd/ios/compare/1.8.0...1.8.1) (2022-09-16)



All notable changes to this project will be documented in this file. See [standard-version](https://github.com/conventional-changelog/standard-version) for commit guidelines.

## [1.6.0](https://github.com/rownd/ios/compare/v1.1.1...v1.6.0) (2022-08-25)


### Features

* **encryption:** initial api + tests ([#1](https://github.com/rownd/ios/issues/1)) ([6289d42](https://github.com/rownd/ios/commit/6289d426408c15ad86cd9e93e940ff1cbd7480aa))
* **encryption:** initial transfer ui ([5fd7741](https://github.com/rownd/ios/commit/5fd7741acf8da7ef2b58506970ad98d62a54fe7e))
* **encryption:** polish key transfer flow ([5740a01](https://github.com/rownd/ios/commit/5740a015bc42c4d12c88b414fc1c9801ae0f6073))
* **encryption:** security improvements and ui fixes ([7ffdb34](https://github.com/rownd/ios/commit/7ffdb3449d7f6b892d4a36487bdc07d140283e6d))
* **encryption:** support for displaying transfer qr codes ([9087936](https://github.com/rownd/ios/commit/9087936728809608402e660c8e566e66a8e3127e))
* **encryption:** transfer ui improvements ([14f802d](https://github.com/rownd/ios/commit/14f802d2962f5413aea1d59f58e16124f1e293eb))
* **encryption:** ux improvements to transfer views ([16eb78d](https://github.com/rownd/ios/commit/16eb78d895830a92b531a8c95037b4914a80428b))
* improvements to user management and sign-in ([bf37c9e](https://github.com/rownd/ios/commit/bf37c9ed46b40a1835b171fe1bf487b63c4f2b78))
* **os:** now target ios v14+ ([1410178](https://github.com/rownd/ios/commit/141017870bb25602b00e2f023be2f412a541b1af))


### Bug Fixes

* **auth:** failing refresh token flow ([bb81e7a](https://github.com/rownd/ios/commit/bb81e7a305f6e0871226acdc420c2d60a26314e0))
* **auth:** intermittent sign-out issues ([07de523](https://github.com/rownd/ios/commit/07de523087243130f1b987fefc71b36b055d77b8))
* **encrypt:** generate complete qr codes on-demand ([2974a42](https://github.com/rownd/ios/commit/2974a42ed46a8c9ea24e99091f5af678ca9d3cf6))
* **encrypt:** improved error handling ([c842143](https://github.com/rownd/ios/commit/c842143f01fd03371b0c7c61376e30be2991b462))
* **release:** add missin deps ([8dd4132](https://github.com/rownd/ios/commit/8dd41326ef8cd40ce1346824fdc6e2aa7c28c3b2))
* **release:** broken reswift-thunk package name ([05fbb58](https://github.com/rownd/ios/commit/05fbb581fd01a10f64b875273a1110e230d0a2b4))
* **release:** delete unused file ([d2340d8](https://github.com/rownd/ios/commit/d2340d8bf9c308589c7cac44537bd69279a921f8))
* **release:** minimum ios version should be 15 ([ca103ad](https://github.com/rownd/ios/commit/ca103ad82b5bd5eca07ad7f350dfda10c7f965a5))
* **release:** missing comma ([dbdfed6](https://github.com/rownd/ios/commit/dbdfed68d5630fc78718494d3ec17c3f87ae565b))
* **release:** missing comma ([7844b3a](https://github.com/rownd/ios/commit/7844b3ae9e4725b46bde88ee7f072582ccdcf95b))
* **release:** remove reference to unneeded lib ([d9e8252](https://github.com/rownd/ios/commit/d9e8252816c91987c242ff92db0b83c8343ad8bc))
* **release:** remove unused file from target ([6faa196](https://github.com/rownd/ios/commit/6faa196d0946cf4f2db93bac6fd8eb5876ca9a7d))
* **ui:** compatibility with navigation controller ([1dfecb6](https://github.com/rownd/ios/commit/1dfecb64033c4cb9f321a990a5233dec2bcc786c))
