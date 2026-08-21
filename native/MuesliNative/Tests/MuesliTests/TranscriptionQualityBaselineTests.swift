import CryptoKit
import Foundation
import MuesliCore
import Testing

private typealias Sample = TranscriptionQualitySample
private typealias Metric = TranscriptionQualityScoring.Metric
private typealias Distribution = TranscriptionQualityScoring.Distribution

/// Verifies the immutable fixture, scoring, and timing schema. It does not run
/// ASR; behavior PRs publish a new measured capture before changing baselines.
@Suite("Transcription quality fixture contract")
struct TranscriptionQualityFixtureContractTests {
    @Test("fixture provenance, hashes, and size bounds are frozen")
    func fixtureContract() throws {
        let fixture = try Fixture.load()
        let manifest = try fixture.decode(Manifest.self, file: "manifest.json")

        #expect(manifest.schemaVersion == 1)
        #expect(manifest.files.count == 4)
        #expect(fixture.regularFilePaths == Set(manifest.files.map(\.path) + ["manifest.json"]))
        #expect(fixture.samples.count == 9)
        #expect(Dictionary(grouping: fixture.samples, by: \.cohort).values.map(\.count).sorted() == [3, 3, 3])
        #expect(Set(fixture.samples.map(\.cohort)) == [.english, .arabic, .arabicEnglish])
        #expect(fixture.totalBytes <= manifest.maximumCorpusBytes)

        for sample in fixture.samples {
            #expect(sample.reference.utf8.count <= manifest.maximumTextFieldBytes)
            #expect(sample.rawASR.utf8.count <= manifest.maximumTextFieldBytes)
            #expect(sample.finalOutput.utf8.count <= manifest.maximumTextFieldBytes)
            #expect(sample.backend == "whisperkit")
            #expect(sample.model == "whisper-tiny")
            #expect(sample.audioDurationSeconds > 0)
            #expect(sample.asrSeconds > 0)
            #expect(sample.endToEndSeconds >= sample.asrSeconds)
            #expect(sample.audioBytes > 0)
            #expect(sample.audioSHA256.count == 64)
        }

        for entry in manifest.files {
            let data = try Data(contentsOf: fixture.root.appendingPathComponent(entry.path))
            #expect(data.count == entry.bytes)
            #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == entry.sha256)
        }
    }

    @Test("scores and latency distributions reproduce the committed baseline")
    func baselineRecomputes() throws {
        let fixture = try Fixture.load()
        let baseline = try fixture.decode(Baseline.self, file: "baseline-v1.json")

        #expect(baseline.schemaVersion == 1)
        #expect(baseline.sampleCount == fixture.samples.count)
        #expect(baseline.samplesPerCohort == 3)
        assertScores(baseline.rawASR, samples: fixture.samples, output: \.rawASR)
        assertScores(baseline.finalOutput, samples: fixture.samples, output: \.finalOutput)

        assertDistribution(
            baseline.timing.asrSeconds,
            equals: Distribution(values: fixture.samples.map(\.asrSeconds))
        )
        assertDistribution(
            baseline.timing.endToEndSeconds,
            equals: Distribution(values: fixture.samples.map(\.endToEndSeconds))
        )
        assertDistribution(
            baseline.timing.realTimeFactor,
            equals: Distribution(values: fixture.samples.map { $0.asrSeconds / $0.audioDurationSeconds })
        )
    }

    private func assertScores(
        _ expected: ScoreGroups,
        samples: [Sample],
        output: KeyPath<Sample, String>
    ) {
        assertMetric(expected.overall, equals: Metric(samples: samples, output: output))
        assertMetric(expected.english, equals: Metric(samples: samples.filter { $0.cohort == .english }, output: output))
        assertMetric(expected.arabic, equals: Metric(samples: samples.filter { $0.cohort == .arabic }, output: output))
        let mixedSamples = samples.filter { $0.cohort == .arabicEnglish }
        let mixed = Metric(samples: mixedSamples, output: output)
        assertMetric(expected.arabicEnglish, equals: mixed)
        expectEqual(
            expected.arabicEnglish.latinTokenPreservation,
            TranscriptionQualityScoring.tokenPreservation(samples: mixedSamples, output: output, script: .latin)
        )
        expectEqual(
            expected.arabicEnglish.arabicTokenPreservation,
            TranscriptionQualityScoring.tokenPreservation(samples: mixedSamples, output: output, script: .arabic)
        )
    }

    private func assertMetric(_ expected: Score, equals actual: Metric) {
        expectEqual(expected.wer, actual.wer)
        expectEqual(expected.cer, actual.cer)
    }

    private func assertDistribution(_ expected: Distribution, equals actual: Distribution) {
        #expect(expected.count == actual.count)
        expectEqual(expected.p50, actual.p50)
        expectEqual(expected.p95, actual.p95)
        expectEqual(expected.maximum, actual.maximum)
    }

    private func expectEqual(_ expected: Double?, _ actual: Double) {
        #expect(expected != nil)
        if let expected {
            #expect(abs(expected - actual) < 1e-12)
        }
    }
}

private struct Fixture {
    let root: URL
    let samples: [Sample]
    let totalBytes: Int
    let regularFilePaths: Set<String>

    static func load() throws -> Fixture {
        let root = try #require(Bundle.module.resourceURL?
            .appendingPathComponent("Fixtures/TranscriptionQuality", isDirectory: true))
        let data = try Data(contentsOf: root.appendingPathComponent("samples.jsonl"))
        let decoder = JSONDecoder()
        let samples = try data.split(separator: 0x0A).map { try decoder.decode(Sample.self, from: Data($0)) }
        let enumerator = try #require(FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        ))
        var totalBytes = 0
        var regularFilePaths = Set<String>()
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true {
                totalBytes += values.fileSize ?? 0
                regularFilePaths.insert(String(url.path.dropFirst(root.path.count + 1)))
            }
        }
        return Fixture(
            root: root,
            samples: samples,
            totalBytes: totalBytes,
            regularFilePaths: regularFilePaths
        )
    }

    func decode<Value: Decodable>(_ type: Value.Type, file: String) throws -> Value {
        try JSONDecoder().decode(Value.self, from: Data(contentsOf: root.appendingPathComponent(file)))
    }
}

private struct Manifest: Decodable {
    let schemaVersion: Int
    let maximumCorpusBytes: Int
    let maximumTextFieldBytes: Int
    let files: [FileEntry]

    struct FileEntry: Decodable {
        let path: String
        let bytes: Int
        let sha256: String
    }
}

private struct Baseline: Decodable {
    let schemaVersion: Int
    let sampleCount: Int
    let samplesPerCohort: Int
    let rawASR: ScoreGroups
    let finalOutput: ScoreGroups
    let timing: Timing
}

private struct ScoreGroups: Decodable {
    let overall: Score
    let english: Score
    let arabic: Score
    let arabicEnglish: Score
}

private struct Score: Decodable {
    let wer: Double
    let cer: Double
    let latinTokenPreservation: Double?
    let arabicTokenPreservation: Double?
}

private struct Timing: Decodable {
    let asrSeconds: Distribution
    let endToEndSeconds: Distribution
    let realTimeFactor: Distribution
}
