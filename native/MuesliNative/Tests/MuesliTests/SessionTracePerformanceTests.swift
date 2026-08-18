import Foundation
import MuesliCore
import Testing
@testable import MuesliNativeApp

@Suite("Session trace performance", .serialized)
struct SessionTracePerformanceTests {
    @Test("trace enqueue and terminal durability stay below committed caps")
    func traceOverheadCap() async throws {
        let baselineURL = try #require(Bundle.module.resourceURL?
            .appendingPathComponent("Fixtures/TranscriptionQuality/baseline-v1.json"))
        let caps = try JSONDecoder().decode(PerformanceBaseline.self, from: Data(contentsOf: baselineURL))
            .traceOverhead
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-trace-performance-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: databaseURL.path + suffix)
            }
        }
        let store = try SessionTraceStore(databaseURL: databaseURL)
        var enqueueMilliseconds: [Double] = []
        var terminalMilliseconds: [Double] = []

        for index in 0 ..< 105 {
            let trace = SessionRunTrace(store: store, kind: .dictation, backendIdentity: "fixture:benchmark")
            let enqueueStart = ContinuousClock.now
            await trace.recordStageStarted("speech_recognition", metadata: ["sample": "\(index)"])
            let enqueue = milliseconds(from: enqueueStart.duration(to: .now))
            await trace.storeArtifact("bounded fixture \(index)", kind: .rawASR)
            let terminalStart = ContinuousClock.now
            #expect(await trace.claimTerminal(.success))
            let terminal = milliseconds(from: terminalStart.duration(to: .now))
            if index >= 5 {
                enqueueMilliseconds.append(enqueue)
                terminalMilliseconds.append(terminal)
            }
        }

        let enqueueP95 = percentile(enqueueMilliseconds, 0.95)
        let terminalP95 = percentile(terminalMilliseconds, 0.95)
        print("TRACE_OVERHEAD enqueue_p50_ms=\(percentile(enqueueMilliseconds, 0.50)) enqueue_p95_ms=\(enqueueP95) enqueue_max_ms=\(enqueueMilliseconds.max() ?? 0) terminal_p50_ms=\(percentile(terminalMilliseconds, 0.50)) terminal_p95_ms=\(terminalP95) terminal_max_ms=\(terminalMilliseconds.max() ?? 0)")
        #expect(enqueueP95 <= caps.committedEnqueueCapMilliseconds)
        #expect(terminalP95 <= caps.committedTerminalDurableCapMilliseconds)
        #expect(try await store.list(limit: 200).count == 105)
    }

    private func milliseconds(from duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    private func percentile(_ values: [Double], _ percentile: Double) -> Double {
        let sorted = values.sorted()
        return sorted[max(0, Int(ceil(percentile * Double(sorted.count))) - 1)]
    }
}

private struct PerformanceBaseline: Decodable {
    let traceOverhead: TraceOverhead

    struct TraceOverhead: Decodable {
        let committedEnqueueCapMilliseconds: Double
        let committedTerminalDurableCapMilliseconds: Double
    }
}
