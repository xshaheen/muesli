import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Ordered dictation job queue")
struct OrderedDictationJobQueueTests {
    private struct Job: Identifiable {
        let id: Int
        let transcript: String
    }

    @Test("jobs retain their payload and complete in enqueue order")
    @MainActor
    func jobsCompleteInOrder() async {
        let firstJobGate = AsyncStream<Void>.makeStream()
        var started: [Int] = []
        var completed: [String] = []
        let queue = OrderedDictationJobQueue<Job> { job in
            started.append(job.id)
            if job.id == 1 {
                for await _ in firstJobGate.stream { break }
            }
            completed.append(job.transcript)
        }

        queue.enqueue(Job(id: 1, transcript: "first"))
        queue.enqueue(Job(id: 2, transcript: "second"))
        queue.enqueue(Job(id: 3, transcript: "third"))
        await Task.yield()

        #expect(started == [1])
        #expect(queue.count == 3)

        firstJobGate.continuation.yield()
        firstJobGate.continuation.finish()
        let deadline = ContinuousClock.now + .seconds(10)
        while queue.count > 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }

        #expect(started == [1, 2, 3])
        #expect(completed == ["first", "second", "third"])
        #expect(queue.count == 0)
    }

    @Test("cancelling a queued job does not disturb surrounding order")
    @MainActor
    func cancellationPreservesOrder() async {
        let firstJobGate = AsyncStream<Void>.makeStream()
        var completed: [Int] = []
        let queue = OrderedDictationJobQueue<Job> { job in
            if job.id == 1 {
                for await _ in firstJobGate.stream { break }
            }
            try? Task.checkCancellation()
            guard !Task.isCancelled else { return }
            completed.append(job.id)
        }

        queue.enqueue(Job(id: 1, transcript: "first"))
        queue.enqueue(Job(id: 2, transcript: "cancelled"))
        queue.enqueue(Job(id: 3, transcript: "third"))
        await queue.cancel(id: 2)
        firstJobGate.continuation.yield()
        firstJobGate.continuation.finish()

        let deadline = ContinuousClock.now + .seconds(10)
        while queue.count > 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }

        #expect(completed == [1, 3])
    }

    @Test("cancelling the active job advances to the next job")
    @MainActor
    func activeCancellationAdvancesQueue() async {
        var completed: [Int] = []
        let queue = OrderedDictationJobQueue<Job> { job in
            if job.id == 1 {
                do {
                    try await Task.sleep(for: .seconds(10))
                } catch {
                    return
                }
            }
            completed.append(job.id)
        }

        queue.enqueue(Job(id: 1, transcript: "cancelled"))
        queue.enqueue(Job(id: 2, transcript: "second"))
        await Task.yield()
        await queue.cancel(id: 1)

        let deadline = ContinuousClock.now + .seconds(10)
        while queue.count > 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }

        #expect(completed == [2])
        #expect(queue.count == 0)
    }

    @Test("active cancellation settles ownership before cancelling work")
    @MainActor
    func activeCancellationSettlesOwnershipFirst() async {
        var cancellationClaimed = false
        var workerObservedClaim = false
        let queue = OrderedDictationJobQueue<Job>(
            handler: { _ in
                do {
                    try await Task.sleep(for: .seconds(10))
                } catch {
                    workerObservedClaim = cancellationClaimed
                }
            },
            onCurrentCancellationRequested: { _ in
                cancellationClaimed = true
            }
        )

        queue.enqueue(Job(id: 1, transcript: "cancelled"))
        await Task.yield()
        await queue.cancel(id: 1)

        let deadline = ContinuousClock.now + .seconds(10)
        while queue.count > 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }

        #expect(cancellationClaimed)
        #expect(workerObservedClaim)
    }

    @Test("completed recordings wait for earlier stop callbacks")
    func outOfOrderStopCallbacks() {
        var buffer = OrderedCompletionBuffer<String>()

        #expect(buffer.insert("second", sequence: 1).isEmpty)
        #expect(buffer.count == 1)
        #expect(buffer.insert("first", sequence: 0) == ["first", "second"])
        #expect(buffer.count == 0)
    }

    @Test("large backlogs drain in FIFO order")
    @MainActor
    func largeBacklogDrainsInOrder() async {
        let firstJobGate = AsyncStream<Void>.makeStream()
        var completed: [Int] = []
        let queue = OrderedDictationJobQueue<Job> { job in
            if job.id == 0 {
                for await _ in firstJobGate.stream { break }
            }
            completed.append(job.id)
        }

        for id in 0..<256 {
            queue.enqueue(Job(id: id, transcript: "\(id)"))
        }
        #expect(queue.count == 256)

        firstJobGate.continuation.yield()
        firstJobGate.continuation.finish()
        let deadline = ContinuousClock.now + .seconds(10)
        while queue.count > 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }

        #expect(completed == Array(0..<256))
        #expect(queue.count == 0)
    }
}
