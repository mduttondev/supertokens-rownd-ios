//
//  RowndState.swift
//
//
//  Created by Matt Hamann on 4/3/24.
//

import Foundation
import OSLog
import ReSwift
import ReSwiftThunk

private let log = Logger(subsystem: "io.rownd.sdk", category: "state")

private let STORAGE_STATE_KEY = "RowndState"

private let saveDebouncer = Debouncer(delay: 0.1)
private let reloadDebouncer = Debouncer(delay: 0.1)

public struct RowndState: Codable, Hashable {
    public var isStateLoaded = false
    internal var clockSyncState: ClockSyncState = NetworkTimeManager.shared.currentTime != nil ? .synced : .waiting
    public var appConfig = AppConfigState()
    public var auth = AuthState()
    public var user = UserState()
    public var signIn = SignInState()
    public var lastUpdateTs = Date()
}

extension RowndState {
    enum CodingKeys: String, CodingKey {
        case appConfig, auth, user, signIn, lastUpdateTs
    }

    public var isInitialized: Bool {
        return isStateLoaded && clockSyncState != .waiting
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appConfig = try container.decode(AppConfigState.self, forKey: .appConfig)
        auth = try container.decode(AuthState.self, forKey: .auth)
        user = try container.decode(UserState.self, forKey: .user)
        signIn = try container.decodeIfPresent(SignInState.self, forKey: .signIn) ?? SignInState()
        lastUpdateTs = try container.decodeIfPresent(Date.self, forKey: .lastUpdateTs) ?? Date()
    }

    internal func save() {
        saveDebouncer.debounce(action: {
            self.saveImmediately()
        })
    }

    @discardableResult
    internal func saveImmediately() -> Bool {
        guard let encoded = try? toJson(),
              Storage.shared.set(encoded, forKey: STORAGE_STATE_KEY) else {
            return false
        }

        DarwinNotificationManager.shared.postNotification(name: "io.rownd.events.StateUpdated")
        log.trace("Wrote state to storage \(Redact.redactSensitiveKeys(in: encoded).data(using: .utf8)?.prettyPrintedJSONString)")
        return true
    }

    @discardableResult
    public func load() async -> RowndState {
        return await load(Context.currentContext.store)
    }

    @discardableResult
    internal func load(_ store: Store<RowndState>) async -> RowndState {
        let existingStateStr = Storage.shared.get(forKey: STORAGE_STATE_KEY)
//        log.trace("initial store state: \(String(describing: existingStateStr))")

        DarwinNotificationManager.shared.startObserving(name: "io.rownd.events.StateUpdated") {
            self.scheduleReload(store)
        }

        guard let existingStateStr = existingStateStr else {
            await MainActor.run {
                store.dispatch(SetStateLoaded())
            }
            return store.state
        }

        do {
            let decoder = JSONDecoder()
            var decoded = try decoder.decode(
                RowndState.self,
                from: (existingStateStr.data(using: .utf8) ?? Data())
            )
            decoded.isStateLoaded = true
            decoded.clockSyncState = NetworkTimeManager.shared.currentTime != nil ? .synced : store.state.clockSyncState
            await MainActor.run { [decoded] in
                store.dispatch(InitializeRowndState(payload: decoded))
            }

            return decoded
        } catch {
            log.debug("Failed decoding state from storage (if this is the first time launching the app, this is expected): \(String(describing: error))")
        }

        return store.state
    }

    internal func scheduleReload(_ store: Store<RowndState>) {
        reloadDebouncer.debounce {
            Task {
                await self.reload(store)
            }
        }
    }

    internal func reload() async {
        await reload(Context.currentContext.store)
    }

    internal func reload(_ store: Store<RowndState>) async {
        let existingStateStr = Storage.shared.get(forKey: STORAGE_STATE_KEY)
        log.trace("Retrieved store state: \(Redact.redactSensitiveKeys(in: existingStateStr ?? ""), privacy: .private)")

        guard let existingStateStr = existingStateStr else {
            return
        }

        do {
            let decoder = JSONDecoder()
            let decoded = try decoder.decode(
                RowndState.self,
                from: (existingStateStr.data(using: .utf8) ?? Data())
            )

            log.trace("Retrieved auth state: \(String(describing: decoded.auth), privacy: .private)")

            await MainActor.run { [decoded] in
                // A delayed notification can read a snapshot older than pending local writes.
                // Check at dispatch time so updates made during the actor hop also win.
                guard decoded.lastUpdateTs > store.state.lastUpdateTs else {
                    return
                }
                store.dispatch(ReloadRowndState(payload: decoded))
            }
        } catch {
            log.debug("Failed decoding state from storage (if this is the first time launching the app, this is expected): \(String(describing: error))")
        }
    }

    public func toJson() throws -> String? {
        let encoder = JSONEncoder()
        if let encoded = try? encoder.encode(self) {
            return String(data: encoded, encoding: .utf8)
        }

        throw StateError("Failed to encode state")
    }

    public func toDictionary() throws -> [String: Any?] {
        let encoder = JSONEncoder()
        let data = try encoder.encode(self)
        return try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] ?? [:]
    }
}

struct SetStateLoaded: Action {}

struct InitializeRowndState: Action {
    var payload: RowndState
}

struct SetClockSync: Action {
    var clockSyncState: ClockSyncState
}

struct ReloadRowndState: Action {
    var payload: RowndState
}

func rowndStateReducer(action: Action, state: RowndState?) -> RowndState {
    var newState: RowndState
    switch action {
    case _ as SetStateLoaded:
        newState = state ?? Context.currentContext.store.state
        newState.isStateLoaded = true
    case let initializeAction as InitializeRowndState:
        newState = initializeAction.payload
        newState.clockSyncState = state?.clockSyncState ?? Context.currentContext.store.state.clockSyncState
    case let clockSyncAction as SetClockSync:
        newState = state ?? Context.currentContext.store.state
        newState.clockSyncState = clockSyncAction.clockSyncState
    case let reloadAction as ReloadRowndState:
        newState = reloadAction.payload
        newState.clockSyncState = state?.clockSyncState ?? .unknown
        newState.isStateLoaded = state?.isStateLoaded ?? true
    default:
        newState = RowndState(
            isStateLoaded: true,
            clockSyncState: state?.clockSyncState ?? Context.currentContext.store.state.clockSyncState,
            appConfig: appConfigReducer(action: action, state: state?.appConfig),
            auth: authReducer(action: action, state: state?.auth),
            user: userReducer(action: action, state: state?.user),
            signIn: signInReducer(action: action, state: state?.signIn)
        )

        if let priorRevision = state?.lastUpdateTs.timeIntervalSinceReferenceDate {
            // This timestamp also orders snapshots; local edits must advance after clock rollback.
            newState.lastUpdateTs = Date(timeIntervalSinceReferenceDate: max(
                newState.lastUpdateTs.timeIntervalSinceReferenceDate,
                priorRevision.nextUp
            ))
        }

        newState.save()
    }

    log.trace("Internal state update \(String(describing: action), privacy: .auto)")

    if !newState.auth.isAuthenticated && (state?.auth.isAuthenticated == true) {
        if #available(iOS 15.0, *) {
            Task {
                // TODO: enable w/ telemetry
                // fetchRecentLogs(secondsBack: 10)
            }
        }
    }

    return newState
}

func createStore() -> Store<RowndState> {
    return Store(
        reducer: rowndStateReducer,
        state: RowndState(),
        middleware: [
            thunkMiddleware,
            authenticatorMiddleware
        ]
    )
}

let thunkMiddleware: Middleware<RowndState> = createThunkMiddleware()
let authenticatorMiddleware: Middleware<RowndState> = AuthenticatorSubscription.createAuthenticatorMiddleware()

struct StateError: Error, CustomStringConvertible {
    var message: String

    init(_ message: String) {
        self.message = message
    }

    public var description: String {
        return message
    }
}
