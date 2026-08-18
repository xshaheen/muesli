import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("MeetingSessionDiagnostics")
struct MeetingSessionDiagnosticsTests {

    @Test("final report retains content-free metadata without duplicating transcript or audio")
    func finalReportIsContentFree() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceDirectory = root.appendingPathComponent("RetainedRecordings", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let rawMicURL = sourceDirectory.appendingPathComponent("credential-secret-raw.wav")
        let systemAudioURL = sourceDirectory.appendingPathComponent("personal-context-system.wav")
        try writeWav(samples: [0, 16_384, -16_384, 0], to: rawMicURL)
        try writeWav(samples: [8_192, -8_192], to: systemAudioURL)

        let diagnostics = MeetingSessionDiagnostics(
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            rootURL: root,
            enabledOverride: true
        )
        diagnostics.appendCleanedMicSamples([0, 4_096, -4_096])
        diagnostics.writeFinalReport(
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_030),
            systemCapture: nil,
            micRecorder: nil,
            micHealth: micHealthSnapshot(
                rawMic: AudioSampleStatsSnapshot(sampleCount: 4, zeroSampleCount: 2, rms: 0.35, peak: 0.5),
                systemAudio: AudioSampleStatsSnapshot(sampleCount: 2, zeroSampleCount: 0, rms: 0.25, peak: 0.25)
            ),
            aec: emptyAecSnapshot,
            micChunks: emptyChunkSnapshot,
            systemChunks: emptyChunkSnapshot,
            diarizationSegments: nil,
            protectedSystemSegmentCount: 0
        )

        let runs = MeetingSessionDiagnostics.loadStoredSummaries(rootURL: root)
        let run = try #require(runs.first)
        let reportURL = root
            .appendingPathComponent("MeetingDiagnostics", isDirectory: true)
            .appendingPathComponent(run.id, isDirectory: true)
            .appendingPathComponent("diagnostics.json")
        let report = try String(contentsOf: reportURL, encoding: .utf8)

        #expect(runs.count == 1)
        #expect(run.summary.rawMic?.sampleCount == 4)
        #expect(run.summary.systemAudio?.sampleCount == 2)
        #expect(run.summary.cleanedMicAec.sampleCount == 3)
        for forbidden in [
            "private meeting title",
            "raw transcript",
            "credential-secret-raw.wav",
            "personal-context-system.wav",
            sourceDirectory.path,
            "raw-transcript.txt",
        ] {
            #expect(!report.localizedCaseInsensitiveContains(forbidden))
        }

        let storedFiles = try FileManager.default.contentsOfDirectory(
            at: reportURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        #expect(storedFiles.map(\.lastPathComponent) == ["diagnostics.json"])
        #expect(FileManager.default.fileExists(atPath: rawMicURL.path))
        #expect(FileManager.default.fileExists(atPath: systemAudioURL.path))
    }

    @Test("stored metadata is limited by age, count, and total bytes")
    func retentionIsAgeCountAndByteBounded() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()

        for index in 0..<12 {
            let diagnostics = MeetingSessionDiagnostics(
                startedAt: now.addingTimeInterval(Double(index)),
                rootURL: root,
                enabledOverride: true
            )
            diagnostics.writeFinalReport(
                startedAt: now,
                endedAt: now,
                systemCapture: nil,
                micRecorder: nil,
                micHealth: nil,
                aec: emptyAecSnapshot,
                micChunks: emptyChunkSnapshot,
                systemChunks: emptyChunkSnapshot,
                diarizationSegments: nil,
                protectedSystemSegmentCount: 0,
                retentionReferenceDate: now
            )
        }

        var runs = MeetingSessionDiagnostics.loadStoredSummaries(rootURL: root, now: now)
        #expect(runs.count == MeetingSessionDiagnostics.maximumStoredRunCount)
        guard runs.count >= 2 else { return }

        let staleDirectory = root
            .appendingPathComponent("MeetingDiagnostics", isDirectory: true)
            .appendingPathComponent(runs[0].id, isDirectory: true)
        let staleDate = now.addingTimeInterval(-MeetingSessionDiagnostics.retentionDuration - 1)
        try FileManager.default.setAttributes([.modificationDate: staleDate], ofItemAtPath: staleDirectory.path)

        let oversizedDirectory = root
            .appendingPathComponent("MeetingDiagnostics", isDirectory: true)
            .appendingPathComponent(runs[1].id, isDirectory: true)
        try Data(repeating: 0, count: MeetingSessionDiagnostics.maximumStoredRunBytes)
            .write(to: oversizedDirectory.appendingPathComponent("padding.bin"))

        runs = MeetingSessionDiagnostics.loadStoredSummaries(rootURL: root, now: now)
        let retainedBytes = try runs.reduce(into: 0) { total, run in
            let directory = root
                .appendingPathComponent("MeetingDiagnostics", isDirectory: true)
                .appendingPathComponent(run.id, isDirectory: true)
            total += try directorySize(directory)
        }

        #expect(runs.count < MeetingSessionDiagnostics.maximumStoredRunCount)
        #expect(!runs.contains { $0.id == staleDirectory.lastPathComponent })
        #expect(!runs.contains { $0.id == oversizedDirectory.lastPathComponent })
        #expect(retainedBytes <= MeetingSessionDiagnostics.maximumStoredTotalBytes)
    }

    @Test("clearing stored diagnostics is idempotent and preserves retained recordings")
    func clearingIsIdempotentAndPreservesRecordings() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recordingURL = root.appendingPathComponent("RetainedRecordings/meeting.m4a")
        try FileManager.default.createDirectory(
            at: recordingURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([1, 2, 3]).write(to: recordingURL)

        _ = MeetingSessionDiagnostics(
            startedAt: Date(),
            rootURL: root,
            enabledOverride: true
        )
        let first = try MeetingSessionDiagnostics.clearStoredRuns(rootURL: root)
        let second = try MeetingSessionDiagnostics.clearStoredRuns(rootURL: root)

        #expect(first.activeRunsPreserved == 0)
        #expect(second.activeRunsPreserved == 0)
        #expect(MeetingSessionDiagnostics.loadStoredSummaries(rootURL: root).isEmpty)
        #expect(FileManager.default.fileExists(atPath: recordingURL.path))
    }

    @Test("clear preserves an active writer and removes it after finalization")
    func clearPreservesActiveWriter() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let diagnostics = MeetingSessionDiagnostics(
            startedAt: now.addingTimeInterval(-30),
            rootURL: root,
            enabledOverride: true
        )

        let duringWrite = try MeetingSessionDiagnostics.clearStoredRuns(rootURL: root)
        #expect(duringWrite.activeRunsPreserved == 1)

        diagnostics.writeFinalReport(
            startedAt: now.addingTimeInterval(-30),
            endedAt: now,
            systemCapture: nil,
            micRecorder: nil,
            micHealth: nil,
            aec: emptyAecSnapshot,
            micChunks: emptyChunkSnapshot,
            systemChunks: emptyChunkSnapshot,
            diarizationSegments: nil,
            protectedSystemSegmentCount: 0,
            retentionReferenceDate: now
        )
        #expect(MeetingSessionDiagnostics.loadStoredSummaries(rootURL: root, now: now).count == 1)

        let afterWrite = try MeetingSessionDiagnostics.clearStoredRuns(rootURL: root)
        #expect(afterWrite.activeRunsPreserved == 0)
        #expect(MeetingSessionDiagnostics.loadStoredSummaries(rootURL: root, now: now).isEmpty)
    }

    @Test("store preparation purges legacy rich runs and preserves retained recordings")
    func preparationPurgesLegacyRichRuns() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyRun = root.appendingPathComponent(
            "MeetingDiagnostics/private-meeting-title",
            isDirectory: true
        )
        let recordingURL = root.appendingPathComponent("RetainedRecordings/keep.m4a")
        try FileManager.default.createDirectory(at: legacyRun, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: recordingURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("raw transcript credential".utf8)
            .write(to: legacyRun.appendingPathComponent("raw-transcript.txt"))
        try Data([1, 2, 3]).write(to: legacyRun.appendingPathComponent("raw-mic-full-session.wav"))
        try Data("{}".utf8).write(to: legacyRun.appendingPathComponent("diagnostics.json"))
        try Data([4, 5, 6]).write(to: recordingURL)

        MeetingSessionDiagnostics.prepareStore(rootURL: root)

        #expect(!FileManager.default.fileExists(atPath: legacyRun.path))
        #expect(FileManager.default.fileExists(atPath: recordingURL.path))
    }

    private var emptyAecSnapshot: MeetingAecDiagnosticsSnapshot {
        MeetingAecDiagnosticsSnapshot(
            ready: false,
            processor: nil,
            frameSize: 0,
            processedFrames: 0,
            fullReferenceFrames: 0,
            partialReferenceFrames: 0,
            missingReferenceFrames: 0,
            systemSamplesReceived: 0,
            micSamplesReceived: 0,
            bufferedSystemSamples: 0,
            bufferedMicSamples: 0,
            currentDelayMs: 0,
            delayHistory: [],
            delaySkipHistory: []
        )
    }

    private var emptyChunkSnapshot: MeetingTranscriptChunkHealthSnapshot {
        MeetingTranscriptChunkHealthSnapshot(
            successfulChunkCount: 0,
            emptyChunkCount: 0,
            failedChunkCount: 0
        )
    }

    private func micHealthSnapshot(
        rawMic: AudioSampleStatsSnapshot,
        systemAudio: AudioSampleStatsSnapshot
    ) -> MeetingMicHealthSnapshot {
        MeetingMicHealthSnapshot(
            state: .healthy,
            rawMic: rawMic,
            systemAudio: systemAudio,
            firstRawMicCallbackAt: nil,
            firstNonZeroMicAt: nil,
            firstSystemAudioAt: nil,
            lastRawMicCallbackAt: nil,
            lastNonZeroMicAt: nil,
            lastSystemAudioAt: nil,
            transitions: [],
            sustainedZeroMicWhileSystemActive: false,
            failover: nil,
            warningMessage: nil
        )
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-diagnostics-\(UUID().uuidString)", isDirectory: true)
    }

    private func writeWav(samples: [Int16], to url: URL) throws {
        var data = WavWriter.header(dataSize: UInt32(samples.count * MemoryLayout<Int16>.size))
        samples.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        try data.write(to: url)
    }

    private func directorySize(_ url: URL) throws -> Int {
        let enumerator = try #require(FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        ))
        var size = 0
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true {
                size += values.fileSize ?? 0
            }
        }
        return size
    }
}
