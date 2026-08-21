import Foundation
import MuesliCore
import Testing

private typealias Cohort = TranscriptionQuality.Cohort
private typealias Stage = TranscriptionQuality.Stage
private typealias Threshold = TranscriptionQuality.Threshold

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
    func metricSingleSample() {
        let metric = TranscriptionQualityScoring.Metric(
            samples: [Self.sample(cohort: .english, reference: "the quick brown fox", rawASR: "the quick brown box")],
            output: \.rawASR
        )
        // One wrong word of four; one wrong character of the sixteen in "thequickbrownfox".
        #expect(metric.wer == 0.25)
        #expect(metric.cer == 1.0 / 16.0)
    }

    /// Errors and reference lengths pool across the cohort rather than averaging per-sample rates,
    /// so a long sample weighs more than a short one.
    @Test("error rates pool across samples instead of averaging per-sample rates")
    func metricPoolsAcrossSamples() {
        let metric = TranscriptionQualityScoring.Metric(
            samples: [
                Self.sample(cohort: .english, reference: "the quick brown fox", rawASR: "the quick brown box"),
                Self.sample(cohort: .english, reference: "hello", rawASR: "hello"),
            ],
            output: \.rawASR
        )
        #expect(metric.wer == 1.0 / 5.0)
        #expect(metric.cer == 1.0 / 21.0)
    }

    @Test("non-English cohorts score against Arabic-normalized text")
    func metricAppliesArabicNormalization() {
        // أمس vs امس differ only by the alef form, which the cohort's normalization folds away.
        let metric = TranscriptionQualityScoring.Metric(
            samples: [Self.sample(
                cohort: .egyptianArabic,
                reference: "\u{0623}\u{0645}\u{0633}",
                rawASR: "\u{0627}\u{0645}\u{0633}"
            )],
            output: \.rawASR
        )
        #expect(metric.wer == 0)
        #expect(metric.cer == 0)
    }

    // MARK: - Token preservation

    @Test("token preservation scores each script against its own reference tokens")
    func tokenPreservationPerScript() {
        // "deploy اليوم now" heard as "deploy اليوم know": the Arabic survives, one Latin word does not.
        let samples = [Self.sample(
            cohort: .arabicEnglish,
            reference: "deploy \u{0627}\u{0644}\u{064A}\u{0648}\u{0645} now",
            rawASR: "deploy \u{0627}\u{0644}\u{064A}\u{0648}\u{0645} know"
        )]
        #expect(
            TranscriptionQualityScoring.tokenPreservation(samples: samples, output: \.rawASR, script: .latin) == 0.5
        )
        #expect(
            TranscriptionQualityScoring.tokenPreservation(samples: samples, output: \.rawASR, script: .arabic) == 1.0
        )
    }

    @Test("token preservation consumes each matched hypothesis token once")
    func tokenPreservationMatchesWithoutReplacement() {
        let samples = [Self.sample(cohort: .arabicEnglish, reference: "go go", rawASR: "go")]
        #expect(
            TranscriptionQualityScoring.tokenPreservation(samples: samples, output: \.rawASR, script: .latin) == 0.5
        )
    }

    @Test("token preservation compares normalized forms, not raw orthography")
    func tokenPreservationNormalizes() {
        let samples = [Self.sample(
            cohort: .arabicEnglish,
            reference: "\u{0623}\u{0645}\u{0633}",
            rawASR: "\u{0627}\u{0645}\u{0633}!"
        )]
        #expect(
            TranscriptionQualityScoring.tokenPreservation(samples: samples, output: \.rawASR, script: .arabic) == 1.0
        )
    }

    // MARK: - Script distribution

    @Test("script distribution counts each script and ignores tokens belonging to neither")
    func scriptDistributionCounts() {
        let distribution = TranscriptionQualityScoring.scriptDistribution("deploy \(Arabic.today) please")
        #expect(distribution.arabicTokens == 1)
        #expect(distribution.latinTokens == 2)
        #expect(distribution.scriptBearingTokens == 3)
        #expect(distribution.arabicShare == 1.0 / 3.0)
    }

    /// A share with no denominator is not-applicable. Reporting zero would claim "all Latin",
    /// which is a measurement the text does not support.
    @Test("a text with no script-bearing tokens reports no Arabic share rather than zero")
    func scriptDistributionWithoutScriptBearingTokens() {
        let distribution = TranscriptionQualityScoring.scriptDistribution("   !!!   ")
        #expect(distribution.scriptBearingTokens == 0)
        #expect(distribution.arabicShare == nil)
    }

    // MARK: - Digits are not a language (A1)

    /// The frozen v1 classifier calls ASCII digits Latin and, through the Arabic block, Arabic-Indic
    /// digits Arabic. Faithfulness asks which *language* came out, and a numeral is neither — under
    /// v1's rule the same sentence differing only in digit form disagrees with itself about its own
    /// Arabic share.
    @Test("a numeral is evidence for neither language, in either digit form")
    func digitsAreScriptNeutralForFaithfulness() {
        #expect(TranscriptionQualityScoring.languageScript(ofToken: "123") == nil)
        #expect(TranscriptionQualityScoring.languageScript(ofToken: "\u{0661}\u{0662}\u{0663}") == nil)
        #expect(TranscriptionQualityScoring.languageScript(ofToken: "deploy") == .latin)
        #expect(TranscriptionQualityScoring.languageScript(ofToken: Arabic.today) == .arabic)
        // Mixed-script tokens belong to neither, exactly as the frozen classifier has it.
        #expect(TranscriptionQualityScoring.languageScript(ofToken: "ab\u{0645}") == nil)
        // A letter-plus-digit token is still evidence for its letters' language.
        #expect(TranscriptionQualityScoring.languageScript(ofToken: "v2") == .latin)
        // The frozen v1 predicate is untouched and still counts digits as Latin.
        #expect(TranscriptionQualityScoring.token("123", belongsTo: .latin))
    }

    @Test("the same number in either digit form leaves the Arabic share unchanged")
    func digitFormDoesNotMoveTheArabicShare() {
        let arabicIndic = "\u{0631}\u{0627}\u{062C}\u{0639} \u{0627}\u{0644}\u{0645}\u{0644}\u{0641} \u{0661}\u{0662}\u{0663}"
        let ascii = "\u{0631}\u{0627}\u{062C}\u{0639} \u{0627}\u{0644}\u{0645}\u{0644}\u{0641} 123"

        #expect(TranscriptionQualityScoring.scriptDistribution(arabicIndic).arabicShare == 1)
        #expect(TranscriptionQualityScoring.scriptDistribution(ascii).arabicShare == 1)
        // Before the fix this pair scored 1 - |1 - 2/3| = 0.667 and fell under the 0.90 gate on
        // nothing but a digit form.
        #expect(TranscriptionQualityScoring.faithfulness(reference: arabicIndic, hypothesis: ascii) == 1)
        #expect(
            TranscriptionQualityScoring.faithfulness(reference: arabicIndic, hypothesis: ascii)
                .map { $0 >= Threshold.faithfulnessGate } == true
        )
    }

    @Test("a digits-only text is script-free, so it can neither pass nor fail on script evidence")
    func digitsOnlyTextIsScriptFree() {
        let distribution = TranscriptionQualityScoring.scriptDistribution("123 456")
        #expect(distribution.scriptBearingTokens == 0)
        #expect(distribution.arabicShare == nil)
    }

    // MARK: - Not-applicable faithfulness (A2)

    /// A reference with nothing script-bearing asked nothing of the output's language. Answering
    /// with the perfect 1 it used to return let a cohort of such rows carry a backend over the gate
    /// on no language evidence at all.
    @Test("a reference with no script-bearing tokens yields a not-applicable faithfulness, not a perfect one")
    func scriptFreeReferenceIsNotApplicable() {
        for reference in ["", "   ", "!!! ... ???", "123", "\u{0661}\u{0662}\u{0663}"] {
            #expect(
                TranscriptionQualityScoring.faithfulness(reference: reference, hypothesis: "send the report") == nil,
                "\(reference)"
            )
            let score = TranscriptionQuality.StageScore(
                stage: .rawASR,
                cohort: .egyptianArabic,
                reference: reference,
                hypothesis: "send the report"
            )
            #expect(score.faithfulness == nil, "\(reference)")
            // Nothing script-bearing in the reference cannot evidence a script change either.
            #expect(!score.scriptChangeInflatesErrorRate, "\(reference)")
        }
    }

    /// The delta is R8's signal. A difference between a measurement and a placeholder is not one.
    @Test("a not-applicable stage produces no faithfulness delta rather than a zero one")
    func notApplicableStageHasNoDelta() {
        let score = TranscriptionQuality.SampleScore(sample: Self.sample(
            cohort: .egyptianArabic,
            reference: "123",
            rawASR: "123",
            finalOutput: "one two three"
        ))
        #expect(score.rawASR.faithfulness == nil)
        #expect(score.finalOutput.faithfulness == nil)
        #expect(score.faithfulnessDelta == nil)
    }

    @Test("a reference that does carry script keeps a measured faithfulness and a delta")
    func scriptBearingReferenceStaysMeasured() throws {
        let score = TranscriptionQuality.SampleScore(sample: Self.sample(
            cohort: .egyptianArabic,
            reference: Arabic.reference,
            rawASR: Arabic.garbled,
            finalOutput: Arabic.translated
        ))
        #expect(score.rawASR.faithfulness == 1.0)
        #expect(score.finalOutput.faithfulness == 0.0)
        #expect(try #require(score.faithfulnessDelta).change == -1.0)
    }

    // MARK: - Faithfulness

    /// The discrimination this metric exists for: mistranscription is not translation. A recognizer
    /// that heard Arabic and produced wrong Arabic words preserved the language; one that produced
    /// fluent English did not — and both are equally wrong on WER, so WER cannot tell them apart.
    @Test("faithfulness is independent of accuracy: garbled Arabic stays faithful at maximal WER")
    func faithfulnessIsIndependentOfAccuracy() throws {
        let garbled = TranscriptionQuality.StageScore(
            stage: .rawASR,
            cohort: .egyptianArabic,
            reference: Arabic.reference,
            hypothesis: Arabic.garbled
        )
        let translated = TranscriptionQuality.StageScore(
            stage: .rawASR,
            cohort: .egyptianArabic,
            reference: Arabic.reference,
            hypothesis: Arabic.translated
        )

        // Both are wrong to exactly the same degree.
        #expect(garbled.normalized.wer == 1.0)
        #expect(translated.normalized.wer == 1.0)
        // Only faithfulness separates them.
        #expect(garbled.faithfulness == 1.0)
        #expect(translated.faithfulness == 0.0)
        #expect(try #require(garbled.faithfulness) >= Threshold.faithfulnessGate)
        #expect(try #require(translated.faithfulness) < Threshold.faithfulnessGate)
    }

    @Test("faithfulness is unchanged when only word accuracy varies at constant script composition")
    func faithfulnessIgnoresWordAccuracy() {
        let reference = "deploy \(Arabic.today) please"
        let perfect = TranscriptionQuality.StageScore(
            stage: .rawASR,
            cohort: .arabicEnglish,
            reference: reference,
            hypothesis: reference
        )
        // Two Latin tokens and one Arabic token again, but not one word right.
        let inaccurate = TranscriptionQuality.StageScore(
            stage: .rawASR,
            cohort: .arabicEnglish,
            reference: reference,
            hypothesis: "deployed \(Arabic.report) peace"
        )

        #expect(perfect.normalized.wer == 0)
        #expect(inaccurate.normalized.wer == 1.0)
        #expect(inaccurate.faithfulness == perfect.faithfulness)
        #expect(inaccurate.faithfulness == 1.0)
    }

    // MARK: - Stages

    /// AE4. The recognizer heard Arabic and kept it; cleanup translated it into English. Both
    /// stages score the same WER against the Arabic reference, so only the faithfulness delta
    /// distinguishes a cleanup defect from an ASR defect.
    @Test("a cleanup stage that translates the speech is reported as a faithfulness regression")
    func cleanupIntroducedFaithfulnessRegression() throws {
        let score = TranscriptionQuality.SampleScore(sample: Self.sample(
            cohort: .egyptianArabic,
            reference: Arabic.reference,
            rawASR: Arabic.garbled,
            finalOutput: Arabic.translated
        ))

        #expect(score.rawASR.normalized.wer == score.finalOutput.normalized.wer)
        #expect(try #require(score.rawASR.faithfulness) >= Threshold.faithfulnessGate)
        #expect(score.finalOutput.faithfulness == 0.0)

        let delta = try #require(score.faithfulnessDelta)
        #expect(delta.change == -1.0)
        #expect(delta.recognizerWasFaithful)
        #expect(delta.isCleanupIntroducedRegression)
    }

    @Test("a stage that preserves faithfulness reports no regression")
    func faithfulPipelineReportsNoRegression() throws {
        let score = TranscriptionQuality.SampleScore(sample: Self.sample(
            cohort: .egyptianArabic,
            reference: Arabic.reference,
            rawASR: Arabic.garbled,
            finalOutput: Arabic.reference
        ))
        let delta = try #require(score.faithfulnessDelta)
        #expect(delta.change == 0)
        #expect(!delta.isCleanupIntroducedRegression)
    }

    @Test("the stage subscript selects the text that stage produced")
    func stageSubscriptSelectsStageText() {
        let sample = Self.sample(
            cohort: .egyptianArabic,
            reference: Arabic.reference,
            rawASR: Arabic.garbled,
            finalOutput: Arabic.translated
        )
        #expect(sample[.rawASR] == Arabic.garbled)
        #expect(sample[.finalOutput] == Arabic.translated)
        let score = TranscriptionQuality.SampleScore(sample: sample)
        #expect(score[.rawASR] == score.rawASR)
        #expect(score[.finalOutput] == score.finalOutput)
        #expect(score[.finalOutput].stage == .finalOutput)
    }

    // MARK: - Raw versus normalized error rates

    /// AE5. Orthographic variants are the reason the repository normalizes Arabic at all. Both
    /// figures are kept: the raw one is comparable to published WER, the normalized one answers
    /// whether the words were actually right.
    @Test("orthographic variants score high raw WER, near-zero normalized WER, and stay faithful")
    func orthographicVariantsSeparateRawFromNormalized() {
        let score = TranscriptionQuality.StageScore(
            stage: .rawASR,
            cohort: .egyptianArabic,
            reference: Arabic.orthographicReference,
            hypothesis: Arabic.orthographicVariant
        )

        // Two of three words differ before folding; none differ after it.
        #expect(score.raw.wer == 2.0 / 3.0)
        #expect(score.normalized.wer == 0)
        #expect(score.normalized.cer == 0)
        #expect(score.faithfulness == 1.0)
        #expect(!score.scriptChangeInflatesErrorRate)
    }

    /// AE5b. Correct content in the wrong script. The shipped normalization folds Arabic
    /// orthography, not transliteration, so it cannot recover these words — the error rates are an
    /// upper bound and the result says so rather than claiming a recognition failure.
    @Test("Latin transliteration of Arabic speech is unfaithful and marks its error rates inflated")
    func transliterationIsMarkedAsAMeasurementLimitation() throws {
        let score = TranscriptionQuality.StageScore(
            stage: .rawASR,
            cohort: .egyptianArabic,
            reference: Arabic.reference,
            hypothesis: Arabic.transliterated
        )

        #expect(score.faithfulness == 0.0)
        #expect(try #require(score.faithfulness) < Threshold.scriptChange)
        #expect(score.raw.wer >= Threshold.inflatedErrorRate)
        #expect(score.normalized.wer >= Threshold.inflatedErrorRate)
        // Normalization cannot map transliteration back, so folding buys nothing here.
        #expect(score.raw.wer == score.normalized.wer)
        #expect(score.scriptChangeInflatesErrorRate)
    }

    /// The marker must not fire on a recognizer that simply got the words wrong, or it would excuse
    /// the failures it exists to distinguish from.
    @Test("faithful but inaccurate output is not marked as an inflated measurement")
    func garbledArabicIsNotMarkedAsInflated() {
        let score = TranscriptionQuality.StageScore(
            stage: .rawASR,
            cohort: .egyptianArabic,
            reference: Arabic.reference,
            hypothesis: Arabic.garbled
        )
        #expect(score.normalized.wer == 1.0)
        #expect(!score.scriptChangeInflatesErrorRate)
    }

    // MARK: - Pooling

    /// R5. The per-pair scorer has to carry the counts the frozen v1 `Metric` divides, or the two
    /// halves of the repository report different statistics under the same name — and only one of
    /// them is comparable to a published WER. Samples of very unequal length are what separates a
    /// pooled rate from a mean of per-utterance rates.
    @Test("per-pair counts summed over samples reproduce the frozen v1 pooled metric exactly")
    func perPairCountsPoolToTheVersion1Metric() {
        let samples = [
            Self.sample(cohort: .english, reference: "yes", rawASR: "no"),
            Self.sample(
                cohort: .english,
                reference: "please schedule the product review for tomorrow morning",
                rawASR: "please schedule the product review for tomorrow morning"
            ),
            Self.sample(cohort: .egyptianArabic, reference: Arabic.reference, rawASR: Arabic.garbled),
        ]
        let version1 = TranscriptionQualityScoring.Metric(samples: samples, output: \.rawASR)
        let scored = samples.map { TranscriptionQuality.SampleScore(sample: $0).rawASR.normalized }

        let pooledWER = Double(scored.reduce(0) { $0 + $1.wordErrors })
            / Double(scored.reduce(0) { $0 + $1.referenceWords })
        let pooledCER = Double(scored.reduce(0) { $0 + $1.characterErrors })
            / Double(scored.reduce(0) { $0 + $1.referenceCharacters })

        #expect(abs(pooledWER - version1.wer) < 1e-12)
        #expect(abs(pooledCER - version1.cer) < 1e-12)
        // The defect this replaced: averaging the rates answers a different question by a wide
        // margin, because the one-word sample gets the same vote as the eight-word one.
        let meanOfRates = scored.reduce(0.0) { $0 + $1.wer } / Double(scored.count)
        #expect(abs(meanOfRates - version1.wer) > 0.1)
    }

    // MARK: - Degenerate and not-applicable cases

    @Test("a perfect transcription scores zero error and full faithfulness in every cohort")
    func perfectTranscriptionScoresCleanInEveryCohort() throws {
        let references: [Cohort: String] = [
            .english: "please schedule the product review",
            .egyptianArabic: Arabic.reference,
            .arabicEnglish: "deploy \(Arabic.today) please",
        ]
        for cohort in Cohort.allCases {
            let reference = try #require(references[cohort])
            let score = TranscriptionQuality.SampleScore(sample: Self.sample(
                cohort: cohort,
                reference: reference,
                rawASR: reference
            ))
            for stage in Stage.allCases {
                #expect(score[stage].raw.wer == 0, "\(cohort) \(stage)")
                #expect(score[stage].raw.cer == 0, "\(cohort) \(stage)")
                #expect(score[stage].normalized.wer == 0, "\(cohort) \(stage)")
                #expect(score[stage].normalized.cer == 0, "\(cohort) \(stage)")
                #expect(score[stage].faithfulness == 1.0, "\(cohort) \(stage)")
                #expect(!score[stage].scriptChangeInflatesErrorRate, "\(cohort) \(stage)")
            }
            #expect(score.faithfulnessDelta?.change == 0)
        }
    }

    @Test("an empty hypothesis scores maximal error and zero faithfulness without dividing by zero")
    func emptyHypothesisScoresMaximalError() {
        let score = TranscriptionQuality.StageScore(
            stage: .rawASR,
            cohort: .egyptianArabic,
            reference: Arabic.reference,
            hypothesis: ""
        )

        #expect(score.normalized.wer == 1.0)
        #expect(score.normalized.cer == 1.0)
        #expect(score.raw.wer == 1.0)
        #expect(!score.normalized.wer.isNaN)
        #expect(!score.normalized.cer.isNaN)
        #expect(score.faithfulness == 0.0)
        // Producing nothing is a recognition failure, not a script change to be excused.
        #expect(!score.scriptChangeInflatesErrorRate)
    }

    @Test("an empty reference yields defined rates rather than NaN")
    func emptyReferenceYieldsDefinedRates() {
        let empty = TranscriptionQualityScoring.errorRates(reference: "", hypothesis: "", arabic: true)
        #expect(empty.wer == 0)
        #expect(empty.cer == 0)
        let inserted = TranscriptionQualityScoring.errorRates(reference: "", hypothesis: "hello", arabic: true)
        #expect(inserted.wer == 1.0)
        #expect(inserted.cer == 1.0)
    }

    @Test("Arabic preservation is not-applicable for a sample with no Arabic content")
    func arabicPreservationIsNotApplicableWithoutArabicContent() {
        let score = TranscriptionQuality.StageScore(
            stage: .rawASR,
            cohort: .english,
            reference: "please schedule the product review",
            hypothesis: "please schedule the product review"
        )
        #expect(score.arabicTokenPreservation == nil)
        #expect(score.latinTokenPreservation == 1.0)
        #expect(score.referenceScript.arabicTokens == 0)
        #expect(score.faithfulness == 1.0)
    }

    @Test("per-sample token preservation reports a missing script as nil, not zero")
    func perSampleTokenPreservationNotApplicable() {
        #expect(TranscriptionQualityScoring.tokenPreservation(
            reference: "deploy now",
            hypothesis: "deploy now",
            script: .arabic
        ) == nil)
        #expect(TranscriptionQualityScoring.tokenPreservation(
            reference: "deploy now",
            hypothesis: "deploy know",
            script: .latin
        ) == 0.5)
    }

    // MARK: - Cohort

    /// v1's `samples.jsonl` is hash-pinned by its manifest and cannot be rewritten, so its older
    /// spelling has to keep decoding onto the canonical case.
    @Test("the cohort decodes v1's legacy arabic spelling onto the canonical case")
    func cohortDecodesLegacySpelling() throws {
        #expect(try Self.decodeCohort("arabic") == .egyptianArabic)
        #expect(try Self.decodeCohort("egyptian-arabic") == .egyptianArabic)
        #expect(try Self.decodeCohort("arabic-english") == .arabicEnglish)
        #expect(try Self.decodeCohort("english") == .english)
    }

    @Test("an unknown cohort is rejected with the offending value named")
    func unknownCohortNamesTheOffendingValue() {
        var message = ""
        #expect(throws: (any Error).self) {
            do {
                _ = try Self.decodeCohort("levantine")
            } catch {
                message = String(describing: error)
                throw error
            }
        }
        #expect(message.contains("levantine"))
    }

    @Test("only the English cohort skips Arabic normalization")
    func cohortSelectsNormalization() {
        #expect(!Cohort.english.usesArabicNormalization)
        #expect(Cohort.egyptianArabic.usesArabicNormalization)
        #expect(Cohort.arabicEnglish.usesArabicNormalization)
    }

    private static func decodeCohort(_ raw: String) throws -> Cohort {
        let data = try JSONSerialization.data(withJSONObject: [raw], options: .fragmentsAllowed)
        return try JSONDecoder().decode([Cohort].self, from: data)[0]
    }

    /// Egyptian Arabic sentences shared by the faithfulness cases, so each test states only the
    /// one thing it varies.
    private enum Arabic {
        /// "Send the report this morning."
        static let reference = "ابعت التقرير النهاردة الصبح"
        /// The same sentence in the same script with every word wrong: a bad recognizer, not a
        /// translator.
        static let garbled = "ابعد التقارير النهار وصبح"
        /// The failure this harness exists to catch: Arabic speech rendered as fluent English.
        static let translated = "send the report today"
        /// Right words, wrong script — the shipped normalization cannot fold this back (AE5b).
        static let transliterated = "ebaat el taqreer el naharda el sobh"
        /// "Yesterday at the desk", written with hamza and alef maqsura.
        static let orthographicReference = "أمس على المكتب"
        /// The same three words in the bare forms recognizers commonly emit.
        static let orthographicVariant = "امس علي المكتب"
        static let today = "النهاردة"
        static let report = "التقرير"
    }

    /// Only the four text-bearing fields matter to scoring; the rest are filled with valid-shaped
    /// values so a sample built here still satisfies the fixture contract's bounds.
    private static func sample(
        cohort: Cohort,
        reference: String,
        rawASR: String,
        finalOutput: String? = nil
    ) -> TranscriptionQualitySample {
        TranscriptionQualitySample(
            id: "test",
            cohort: cohort,
            reference: reference,
            rawASR: rawASR,
            finalOutput: finalOutput ?? rawASR,
            audioBytes: 1,
            audioSHA256: String(repeating: "0", count: 64),
            audioDurationSeconds: 1.0,
            asrSeconds: 0.5,
            endToEndSeconds: 1.0,
            backend: "whisperkit",
            model: "whisper-tiny",
            languageConfiguration: "automatic",
            provenanceID: "test"
        )
    }
}
