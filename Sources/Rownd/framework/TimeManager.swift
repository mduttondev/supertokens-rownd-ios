import Darwin
import Foundation
import Network
import OSLog
import ReSwift

struct NTPPacket {
    private static let epochOffset: TimeInterval = 2_208_988_800
    private static let eraLength: TimeInterval = 4_294_967_296

    static func request(at date: Date) -> Data? {
        var packet = Data(repeating: 0, count: 48)
        packet[0] = 0x23 // NTP version 4, client mode
        guard writeTimestamp(date, into: &packet, at: 40) else { return nil }
        return packet
    }

    static func correctedTime(response: Data, request: Data, reference: Date, elapsed: TimeInterval) -> Date? {
        guard elapsed.isFinite, elapsed >= 0, reference.timeIntervalSince1970.isFinite,
              response.count >= 48, request.count == 48,
              response[0] & 0x07 == 4, (3...4).contains((response[0] >> 3) & 0x07),
              response[0] >> 6 != 3, (1...15).contains(response[1]),
              response[24..<32] == request[40..<48],
               let serverReceived = readTimestamp(response, at: 32, reference: reference),
               let serverSent = readTimestamp(response, at: 40, reference: serverReceived),
              serverSent >= serverReceived else {
            return nil
        }

        let serverProcessing = serverSent.timeIntervalSince(serverReceived)
        // Allow sub-microsecond Date rounding, but reject impossible server timing.
        guard serverProcessing <= elapsed + 0.000001 else { return nil }
        // Only monotonic elapsed time contributes to latency, never a wall-clock delta.
        return serverSent.addingTimeInterval(max(0, elapsed - serverProcessing) / 2)
    }

    private static func writeTimestamp(_ date: Date, into packet: inout Data, at offset: Int) -> Bool {
        let time = date.timeIntervalSince1970 + epochOffset
        guard time.isFinite else { return false }
        // Wrap before conversion, including dates before 1900; never convert an unbounded Double.
        let wholeSeconds = floor(time)
        let remainder = wholeSeconds.truncatingRemainder(dividingBy: eraLength)
        let seconds = UInt64(remainder < 0 ? remainder + eraLength : remainder)
        let fraction = UInt64((time - wholeSeconds) * eraLength)
        let timestamp = (seconds << 32) | fraction
        for index in 0..<8 {
            packet[offset + index] = UInt8(truncatingIfNeeded: timestamp >> (56 - index * 8))
        }
        return true
    }

    private static func readTimestamp(_ packet: Data, at offset: Int, reference: Date) -> Date? {
        let bytes = packet[offset..<(offset + 8)]
        guard bytes.contains(where: { $0 != 0 }) else { return nil }
        let value = bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let seconds = Double(value >> 32) - epochOffset
        let fraction = Double(value & 0xffff_ffff) / eraLength
        // NTP omits the era: assume the true time is within half an era (~68 years)
        // of the explicit reference. Unfold transmit relative to receive across rollover.
        let era = ((reference.timeIntervalSince1970 - seconds - fraction) / eraLength).rounded()
        return Date(timeIntervalSince1970: seconds + fraction + era * eraLength)
    }
}

enum ClockReference {
    static func now() -> TimeInterval {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(mach_continuous_time()) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }
}

private final class NTPQuery {
    private let lock = NSLock()
    private var finished = false
    private let connection: NWConnection
    private let continuation: CheckedContinuation<(Date, TimeInterval)?, Never>

    init(continuation: CheckedContinuation<(Date, TimeInterval)?, Never>) {
        self.continuation = continuation
        connection = NWConnection(host: "time.cloudflare.com", port: 123, using: .udp)
    }

    func start() {
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                guard !lock.withLock({ finished }) else { return }
                let sent = Date()
                guard let request = NTPPacket.request(at: sent) else {
                    finish(nil)
                    return
                }
                let sentUptime = ClockReference.now()
                connection.send(content: request, completion: .contentProcessed { [self] error in
                    if error != nil { finish(nil) }
                })
                connection.receiveMessage { [self] data, _, _, error in
                    let uptime = ClockReference.now()
                    guard error == nil, let data = data,
                          let corrected = NTPPacket.correctedTime(response: data, request: request, reference: sent, elapsed: uptime - sentUptime) else {
                        finish(nil)
                        return
                    }
                    finish((corrected, uptime))
                }
            case .failed, .cancelled:
                finish(nil)
            default:
                break
            }
        }
        connection.start(queue: DispatchQueue.global(qos: .utility))
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { [self] in
            finish(nil)
        }
    }

    private func finish(_ result: (Date, TimeInterval)?) {
        let shouldFinish = lock.withLock {
            guard !finished else { return false }
            finished = true
            return true
        }
        guard shouldFinish else { return }
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation.resume(returning: result)
    }
}

class NetworkTimeManager {
    internal static let shared = NetworkTimeManager()

    private let log = Logger(subsystem: "io.rownd.sdk", category: "TimeManager")
    private let startLock = NSLock()
    private let stateLock = NSLock()
    private var didStart = false
    private var fetchTimeTask: Task<Bool, Never>?
    private var fetchedWorldTime: Date?
    private var fetchUptime: TimeInterval?
    private let fetch: () async -> (Date, TimeInterval)?

    init(fetch: @escaping () async -> (Date, TimeInterval)? = {
        await withCheckedContinuation { continuation in
            NTPQuery(continuation: continuation).start()
        }
    }) {
        self.fetch = fetch
    }

    internal var currentTime: Date? {
        let (fetchedWorldTime, fetchUptime) = stateLock.withLock {
            (self.fetchedWorldTime, self.fetchUptime)
        }
        guard let fetchedWorldTime = fetchedWorldTime, let fetchUptime = fetchUptime else {
            return nil
        }
        return fetchedWorldTime.addingTimeInterval(ClockReference.now() - fetchUptime)
    }

    // Starts process-wide synchronization once. The first store receives clock state updates.
    func start(store: Store<RowndState>) {
        let shouldStart = startLock.withLock {
            guard !didStart else {
                return false
            }
            didStart = true
            return true
        }
        guard shouldStart else {
            return
        }

        let ntpStart = Date()
        Task {
            guard await fetchWorldTime() else {
                return
            }

            await MainActor.run {
                if store.state.clockSyncState != .synced {
                    store.dispatch(SetClockSync(clockSyncState: .synced))
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if store.state.clockSyncState == .waiting {
                self.log.warning("TimeManager clock not synced after \(ntpStart.distance(to: Date())) seconds.")
                store.dispatch(SetClockSync(clockSyncState: .unknown))
            }
        }
    }

    func fetchWorldTime() async -> Bool {
        let task = Task { () -> Bool in
            defer {
                stateLock.withLock {
                    fetchTimeTask = nil
                }
            }

            guard let (date, uptime) = await fetch() else {
                log.warning("Error fetching network time")
                return false
            }
            stateLock.withLock {
                fetchedWorldTime = date
                fetchUptime = uptime
            }
            return true
        }

        stateLock.withLock {
            fetchTimeTask = task
        }
        return await task.value
    }

    func getCurrentWorldTime() async -> Date {
        let pendingTask: Task<Bool, Never>? = stateLock.withLock {
            self.fetchTimeTask
        }
        if let pendingTask = pendingTask {
            _ = await pendingTask.value
        }

        if currentTime == nil {
            _ = await fetchWorldTime()
        }

        guard let currentTime = currentTime else {
            log.warning("Network time not found. Using local time instead")
            return Date()
        }
        return currentTime
    }
}
