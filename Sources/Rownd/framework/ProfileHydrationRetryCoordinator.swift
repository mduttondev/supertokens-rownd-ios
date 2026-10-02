import Foundation

internal actor ProfileHydrationRetryCoordinator {
    enum AttemptResult {
        case retry
        case stop
    }

    typealias Sleep = (UInt64) async throws -> Void

    private let delays: [UInt64]
    private let sleep: Sleep
    private var scheduledIdentity: SuperTokensSessionBridge.StableSessionIdentity?
    private var task: Task<Void, Never>?
    private var taskID: UUID?

    init(
        delays: [UInt64] = [1_000_000_000, 2_000_000_000, 4_000_000_000],
        sleep: @escaping Sleep = { try await Task.sleep(nanoseconds: $0) }
    ) {
        self.delays = delays
        self.sleep = sleep
    }

    func schedule(
        for identity: SuperTokensSessionBridge.StableSessionIdentity,
        attempt: @escaping (SuperTokensSessionBridge.StableSessionIdentity) async -> AttemptResult
    ) {
        if scheduledIdentity == identity, task != nil {
            return
        }

        task?.cancel()
        scheduledIdentity = identity
        let taskID = UUID()
        self.taskID = taskID
        task = Task {
            for delay in delays {
                do {
                    try await sleep(delay)
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                if await attempt(identity) == .stop {
                    break
                }
            }
            finish(identity: identity, taskID: taskID)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        taskID = nil
        scheduledIdentity = nil
    }

    func isScheduled(for identity: SuperTokensSessionBridge.StableSessionIdentity) -> Bool {
        scheduledIdentity == identity && task != nil
    }

    // Joins the task captured here, including its cleanup, but not any replacement task.
    func waitForCurrentTaskToFinish() async {
        await task?.value
    }

    private func finish(
        identity: SuperTokensSessionBridge.StableSessionIdentity,
        taskID: UUID
    ) {
        guard scheduledIdentity == identity, self.taskID == taskID else { return }
        task = nil
        self.taskID = nil
        scheduledIdentity = nil
    }
}
