import Foundation
import ReSwift
import XCTest

@testable import Rownd

final class NetworkTimeManagerTests: XCTestCase {
    private let reference = Date(timeIntervalSince1970: 1_700_000_000)
    // Independently encoded NTP timestamps: Unix 1700000001.125 and .1875.
    private let receivedBytes: [UInt8] = [0xe8, 0xfe, 0x6f, 0x81, 0x20, 0, 0, 0]
    private let sentBytes: [UInt8] = [0xe8, 0xfe, 0x6f, 0x81, 0x30, 0, 0, 0]

    private func response(request: Data, received: [UInt8], sent: [UInt8]) -> Data {
        var packet = Data(repeating: 0, count: 48)
        packet[0] = 0x24
        packet[1] = 2
        packet.replaceSubrange(24..<32, with: request[40..<48])
        packet.replaceSubrange(32..<40, with: received)
        packet.replaceSubrange(40..<48, with: sent)
        return packet
    }

    func testRequestEncodingAndInvalidDates() throws {
        let request = try XCTUnwrap(NTPPacket.request(at: reference.addingTimeInterval(0.5)))
        XCTAssertEqual(Array(request[40..<48]), [0xe8, 0xfe, 0x6f, 0x80, 0x80, 0, 0, 0])
        let beforeEpoch = try XCTUnwrap(NTPPacket.request(at: Date(timeIntervalSince1970: -2_208_988_800.5)))
        XCTAssertEqual(Array(beforeEpoch[40..<48]), [0xff, 0xff, 0xff, 0xff, 0x80, 0, 0, 0])
        let afterRollover = try XCTUnwrap(NTPPacket.request(at: Date(timeIntervalSince1970: 2_085_978_496.25)))
        XCTAssertEqual(Array(afterRollover[40..<48]), [0, 0, 0, 0, 0x40, 0, 0, 0])
        for invalid in [Double.nan, .infinity, -.infinity] {
            XCTAssertNil(NTPPacket.request(at: Date(timeIntervalSince1970: invalid)))
        }
    }

    func testNTPResponseCorrectsForMonotonicRoundTripLatency() throws {
        let request = try XCTUnwrap(NTPPacket.request(at: reference))
        let packet = response(request: request, received: receivedBytes, sent: sentBytes)
        let corrected = try XCTUnwrap(NTPPacket.correctedTime(response: packet, request: request, reference: reference, elapsed: 0.25))
        XCTAssertEqual(corrected.timeIntervalSince1970, 1_700_000_001.28125, accuracy: 0.000001)
        // Wall-clock adjustments cannot change latency; the reference only selects the era.
        for jump in [-86_400.0, 86_400.0] {
            let shifted = try XCTUnwrap(NTPPacket.correctedTime(response: packet, request: request, reference: reference.addingTimeInterval(jump), elapsed: 0.25))
            XCTAssertEqual(shifted, corrected)
        }
    }

    func testEraUnfoldingAcross2036Rollover() throws {
        let rollover = Date(timeIntervalSince1970: 2_085_978_496)
        for reference in [rollover.addingTimeInterval(-1), rollover.addingTimeInterval(1)] {
            let request = try XCTUnwrap(NTPPacket.request(at: reference))
            // Receive at era 0's last quarter-second; transmit at era 1 + 0.25s.
            let packet = response(request: request,
                                  received: [0xff, 0xff, 0xff, 0xff, 0xc0, 0, 0, 0],
                                  sent: [0, 0, 0, 0, 0x40, 0, 0, 0])
            let corrected = try XCTUnwrap(NTPPacket.correctedTime(response: packet, request: request, reference: reference, elapsed: 0.75))
            XCTAssertEqual(corrected.timeIntervalSince1970, 2_085_978_496.375, accuracy: 0.000001)
        }
    }

    func testInvalidNTPResponseIsRejected() throws {
        let request = try XCTUnwrap(NTPPacket.request(at: reference))
        let valid = response(request: request, received: receivedBytes, sent: sentBytes)
        var invalidPackets = [Data(valid.prefix(47))]
        for (index, value): (Int, UInt8) in [(0, 0x23), (0, 0xe4), (0, 0x14), (1, 0), (1, 16), (24, valid[24] ^ 1)] {
            var packet = valid
            packet[index] = value
            invalidPackets.append(packet)
        }
        invalidPackets.append(response(request: request, received: sentBytes, sent: receivedBytes))
        invalidPackets.append(response(request: request, received: Array(repeating: 0, count: 8), sent: sentBytes))
        for packet in invalidPackets {
            XCTAssertNil(NTPPacket.correctedTime(response: packet, request: request, reference: reference, elapsed: 0.25))
        }
        for elapsed in [-1.0, .nan, .infinity, -.infinity, 0.01] {
            XCTAssertNil(NTPPacket.correctedTime(response: valid, request: request, reference: reference, elapsed: elapsed))
        }
        XCTAssertNil(NTPPacket.correctedTime(response: valid, request: request, reference: Date(timeIntervalSince1970: .nan), elapsed: 0.25))
        // Tiny representational differences must not reject an otherwise possible response.
        let rounded = try XCTUnwrap(NTPPacket.correctedTime(response: valid, request: request, reference: reference, elapsed: 0.0625 - 0.0000001))
        XCTAssertEqual(rounded.timeIntervalSince1970, 1_700_000_001.1875, accuracy: 0.000001)
    }

    func testSuccessfulSyncAdvancesFromMonotonicClock() async throws {
        let networkDate = reference
        let fetchUptime = ClockReference.now() - 120
        let manager = NetworkTimeManager(fetch: { (networkDate, fetchUptime) })
        XCTAssertNil(manager.currentTime)
        let synced = await manager.fetchWorldTime()
        XCTAssertTrue(synced)
        let before = ClockReference.now()
        let current = try XCTUnwrap(manager.currentTime)
        let after = ClockReference.now()
        XCTAssertGreaterThanOrEqual(current.timeIntervalSince(networkDate), before - fetchUptime - 0.000001)
        XCTAssertLessThanOrEqual(current.timeIntervalSince(networkDate), after - fetchUptime + 0.000001)
        let worldBefore = ClockReference.now()
        let time = await manager.getCurrentWorldTime()
        XCTAssertGreaterThanOrEqual(time.timeIntervalSince(networkDate), worldBefore - fetchUptime - 0.000001)
        XCTAssertLessThanOrEqual(time.timeIntervalSince(networkDate), ClockReference.now() - fetchUptime + 0.000001)
    }

    func testFailedSyncFallsBackToDeviceClock() async {
        let manager = NetworkTimeManager(fetch: { nil })
        let synced = await manager.fetchWorldTime()
        XCTAssertFalse(synced)
        XCTAssertNil(manager.currentTime)
        let before = Date()
        let time = await manager.getCurrentWorldTime()
        XCTAssertGreaterThanOrEqual(time, before)
        XCTAssertLessThanOrEqual(time, Date())
    }

    func testSlowSyncMovesFromWaitingToUnknownThenSynced() async {
        let started = expectation(description: "Fetch started")
        let unknown = expectation(description: "Clock becomes unknown while fetch is pending")
        let synced = expectation(description: "Clock becomes synced after fetch completes")
        let fetch = ControlledTimeFetch()
        let observer = ClockStateObserver { state in
            if state == .unknown { unknown.fulfill() }
            if state == .synced { synced.fulfill() }
        }
        let store = createStore()
        let manager = NetworkTimeManager(fetch: { await fetch.wait(started: started) })
        await MainActor.run {
            store.dispatch(SetClockSync(clockSyncState: .waiting))
            store.subscribe(observer) { $0.select { $0.clockSyncState }.skipRepeats() }
            manager.start(store: store)
        }
        await fulfillment(of: [started, unknown], timeout: 5)
        await MainActor.run { XCTAssertEqual(store.state.clockSyncState, .unknown) }
        XCTAssertNil(manager.currentTime)
        await fetch.complete()
        await fulfillment(of: [synced], timeout: 5)
        await MainActor.run {
            XCTAssertEqual(store.state.clockSyncState, .synced)
            store.unsubscribe(observer)
        }
    }

    func testFailedSyncLeavesClockUnknown() async {
        let unknown = expectation(description: "Clock becomes unknown after failed fetch")
        let observer = ClockStateObserver { if $0 == .unknown { unknown.fulfill() } }
        let store = createStore()
        let manager = NetworkTimeManager(fetch: { nil })
        await MainActor.run {
            store.dispatch(SetClockSync(clockSyncState: .waiting))
            store.subscribe(observer) { $0.select { $0.clockSyncState }.skipRepeats() }
            manager.start(store: store)
        }
        await fulfillment(of: [unknown], timeout: 5)
        await MainActor.run {
            XCTAssertEqual(store.state.clockSyncState, .unknown)
            store.unsubscribe(observer)
        }
        XCTAssertNil(manager.currentTime)
    }
}

private actor ControlledTimeFetch {
    private var continuation: CheckedContinuation<(Date, TimeInterval)?, Never>?

    func wait(started: XCTestExpectation) async -> (Date, TimeInterval)? {
        await withCheckedContinuation {
            continuation = $0
            started.fulfill()
        }
    }

    func complete() {
        continuation?.resume(returning: (Date(), ClockReference.now()))
        continuation = nil
    }
}

private final class ClockStateObserver: StoreSubscriber {
    private let onChange: (ClockSyncState) -> Void

    init(onChange: @escaping (ClockSyncState) -> Void) {
        self.onChange = onChange
    }

    func newState(state: ClockSyncState) {
        onChange(state)
    }
}
