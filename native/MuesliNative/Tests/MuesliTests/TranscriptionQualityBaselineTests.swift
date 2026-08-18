import CryptoKit
import Foundation
import Testing

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
            tokenPreservation(samples: mixedSamples, output: output, script: .latin)
        )
        expectEqual(
            expected.arabicEnglish.arabicTokenPreservation,
            tokenPreservation(samples: mixedSamples, output: output, script: .arabic)
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

private struct Sample: Decodable {
    let id: String
    let cohort: Cohort
    let reference: String
    let rawASR: String
    let finalOutput: String
    let audioBytes: Int
    let audioSHA256: String
    let audioDurationSeconds: Double
    let asrSeconds: Double
    let endToEndSeconds: Double
    let backend: String
    let model: String
    let languageConfiguration: String
    let provenanceID: String
}

private enum Cohort: String, Decodable {
    case english
    case arabic
    case arabicEnglish = "arabic-english"
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

private struct Distribution: Decodable {
    let count: Int
    let p50: Double
    let p95: Double
    let maximum: Double

    init(values: [Double]) {
        let sorted = values.sorted()
        count = sorted.count
        p50 = sorted[nearestRankIndex(percentile: 0.50, count: sorted.count)]
        p95 = sorted[nearestRankIndex(percentile: 0.95, count: sorted.count)]
        maximum = sorted.last ?? 0
    }
}

private struct Metric {
    let wer: Double
    let cer: Double

    init(samples: [Sample], output: KeyPath<Sample, String>) {
        var wordErrors = 0
        var referenceWords = 0
        var characterErrors = 0
        var referenceCharacters = 0
        for sample in samples {
            let arabicNormalization = sample.cohort != .english
            let reference = normalized(sample.reference, arabic: arabicNormalization)
            let hypothesis = normalized(sample[keyPath: output], arabic: arabicNormalization)
            let referenceTokens = reference.split(separator: " ").map(String.init)
            let hypothesisTokens = hypothesis.split(separator: " ").map(String.init)
            let referenceCharactersForSample = Array(referenceTokens.joined())
            let hypothesisCharacters = Array(hypothesisTokens.joined())
            wordErrors += levenshtein(referenceTokens, hypothesisTokens)
            referenceWords += referenceTokens.count
            characterErrors += levenshtein(referenceCharactersForSample, hypothesisCharacters)
            referenceCharacters += referenceCharactersForSample.count
        }
        wer = Double(wordErrors) / Double(referenceWords)
        cer = Double(characterErrors) / Double(referenceCharacters)
    }
}

private enum Script {
    case latin
    case arabic
}

private func tokenPreservation(
    samples: [Sample],
    output: KeyPath<Sample, String>,
    script: Script
) -> Double {
    var retained = 0
    var referenceCount = 0
    for sample in samples {
        let reference = normalized(sample.reference, arabic: true).split(separator: " ").map(String.init)
            .filter { token($0, belongsTo: script) }
        var hypothesis = normalized(sample[keyPath: output], arabic: true).split(separator: " ").map(String.init)
            .filter { token($0, belongsTo: script) }
        referenceCount += reference.count
        for referenceToken in reference {
            if let index = hypothesis.firstIndex(of: referenceToken) {
                retained += 1
                hypothesis.remove(at: index)
            }
        }
    }
    return Double(retained) / Double(referenceCount)
}

private func token(_ value: String, belongsTo script: Script) -> Bool {
    guard !value.isEmpty else { return false }
    return value.unicodeScalars.allSatisfy { scalar in
        switch script {
        case .latin:
            return (0x61 ... 0x7A).contains(scalar.value) || (0x30 ... 0x39).contains(scalar.value)
        case .arabic:
            return (0x0600 ... 0x06FF).contains(scalar.value)
        }
    }
}

private func normalized(_ value: String, arabic: Bool) -> String {
    var scalars = Array(value.precomposedStringWithCanonicalMapping.lowercased().unicodeScalars)
    if arabic {
        scalars = scalars.compactMap { scalar in
            switch scalar.value {
            case 0x0610 ... 0x061A, 0x064B ... 0x065F, 0x0670, 0x06D6 ... 0x06ED, 0x0640:
                return nil
            case 0x0622, 0x0623, 0x0625, 0x0671:
                return UnicodeScalar(0x0627)
            case 0x0649:
                return UnicodeScalar(0x064A)
            default:
                return scalar
            }
        }
    }
    let string = String(String.UnicodeScalarView(scalars))
    let expression = try! NSRegularExpression(pattern: #"[\p{L}\p{N}_]+"#)
    let range = NSRange(string.startIndex ..< string.endIndex, in: string)
    return expression.matches(in: string, range: range).compactMap { match in
        Range(match.range, in: string).map { String(string[$0]) }
    }.joined(separator: " ")
}

private func levenshtein<Element: Equatable>(_ source: [Element], _ target: [Element]) -> Int {
    var previous = Array(0 ... target.count)
    for (sourceIndex, sourceValue) in source.enumerated() {
        var current = [sourceIndex + 1]
        for (targetIndex, targetValue) in target.enumerated() {
            current.append(min(
                current[targetIndex] + 1,
                previous[targetIndex + 1] + 1,
                previous[targetIndex] + (sourceValue == targetValue ? 0 : 1)
            ))
        }
        previous = current
    }
    return previous[target.count]
}

private func nearestRankIndex(percentile: Double, count: Int) -> Int {
    max(0, Int(ceil(percentile * Double(count))) - 1)
}
