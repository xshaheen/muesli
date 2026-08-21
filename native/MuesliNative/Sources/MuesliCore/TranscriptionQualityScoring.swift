import Foundation

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

// MARK: - Per-pair metrics

/// Metrics for the measurement harness, which scores one reference against one hypothesis rather
/// than pooling a cohort. Everything above is frozen — the committed v1 baseline reproduces through
/// it at 1e-12 — so these are added alongside instead of replacing it.
public extension TranscriptionQualityScoring {
    /// How much of the text is Arabic-script and how much is Latin-script.
    static func scriptDistribution(_ value: String) -> TranscriptionQuality.ScriptDistribution {
        let tokens = normalized(value, arabic: true).split(separator: " ").map(String.init)
        return TranscriptionQuality.ScriptDistribution(
            arabicTokens: tokens.filter { token($0, belongsTo: .arabic) }.count,
            latinTokens: tokens.filter { token($0, belongsTo: .latin) }.count
        )
    }

    /// Script distribution agreement: did the output stay in the language that was spoken?
    ///
    /// Deliberately blind to whether the words are correct (KTD4). It reads two script histograms
    /// and never compares a hypothesis token against a reference token, which is the only way
    /// garbled Arabic can score as faithful Arabic while fluent English rendered from Arabic speech
    /// does not.
    static func faithfulness(reference: String, hypothesis: String) -> Double {
        // A reference with nothing script-bearing in it asked nothing of the output; a hypothesis
        // with nothing script-bearing preserved none of what the reference did ask for.
        guard let referenceShare = scriptDistribution(reference).arabicShare else { return 1 }
        guard let hypothesisShare = scriptDistribution(hypothesis).arabicShare else { return 0 }
        return 1 - abs(referenceShare - hypothesisShare)
    }

    /// Word and character error rates for one pair. `arabic` selects whether orthographic variants
    /// are folded, so the caller can compute the published-comparable and the normalized figure
    /// from the same text.
    static func errorRates(
        reference: String,
        hypothesis: String,
        arabic: Bool
    ) -> TranscriptionQuality.ErrorRates {
        let referenceTokens = normalized(reference, arabic: arabic).split(separator: " ").map(String.init)
        let hypothesisTokens = normalized(hypothesis, arabic: arabic).split(separator: " ").map(String.init)
        let referenceCharacters = Array(referenceTokens.joined())
        let hypothesisCharacters = Array(hypothesisTokens.joined())
        // Same tokenisation and same character view as the v1 `Metric`, so a per-pair count summed
        // over a cohort reproduces v1's pooled figure exactly rather than approximately.
        return TranscriptionQuality.ErrorRates(
            wordErrors: levenshtein(referenceTokens, hypothesisTokens),
            referenceWords: referenceTokens.count,
            characterErrors: levenshtein(referenceCharacters, hypothesisCharacters),
            referenceCharacters: referenceCharacters.count
        )
    }

    /// Share of the reference's `script` tokens that survive into the hypothesis, matched greedily
    /// and without replacement — the same token recall the v1 baseline reports, scored per sample.
    ///
    /// Returns `nil` when the reference holds no token of that script: a share with no denominator
    /// is not-applicable, and reporting zero would claim total loss of content that never existed.
    static func tokenPreservation(reference: String, hypothesis: String, script: Script) -> Double? {
        let referenceTokens = normalized(reference, arabic: true).split(separator: " ").map(String.init)
            .filter { token($0, belongsTo: script) }
        guard !referenceTokens.isEmpty else { return nil }
        var hypothesisTokens = normalized(hypothesis, arabic: true).split(separator: " ").map(String.init)
            .filter { token($0, belongsTo: script) }
        var retained = 0
        for referenceToken in referenceTokens {
            if let index = hypothesisTokens.firstIndex(of: referenceToken) {
                retained += 1
                hypothesisTokens.remove(at: index)
            }
        }
        return Double(retained) / Double(referenceTokens.count)
    }

    /// Edit distance over reference length — the one definition of an error rate in the harness,
    /// used both for a single pair and for a pooled total so the two can never diverge.
    ///
    /// An empty reference has no denominator: any output against it is wholly inserted, and no
    /// output against it matches perfectly. Either answer beats letting a NaN reach the report.
    static func errorRate(errors: Int, referenceLength: Int) -> Double {
        guard referenceLength > 0 else { return errors > 0 ? 1 : 0 }
        return Double(errors) / Double(referenceLength)
    }
}
