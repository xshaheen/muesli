import Foundation

/// One measured transcription from the frozen quality corpus.
///
/// Property names are the on-disk JSON keys of `Fixtures/TranscriptionQuality/samples.jsonl`;
/// renaming one silently changes what decodes.
public struct TranscriptionQualitySample: Decodable {
    public let id: String
    public let cohort: Cohort
    public let reference: String
    public let rawASR: String
    public let finalOutput: String
    public let audioBytes: Int
    public let audioSHA256: String
    public let audioDurationSeconds: Double
    public let asrSeconds: Double
    public let endToEndSeconds: Double
    public let backend: String
    public let model: String
    public let languageConfiguration: String
    public let provenanceID: String

    public enum Cohort: String, Decodable {
        case english
        case arabic
        case arabicEnglish = "arabic-english"
    }
}

/// Scoring for the transcription quality corpus.
///
/// Every accumulation order here is load-bearing: committed baselines are compared at 1e-12,
/// so reassociating the `Double` arithmetic below invalidates them.
public enum TranscriptionQualityScoring {
    public enum Script {
        case latin
        case arabic
    }

    /// Word and character error rates, pooled across samples rather than averaged per sample.
    public struct Metric {
        public let wer: Double
        public let cer: Double

        public init(samples: [TranscriptionQualitySample], output: KeyPath<TranscriptionQualitySample, String>) {
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

    /// Nearest-rank summary of a latency series; also the decoded shape of the committed baseline.
    public struct Distribution: Decodable {
        public let count: Int
        public let p50: Double
        public let p95: Double
        public let maximum: Double

        public init(values: [Double]) {
            let sorted = values.sorted()
            count = sorted.count
            p50 = sorted[nearestRankIndex(percentile: 0.50, count: sorted.count)]
            p95 = sorted[nearestRankIndex(percentile: 0.95, count: sorted.count)]
            maximum = sorted.last ?? 0
        }
    }

    /// Share of reference tokens in `script` that survive into the output, matched greedily and
    /// without replacement so a repeated hypothesis token cannot cover two reference tokens.
    public static func tokenPreservation(
        samples: [TranscriptionQualitySample],
        output: KeyPath<TranscriptionQualitySample, String>,
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

    /// Mixed-script tokens belong to neither script, which keeps code-switch scoring honest.
    public static func token(_ value: String, belongsTo script: Script) -> Bool {
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

    /// Case-folds, strips punctuation, and — for Arabic cohorts — folds orthographic variants that
    /// carry no meaning difference (alef forms, final ya, diacritics, tatweel).
    public static func normalized(_ value: String, arabic: Bool) -> String {
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

    public static func levenshtein<Element: Equatable>(_ source: [Element], _ target: [Element]) -> Int {
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

    public static func nearestRankIndex(percentile: Double, count: Int) -> Int {
        max(0, Int(ceil(percentile * Double(count))) - 1)
    }
}
