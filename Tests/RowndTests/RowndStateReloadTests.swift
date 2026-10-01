import Foundation
import ReSwift
import Testing

@testable import Rownd

@Suite(.serialized)
struct RowndStateReloadTests {
    @Test
    func localUpdatesAdvancePastFutureRevisionAndSurviveReloadScheduling() async throws {
        try await withGlobalTestLock {
            let originalState = Storage.shared.get(forKey: "RowndState")
            defer {
                if let originalState {
                    Storage.shared.set(originalState, forKey: "RowndState")
                } else {
                    Storage.shared.remove(forKey: "RowndState")
                }
            }

            // A future revision models a clock rollback without changing the system clock.
            let prior = RowndState(lastUpdateTs: .distantFuture)
            let encoded = try #require(try prior.toJson())
            try #require(Storage.shared.set(encoded, forKey: "RowndState"))
            let updated = await MainActor.run {
                let store = Store(reducer: rowndStateReducer, state: prior)
                store.dispatch(SetAppConfig(payload: AppConfigState(id: "first-update")))
                let firstRevision = store.state.lastUpdateTs
                #expect(firstRevision > prior.lastUpdateTs)
                store.dispatch(SetAppConfig(payload: AppConfigState(id: "second-update")))
                #expect(store.state.lastUpdateTs > firstRevision)

                // Schedule through the notification handler's path while the save is pending.
                store.state.scheduleReload(store)
                return store.state!
            }

            let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
            var persisted: RowndState?
            repeat {
                if let data = Storage.shared.get(forKey: "RowndState")?.data(using: .utf8) {
                    persisted = try JSONDecoder().decode(RowndState.self, from: data)
                }
                if persisted?.appConfig.id == "second-update" { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            } while DispatchTime.now().uptimeNanoseconds < deadline

            #expect(persisted?.appConfig == updated.appConfig)
            #expect(persisted?.lastUpdateTs == updated.lastUpdateTs)
        }
    }

    @Test @MainActor
    func initializationAndReloadPreserveIncomingRevision() {
        let prior = RowndState(clockSyncState: .synced, lastUpdateTs: .distantFuture)
        let incoming = RowndState(lastUpdateTs: Date(timeIntervalSinceReferenceDate: 1_000))
        let initialized = rowndStateReducer(action: InitializeRowndState(payload: incoming), state: prior)
        let reloaded = rowndStateReducer(action: ReloadRowndState(payload: incoming), state: prior)

        #expect(initialized.lastUpdateTs == incoming.lastUpdateTs)
        #expect(reloaded.lastUpdateTs == incoming.lastUpdateTs)
        #expect(initialized.clockSyncState == .synced)
        #expect(reloaded.clockSyncState == .synced)
    }

    @Test(arguments: [-1.0, 0.0, 1.0])
    func reloadOnlyAppliesNewerPersistedState(timestampOffset: TimeInterval) async throws {
        try await withGlobalTestLock {
            let originalState = Storage.shared.get(forKey: "RowndState")
            defer {
                if let originalState {
                    Storage.shared.set(originalState, forKey: "RowndState")
                } else {
                    Storage.shared.remove(forKey: "RowndState")
                }
            }

            let timestamp = Date(timeIntervalSince1970: 1_000)
            let liveState = RowndState(
                isStateLoaded: true,
                clockSyncState: .synced,
                appConfig: AppConfigState(isLoading: true, id: "live-config"),
                lastUpdateTs: timestamp
            )
            let persistedState = RowndState(
                appConfig: AppConfigState(id: "persisted-config"),
                lastUpdateTs: timestamp.addingTimeInterval(timestampOffset)
            )
            let encoded = try #require(try persistedState.toJson())
            #expect(Storage.shared.set(encoded, forKey: "RowndState"))
            let store = await MainActor.run {
                Store(reducer: rowndStateReducer, state: liveState)
            }

            await liveState.reload(store)

            await MainActor.run {
                #expect(store.state.appConfig == (timestampOffset > 0
                    ? persistedState.appConfig : liveState.appConfig))
                #expect(store.state.lastUpdateTs == (timestampOffset > 0
                    ? persistedState.lastUpdateTs : liveState.lastUpdateTs))
                #expect(store.state.clockSyncState == .synced)
                #expect(store.state.isStateLoaded)
            }
        }
    }
}
