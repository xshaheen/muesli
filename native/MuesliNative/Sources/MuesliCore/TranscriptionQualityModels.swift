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

    public typealias Cohort = TranscriptionQuality.Cohort

    public init(
        id: String,
        cohort: Cohort,
        reference: String,
        rawASR: String,
        finalOutput: String,
        audioBytes: Int,
        audioSHA256: String,
        audioDurationSeconds: Double,
        asrSeconds: Double,
        endToEndSeconds: Double,
        backend: String,
        model: String,
        languageConfiguration: String,
        provenanceID: String
    ) {
        self.id = id
        self.cohort = cohort
        self.reference = reference
        self.rawASR = rawASR
        self.finalOutput = finalOutput
        self.audioBytes = audioBytes
        self.audioSHA256 = audioSHA256
        self.audioDurationSeconds = audioDurationSeconds
        self.asrSeconds = asrSeconds
        self.endToEndSeconds = endToEndSeconds
        self.backend = backend
        self.model = model
        self.languageConfiguration = languageConfiguration
        self.provenanceID = provenanceID
    }

    /// The text this stage produced, so callers can iterate stages instead of naming both fields.
    public subscript(stage: TranscriptionQuality.Stage) -> String {
        self[keyPath: stage.output]
    }
}

/// Vocabulary of the transcription quality harness: what was measured, where it was measured,
/// and what the measurement said.
///
/// Everything here is a pure value type. No AppKit, no ASR backend — scoring must stay testable
/// on a machine with no models downloaded.
public enum TranscriptionQuality {
    /// The three usage scenarios the harness reports separately. Never averaged into one headline:
    /// a single WER figure hides exactly the cohort the user complains about.
    public enum Cohort: String, Codable, CaseIterable, Hashable, Sendable {
        case english
        case egyptianArabic = "egyptian-arabic"
        case arabicEnglish = "arabic-english"

        /// v1's `samples.jsonl` is frozen and hash-pinned by its manifest, so its older `arabic`
        /// spelling has to keep decoding even though everything written from here on is canonical.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if raw == "arabic" {
                self = .egyptianArabic
                return
            }
            guard let cohort = Cohort(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "unknown cohort \"\(raw)\""
                )
            }
            self = cohort
        }

        /// Arabic orthographic folding is meaningless for English text and would only hide real
        /// errors there, so it follows the cohort rather than the script of an individual sample.
        public var usesArabicNormalization: Bool { self != .english }
    }

    /// A measurable point in the pipeline. Both are measured in a single run (R7) so the cleanup
    /// stage's effect on faithfulness is observed rather than inferred.
    public enum Stage: String, Codable, CaseIterable, Hashable, Sendable {
        case rawASR
        case finalOutput

        public var output: KeyPath<TranscriptionQualitySample, String> {
            switch self {
            case .rawASR: \.rawASR
            case .finalOutput: \.finalOutput
            }
        }
    }

    /// Thresholds that turn continuous scores into the yes/no signals the report states.
    ///
    /// They live together because they are policy, not arithmetic: changing one changes what the
    /// harness claims, and a reviewer should be able to read them all in one place.
    public enum Threshold {
        /// R16's eligibility gate. Below this a backend has not preserved the spoken language, and
        /// no error-rate advantage buys that back.
        public static let faithfulnessGate = 0.90

        /// Most of the script-bearing output flipped script. At this point the hypothesis is text
        /// in the other language, not a damaged transcription of this one.
        public static let scriptChange = 0.50

        /// Paired with `scriptChange`: an error rate this high on script-flipped output is charged
        /// almost entirely to the flip, so the figure is an upper bound (AE5b).
        public static let inflatedErrorRate = 0.50

        /// A faithfulness drop this large between stages is a real regression rather than the
        /// jitter of a few tokens landing on the other side of a script boundary.
        public static let faithfulnessRegression = 0.10
    }

    /// How many script-bearing tokens of each script a text contains.
    ///
    /// This is the whole input to faithfulness: it counts scripts, never compares words, which is
    /// what lets badly-mistranscribed Arabic still score as faithful Arabic (KTD4).
    public struct ScriptDistribution: Codable, Hashable, Sendable {
        public let arabicTokens: Int
        public let latinTokens: Int

        public init(arabicTokens: Int, latinTokens: Int) {
            self.arabicTokens = arabicTokens
            self.latinTokens = latinTokens
        }

        /// Mixed-script tokens belong to neither script, so this is not the total token count.
        public var scriptBearingTokens: Int { arabicTokens + latinTokens }

        /// `nil` when there is nothing script-bearing to take a share of. A share with no
        /// denominator is not-applicable; reporting it as zero would read as "all Latin".
        public var arabicShare: Double? {
            guard scriptBearingTokens > 0 else { return nil }
            return Double(arabicTokens) / Double(scriptBearingTokens)
        }
    }

    /// Word and character error rates for one reference/hypothesis pair, together with the counts
    /// they were divided out of.
    ///
    /// The counts travel with the rates because a rate cannot be weighted after the fact, and R5
    /// asks for figures comparable to published ones — which are pooled, total edit distance over
    /// total reference length. Without the denominators an aggregation can only average rates, which
    /// lets a one-word utterance count as much as a thirty-word one. They are integers derived from
    /// text and are not text (R2).
    public struct ErrorRates: Codable, Hashable, Sendable {
        public let wordErrors: Int
        public let referenceWords: Int
        public let characterErrors: Int
        public let referenceCharacters: Int
        public let wer: Double
        public let cer: Double

        public init(
            wordErrors: Int,
            referenceWords: Int,
            characterErrors: Int,
            referenceCharacters: Int
        ) {
            self.wordErrors = wordErrors
            self.referenceWords = referenceWords
            self.characterErrors = characterErrors
            self.referenceCharacters = referenceCharacters
            wer = TranscriptionQualityScoring.errorRate(
                errors: wordErrors,
                referenceLength: referenceWords
            )
            cer = TranscriptionQualityScoring.errorRate(
                errors: characterErrors,
                referenceLength: referenceCharacters
            )
        }
    }

    /// Everything measured about one stage of one sample.
    ///
    /// `raw` and `normalized` are both kept rather than one replacing the other (R5): `raw` is
    /// comparable to published figures, `normalized` answers whether the words were actually right.
    public struct StageScore: Codable, Hashable, Sendable {
        public let stage: Stage
        public let raw: ErrorRates
        public let normalized: ErrorRates
        public let faithfulness: Double
        public let referenceScript: ScriptDistribution
        public let hypothesisScript: ScriptDistribution
        /// `nil` when the reference holds no token of that script — not-applicable, not zero.
        public let latinTokenPreservation: Double?
        public let arabicTokenPreservation: Double?
        /// The known measurement limitation of AE5b: the hypothesis is fluent text in the other
        /// script, so every word is charged as an error regardless of whether the content is right.
        /// Read the error rates on this stage as an upper bound, not a recognition result.
        public let scriptChangeInflatesErrorRate: Bool

        public init(stage: Stage, cohort: Cohort, reference: String, hypothesis: String) {
            let faithfulness = TranscriptionQualityScoring.faithfulness(
                reference: reference,
                hypothesis: hypothesis
            )
            let normalized = TranscriptionQualityScoring.errorRates(
                reference: reference,
                hypothesis: hypothesis,
                arabic: cohort.usesArabicNormalization
            )
            let hypothesisScript = TranscriptionQualityScoring.scriptDistribution(hypothesis)
            self.stage = stage
            self.faithfulness = faithfulness
            self.normalized = normalized
            self.hypothesisScript = hypothesisScript
            // Raw error rates deliberately skip Arabic folding whatever the cohort, so they stay
            // comparable to published WER, which does not fold orthographic variants either.
            raw = TranscriptionQualityScoring.errorRates(
                reference: reference,
                hypothesis: hypothesis,
                arabic: false
            )
            referenceScript = TranscriptionQualityScoring.scriptDistribution(reference)
            latinTokenPreservation = TranscriptionQualityScoring.tokenPreservation(
                reference: reference,
                hypothesis: hypothesis,
                script: .latin
            )
            arabicTokenPreservation = TranscriptionQualityScoring.tokenPreservation(
                reference: reference,
                hypothesis: hypothesis,
                script: .arabic
            )
            // An empty or script-free hypothesis is a plain recognition failure, so it must not be
            // excused as a measurement limitation however unfaithful it scores.
            scriptChangeInflatesErrorRate = hypothesisScript.scriptBearingTokens > 0
                && faithfulness < Threshold.scriptChange
                && normalized.wer >= Threshold.inflatedErrorRate
        }
    }

    /// What the cleanup stage did to faithfulness — reported on its own because a language change
    /// introduced after recognition is a different defect from a recognition error (R8).
    public struct FaithfulnessDelta: Codable, Hashable, Sendable {
        public let rawASR: Double
        public let finalOutput: Double

        public init(rawASR: Double, finalOutput: Double) {
            self.rawASR = rawASR
            self.finalOutput = finalOutput
        }

        /// Negative when the cleanup stage lost language the recognizer had preserved.
        public var change: Double { finalOutput - rawASR }

        /// The drop happened between the two stages by construction, so the recognizer is not the
        /// thing that caused it.
        public var isCleanupIntroducedRegression: Bool {
            change <= -Threshold.faithfulnessRegression
        }

        /// The regression the plan exists to catch: the recognizer preserved the spoken language
        /// and cleanup then translated it away.
        public var recognizerWasFaithful: Bool {
            rawASR >= Threshold.faithfulnessGate
        }
    }

    /// One sample scored at every stage.
    public struct SampleScore: Codable, Hashable, Sendable {
        public let id: String
        public let cohort: Cohort
        public let rawASR: StageScore
        public let finalOutput: StageScore

        public init(sample: TranscriptionQualitySample) {
            id = sample.id
            cohort = sample.cohort
            rawASR = StageScore(
                stage: .rawASR,
                cohort: sample.cohort,
                reference: sample.reference,
                hypothesis: sample.rawASR
            )
            finalOutput = StageScore(
                stage: .finalOutput,
                cohort: sample.cohort,
                reference: sample.reference,
                hypothesis: sample.finalOutput
            )
        }

        public var faithfulnessDelta: FaithfulnessDelta {
            FaithfulnessDelta(rawASR: rawASR.faithfulness, finalOutput: finalOutput.faithfulness)
        }

        public subscript(stage: Stage) -> StageScore {
            switch stage {
            case .rawASR: rawASR
            case .finalOutput: finalOutput
            }
        }
    }
}
