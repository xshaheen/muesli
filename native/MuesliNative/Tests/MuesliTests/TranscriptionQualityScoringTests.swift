import Foundation
import MuesliCore
import Testing

/// Hand-computed cases for the scoring primitives behind the frozen baseline. The fixture
/// contract test only proves the whole pipeline reproduces; these pin each piece individually
/// so a regression names the function that broke.
@Suite("Transcription quality scoring")
struct TranscriptionQualityScoringTests {
    // MARK: - Levenshtein

    @Test("levenshtein returns zero for identical and for two empty sequences")
    func levenshteinIdentity() {
        #expect(TranscriptionQualityScoring.levenshtein([String](), [String]()) == 0)
        #expect(TranscriptionQualityScoring.levenshtein(["a", "b", "c"], ["a", "b", "c"]) == 0)
    }

    @Test("levenshtein charges one edit per element when either side is empty")
    func levenshteinEmpty() {
        #expect(TranscriptionQualityScoring.levenshtein([String](), ["a", "b"]) == 2)
        #expect(TranscriptionQualityScoring.levenshtein(["a", "b"], [String]()) == 2)
    }

    @Test("levenshtein charges one for a substitution, insertion, and deletion")
    func levenshteinSingleEdits() {
        #expect(TranscriptionQualityScoring.levenshtein(["a", "b", "c"], ["a", "x", "c"]) == 1)
        #expect(TranscriptionQualityScoring.levenshtein(["a", "c"], ["a", "b", "c"]) == 1)
        #expect(TranscriptionQualityScoring.levenshtein(["a", "b", "c"], ["a", "c"]) == 1)
    }

    /// Plain Levenshtein has no transposition edit, so a swap costs two substitutions.
    @Test("levenshtein charges two for a transposition")
    func levenshteinTransposition() {
        #expect(TranscriptionQualityScoring.levenshtein(["a", "b"], ["b", "a"]) == 2)
        #expect(TranscriptionQualityScoring.levenshtein(Array("ab"), Array("ba")) == 2)
    }

    @Test("levenshtein matches the canonical kitten/sitting distance over characters")
    func levenshteinCharacters() {
        #expect(TranscriptionQualityScoring.levenshtein(Array("kitten"), Array("sitting")) == 3)
    }

    // MARK: - Normalization

    @Test("normalization lowercases, drops punctuation, and collapses to single spaces")
    func normalizationFoldsCase() {
        #expect(TranscriptionQualityScoring.normalized("Hello,  World! 42", arabic: false) == "hello world 42")
    }

    @Test("Arabic normalization folds every alef variant to bare alef")
    func normalizationFoldsAlef() {
        // آ أ إ ٱ all collapse onto ا (U+0627).
        let variants = "\u{0622}\u{0623}\u{0625}\u{0671}"
        #expect(TranscriptionQualityScoring.normalized(variants, arabic: true) == String(repeating: "\u{0627}", count: 4))
    }

    @Test("Arabic normalization folds alef maqsura to ya")
    func normalizationFoldsAlefMaqsura() {
        // على → علي
        #expect(
            TranscriptionQualityScoring.normalized("\u{0639}\u{0644}\u{0649}", arabic: true)
                == "\u{0639}\u{0644}\u{064A}"
        )
    }

    @Test("Arabic normalization strips diacritics and tatweel")
    func normalizationStripsDiacriticsAndTatweel() {
        let muhammad = "\u{0645}\u{062D}\u{0645}\u{062F}"
        // مُحَمَّد — damma, fatha, shadda, fatha.
        let vocalized = "\u{0645}\u{064F}\u{062D}\u{064E}\u{0645}\u{0651}\u{064E}\u{062F}"
        #expect(TranscriptionQualityScoring.normalized(vocalized, arabic: true) == muhammad)
        // Superscript alef (U+0670) is a mark, not a letter, so it goes too.
        #expect(TranscriptionQualityScoring.normalized("\u{0645}\u{0670}\u{062D}\u{0645}\u{062F}", arabic: true) == muhammad)
        // Tatweel is pure elongation.
        let elongated = "\u{0645}\u{0640}\u{062D}\u{0640}\u{0645}\u{062F}"
        #expect(TranscriptionQualityScoring.normalized(elongated, arabic: true) == muhammad)
    }

    @Test("English-cohort normalization leaves Arabic orthography untouched")
    func normalizationSkipsArabicFoldingWhenDisabled() {
        #expect(TranscriptionQualityScoring.normalized("\u{0623}\u{0645}\u{0633}", arabic: false) == "\u{0623}\u{0645}\u{0633}")
    }

    // MARK: - Script classification

    @Test("script membership requires every scalar in one script")
    func tokenScriptMembership() {
        #expect(TranscriptionQualityScoring.token("deploy", belongsTo: .latin))
        #expect(TranscriptionQualityScoring.token("42", belongsTo: .latin))
        #expect(!TranscriptionQualityScoring.token("deploy", belongsTo: .arabic))
        #expect(TranscriptionQualityScoring.token("\u{0645}\u{062D}", belongsTo: .arabic))
        #expect(!TranscriptionQualityScoring.token("\u{0645}\u{062D}", belongsTo: .latin))
        // Mixed-script tokens belong to neither, so code-switch scoring never double counts them.
        #expect(!TranscriptionQualityScoring.token("ab\u{0645}", belongsTo: .latin))
        #expect(!TranscriptionQualityScoring.token("ab\u{0645}", belongsTo: .arabic))
        #expect(!TranscriptionQualityScoring.token("", belongsTo: .latin))
        #expect(!TranscriptionQualityScoring.token("", belongsTo: .arabic))
    }

    /// Classification runs after normalization, which has already lowercased everything.
    @Test("uppercase Latin is not a Latin token before normalization")
    func tokenScriptAssumesNormalizedInput() {
        #expect(!TranscriptionQualityScoring.token("Deploy", belongsTo: .latin))
    }

    // MARK: - Nearest rank

    @Test("nearest-rank indices follow ceil(p x n) - 1, clamped at zero")
    func nearestRank() {
        #expect(TranscriptionQualityScoring.nearestRankIndex(percentile: 0.0, count: 9) == 0)
        #expect(TranscriptionQualityScoring.nearestRankIndex(percentile: 0.50, count: 9) == 4)
        #expect(TranscriptionQualityScoring.nearestRankIndex(percentile: 0.95, count: 9) == 8)
        #expect(TranscriptionQualityScoring.nearestRankIndex(percentile: 1.0, count: 9) == 8)
    }

    @Test("nearest-rank indices stay in bounds for a single-element series")
    func nearestRankSingleElement() {
        #expect(TranscriptionQualityScoring.nearestRankIndex(percentile: 0.0, count: 1) == 0)
        #expect(TranscriptionQualityScoring.nearestRankIndex(percentile: 0.50, count: 1) == 0)
        #expect(TranscriptionQualityScoring.nearestRankIndex(percentile: 0.95, count: 1) == 0)
        #expect(TranscriptionQualityScoring.nearestRankIndex(percentile: 1.0, count: 1) == 0)
    }

    // MARK: - Distribution

    @Test("distribution sorts before summarizing and reports the true maximum")
    func distributionSummarizes() {
        let distribution = TranscriptionQualityScoring.Distribution(values: [3, 1, 2])
        #expect(distribution.count == 3)
        #expect(distribution.p50 == 2)
        #expect(distribution.p95 == 3)
        #expect(distribution.maximum == 3)
    }

    @Test("a single-value distribution reports that value at every percentile")
    func distributionSingleValue() {
        let distribution = TranscriptionQualityScoring.Distribution(values: [0.74])
        #expect(distribution.count == 1)
        #expect(distribution.p50 == 0.74)
        #expect(distribution.p95 == 0.74)
        #expect(distribution.maximum == 0.74)
    }

    // MARK: - Metric

    @Test("word and character error rates count one substitution against the reference length")
    func metricSingleSample() throws {
        let metric = TranscriptionQualityScoring.Metric(
            samples: [try Self.sample(cohort: "english", reference: "the quick brown fox", output: "the quick brown box")],
            output: \.rawASR
        )
        // One wrong word of four; one wrong character of the sixteen in "thequickbrownfox".
        #expect(metric.wer == 0.25)
        #expect(metric.cer == 1.0 / 16.0)
    }

    /// Errors and reference lengths pool across the cohort rather than averaging per-sample rates,
    /// so a long sample weighs more than a short one.
    @Test("error rates pool across samples instead of averaging per-sample rates")
    func metricPoolsAcrossSamples() throws {
        let metric = TranscriptionQualityScoring.Metric(
            samples: [
                try Self.sample(cohort: "english", reference: "the quick brown fox", output: "the quick brown box"),
                try Self.sample(cohort: "english", reference: "hello", output: "hello"),
            ],
            output: \.rawASR
        )
        #expect(metric.wer == 1.0 / 5.0)
        #expect(metric.cer == 1.0 / 21.0)
    }

    @Test("non-English cohorts score against Arabic-normalized text")
    func metricAppliesArabicNormalization() throws {
        // أمس vs امس differ only by the alef form, which the cohort's normalization folds away.
        let metric = TranscriptionQualityScoring.Metric(
            samples: [try Self.sample(cohort: "arabic", reference: "\u{0623}\u{0645}\u{0633}", output: "\u{0627}\u{0645}\u{0633}")],
            output: \.rawASR
        )
        #expect(metric.wer == 0)
        #expect(metric.cer == 0)
    }

    // MARK: - Token preservation

    @Test("token preservation scores each script against its own reference tokens")
    func tokenPreservationPerScript() throws {
        // "deploy اليوم now" heard as "deploy اليوم know": the Arabic survives, one Latin word does not.
        let samples = [try Self.sample(
            cohort: "arabic-english",
            reference: "deploy \u{0627}\u{0644}\u{064A}\u{0648}\u{0645} now",
            output: "deploy \u{0627}\u{0644}\u{064A}\u{0648}\u{0645} know"
        )]
        #expect(
            TranscriptionQualityScoring.tokenPreservation(samples: samples, output: \.rawASR, script: .latin) == 0.5
        )
        #expect(
            TranscriptionQualityScoring.tokenPreservation(samples: samples, output: \.rawASR, script: .arabic) == 1.0
        )
    }

    @Test("token preservation consumes each matched hypothesis token once")
    func tokenPreservationMatchesWithoutReplacement() throws {
        let samples = [try Self.sample(cohort: "arabic-english", reference: "go go", output: "go")]
        #expect(
            TranscriptionQualityScoring.tokenPreservation(samples: samples, output: \.rawASR, script: .latin) == 0.5
        )
    }

    @Test("token preservation compares normalized forms, not raw orthography")
    func tokenPreservationNormalizes() throws {
        let samples = [try Self.sample(
            cohort: "arabic-english",
            reference: "\u{0623}\u{0645}\u{0633}",
            output: "\u{0627}\u{0645}\u{0633}!"
        )]
        #expect(
            TranscriptionQualityScoring.tokenPreservation(samples: samples, output: \.rawASR, script: .arabic) == 1.0
        )
    }

    /// Samples carry no memberwise initializer, so tests build them the way the corpus does.
    private static func sample(cohort: String, reference: String, output: String) throws -> TranscriptionQualitySample {
        let fields: [String: Any] = [
            "id": "test",
            "cohort": cohort,
            "reference": reference,
            "rawASR": output,
            "finalOutput": output,
            "audioBytes": 1,
            "audioSHA256": String(repeating: "0", count: 64),
            "audioDurationSeconds": 1.0,
            "asrSeconds": 0.5,
            "endToEndSeconds": 1.0,
            "backend": "whisperkit",
            "model": "whisper-tiny",
            "languageConfiguration": "automatic",
            "provenanceID": "test",
        ]
        let data = try JSONSerialization.data(withJSONObject: fields)
        return try JSONDecoder().decode(TranscriptionQualitySample.self, from: data)
    }
}
