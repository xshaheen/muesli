import Foundation

struct OrderedCompletionBuffer<Value> {
    private var completed: [UInt64: Value] = [:]
    private var nextSequence: UInt64 = 0

    var count: Int { completed.count }

    mutating func insert(_ value: Value, sequence: UInt64) -> [Value] {
        guard sequence >= nextSequence else { return [] }
        completed[sequence] = value
        var ready: [Value] = []
        while let value = completed.removeValue(forKey: nextSequence) {
            ready.append(value)
            nextSequence &+= 1
        }
        return ready
    }
}

/// Serializes completed dictations while allowing the recorder to start the next one.
/// The queue is main-actor owned because job payloads include captured UI context.
@MainActor
final class OrderedDictationJobQueue<Job: Identifiable> {
    typealias Handler = @MainActor (Job) async -> Void

    private var pending: [Job] = []
    private var pendingHead = 0
    private var current: Job?
    private var currentTask: Task<Void, Never>?
    private let handler: Handler
    private let onCurrentCancellationRequested: @MainActor (Job) async -> Void
    private let onCancel: @MainActor (Job) async -> Void
    private let onCountChanged: @MainActor (Int) -> Void

    var count: Int {
        pending.count - pendingHead + (current == nil ? 0 : 1)
    }

    init(
        handler: @escaping Handler,
        onCurrentCancellationRequested: @escaping @MainActor (Job) async -> Void = { _ in },
        onCancel: @escaping @MainActor (Job) async -> Void = { _ in },
        onCountChanged: @escaping @MainActor (Int) -> Void = { _ in }
    ) {
        self.handler = handler
        self.onCurrentCancellationRequested = onCurrentCancellationRequested
        self.onCancel = onCancel
        self.onCountChanged = onCountChanged
    }

    func enqueue(_ job: Job) {
        pending.append(job)
        onCountChanged(count)
        startNextIfNeeded()
    }

    func cancel(id: Job.ID) async {
        if let current, current.id == id {
            await onCurrentCancellationRequested(current)
            currentTask?.cancel()
            return
        }
        guard let index = pending[pendingHead...].firstIndex(where: { $0.id == id }) else { return }
        let job = pending.remove(at: index)
        await onCancel(job)
        onCountChanged(count)
    }

    /// Cancels the active worker and removes every queued job, waiting until the
    /// active worker has finished its terminal cleanup before returning.
    func cancelAllAndWait() async {
        if let current {
            await onCurrentCancellationRequested(current)
            currentTask?.cancel()
        }
        let queued = Array(pending[pendingHead...])
        pending.removeAll(keepingCapacity: true)
        pendingHead = 0
        for job in queued {
            await onCancel(job)
        }
        onCountChanged(count)
        await currentTask?.value
    }

    private func startNextIfNeeded() {
        guard current == nil, pendingHead < pending.count else { return }
        let job = pending[pendingHead]
        pendingHead += 1
        compactPendingJobsIfNeeded()
        current = job
        currentTask = Task { [weak self] in
            guard let self else { return }
            await handler(job)
            finishCurrent(id: job.id)
        }
    }

    private func compactPendingJobsIfNeeded() {
        guard pendingHead > 0 else { return }
        if pendingHead == pending.count {
            pending.removeAll(keepingCapacity: true)
            pendingHead = 0
        } else if pendingHead >= 64, pendingHead * 2 >= pending.count {
            pending.removeFirst(pendingHead)
            pendingHead = 0
        }
    }

    private func finishCurrent(id: Job.ID) {
        guard current?.id == id else { return }
        current = nil
        currentTask = nil
        onCountChanged(count)
        startNextIfNeeded()
    }
}
