import Foundation

// The markdown report, split out of `TranscriptionQualityReceipt.swift`. It reads the schema
// and the decision policy and is read by neither, so it is the leaf of the three.

/// R13's comparison report, rendered from a receipt and its decisions.
///
/// Rendering rather than writing is the point: every number and every verdict in the output is
/// already in the receipt or is the deterministic output of `TranscriptionQualityDecision`, so the
/// document cannot drift from the measurement or quietly acquire a reviewer's opinion.
public enum TranscriptionQualityReport {
    public static func markdown(for receipt: TranscriptionQualityReceipt) -> String {
        markdown(for: receipt, decisions: TranscriptionQualityDecision.evaluate(receipt))
    }

    public static func markdown(
        for receipt: TranscriptionQualityReceipt,
        decisions: TranscriptionQualityDecision.Report
    ) -> String {
        var lines: [String] = ["# Transcription quality run \(receipt.runID)", ""]
        lines += provenance(receipt)
        lines += corpora(receipt)
        lines += policy(receipt)
        lines += disclosures(receipt)
        for cohort in decisions.cohorts {
            lines += cohortSection(cohort, receipt: receipt)
        }
        lines += coldStartSection(receipt)
        lines += sampleFailureSection(receipt)
        lines += notRunnableSection(receipt)
        lines += qwen3Section(decisions.qwen3)
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Sections

    private static func provenance(_ receipt: TranscriptionQualityReceipt) -> [String] {
        [
            "Schema v\(receipt.schemaVersion), generated \(receipt.generatedAt).",
            "",
            "| Host | |",
            "| --- | --- |",
            "| macOS | \(receipt.host.operatingSystemVersion) |",
            "| Machine | \(receipt.host.machineModel) |",
            "| CPU | \(receipt.host.architecture) |",
            "| Cores | \(receipt.host.processorCount) |",
            "| Memory | \(gigabytes(receipt.host.physicalMemoryBytes)) |",
            "",
        ]
    }

    private static func corpora(_ receipt: TranscriptionQualityReceipt) -> [String] {
        var lines = ["## Corpora", ""]
        guard !receipt.corpora.isEmpty else {
            return lines + ["No corpus identity was recorded for this run.", ""]
        }
        lines += [
            "| Corpus | Revision | Licence | Acquired | Cohorts | Samples | Refused rows |",
            "| --- | --- | --- | --- | --- | ---: | ---: |",
        ]
        for corpus in receipt.corpora {
            let cohorts = corpus.cohorts.map(\.rawValue).joined(separator: ", ")
            lines.append(
                "| \(corpus.id) | \(corpus.revision) | \(corpus.licenceIdentifier) | "
                    + "\(corpus.acquisition) | \(cohorts) | \(corpus.sampleCount) | \(corpus.issueCount) |"
            )
        }
        return lines + [""]
    }

    private static func policy(_ receipt: TranscriptionQualityReceipt) -> [String] {
        let thresholds = receipt.thresholds
        return [
            "## Decision policy",
            "",
            "| Setting | Value |",
            "| --- | --- |",
            "| Faithfulness gate (raw ASR) | \(format(thresholds.faithfulnessGate)) |",
            "| Confidence level | \(percent(thresholds.confidenceLevel)) |",
            "| Paired bootstrap resamples | \(thresholds.bootstrapResamples) |",
            "| Bootstrap seed | \(thresholds.bootstrapSeed) |",
            "",
            "A run scored under different thresholds is not comparable to this one.",
            "",
            "Error rates are pooled over each cohort — total edit distance over total reference "
                + "length — so a long utterance weighs what it is, and the figures are comparable to "
                + "published WER and CER.",
            "",
        ]
    }

    private static func disclosures(_ receipt: TranscriptionQualityReceipt) -> [String] {
        let disclosures = receipt.disclosures
        var lines = ["## What this run did and did not control", ""]
        lines += cleanupDisclosure(disclosures)
        if disclosures.warmupSampleConsumed {
            lines.append(
                "- The first sample is spent on the cold start and is **not** re-measured, so every "
                    + "cohort figure rests on one fewer utterance than the corpus holds. Every backend "
                    + "loses the same sample."
            )
        }
        if disclosures.cleanupModelResidentAcrossSweep {
            lines.append(
                "- ASR weights are unloaded between backends, but the cleanup LLM stays resident for "
                    + "the whole sweep. Latency below is a machine already holding one model."
            )
        }
        lines += disclosures.notes.map { "- \($0)" }
        return lines + [""]
    }

    /// The line that says whether cleanup *happened*. Reporting the request alone let a run in which
    /// the cleanup model was never loadable read as "cleanup preserved the language" — which is the
    /// one question the harness exists to answer.
    private static func cleanupDisclosure(
        _ disclosures: TranscriptionQualityReceipt.Disclosures
    ) -> [String] {
        guard disclosures.cleanupRequested else {
            return [
                "- Cleanup stage: **not requested**. The final stage is only artifact cleanup away "
                    + "from raw ASR, so the faithfulness delta this harness exists to catch cannot "
                    + "appear in this run.",
            ]
        }
        let skipped = disclosures.cleanupNotPerformedUtterances
        var lines: [String]
        if disclosures.cleanupApplied {
            lines = [
                "- Cleanup stage: **requested, and applied on \(disclosures.cleanupAppliedUtterances) "
                    + "of \(disclosures.cleanupAppliedUtterances + skipped) measured utterances**.",
            ]
        } else {
            lines = [
                "- Cleanup stage: **requested, and never applied**. Every final-stage figure below is "
                    + "absent rather than unchanged: this run measured nothing about cleanup, which is "
                    + "not the same as cleanup having changed nothing.",
            ]
        }
        for skip in disclosures.cleanupNotPerformed {
            lines.append("  - \(skip.reason): \(skip.utterances) utterance(s)")
        }
        return lines
    }

    private static func cohortSection(
        _ decision: TranscriptionQualityDecision.CohortDecision,
        receipt: TranscriptionQualityReceipt
    ) -> [String] {
        var lines = ["## Cohort: \(decision.cohort.rawValue)", "", verdictLine(decision), ""]
        if !decision.ranking.isEmpty {
            lines += [
                "| # | Backend | Model | Language | n | WER raw ASR | WER final | Faithfulness raw | "
                    + "Faithfulness final | p50 s | p95 s | RTF |",
                "| ---: | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
            ]
            for (index, entry) in decision.ranking.enumerated() {
                let language = TranscriptionQualityLanguageConfiguration(rawValue: entry.languageConfiguration)
                // R17: the mark travels with the row, so a pinned model's position is never read as
                // a statement about what it can recognise. R9's cold-start mark travels with it for
                // the same reason: a model that failed its first call is not a clean win.
                let mark = (entry.canSelectCohortLanguage ? "" : " ⚠︎")
                    + (entry.warmupFailed ? " ✖︎" : "")
                let model = receipt.backend(identity: entry.identity)?.model ?? entry.identity
                lines.append(
                    "| \(index + 1) | \(entry.label) | \(model) | \(language.description)\(mark) "
                        + "| \(entry.sampleCount) "
                        + "| \(format(entry.normalizedWER)) | \(format(entry.finalOutputNormalizedWER)) "
                        + "| \(format(entry.faithfulness)) | \(format(entry.finalOutputFaithfulness)) "
                        + "| \(format(entry.p50Seconds, places: 2)) | \(format(entry.p95Seconds, places: 2)) "
                        + "| \(format(entry.realTimeFactor, places: 2)) |"
                )
            }
            lines.append("")
            if decision.ranking.contains(where: { !$0.canSelectCohortLanguage }) {
                lines += [
                    "⚠︎ This backend could not select this cohort's language. Its position reflects the "
                        + "language it was pinned to, not a failure to recognise the one that was spoken.",
                    "",
                ]
            }
            if decision.ranking.contains(where: \.warmupFailed) {
                lines += [
                    "✖︎ This backend's cold start failed. Its measured samples are real, but the very "
                        + "first call into the model did not return — see **Cold start** below.",
                    "",
                ]
            }
            lines += finalStageCaveat(decision)
        } else {
            lines += ["No backend passed the faithfulness gate on this cohort.", ""]
        }

        if !decision.excluded.isEmpty {
            lines += [
                "**Excluded by the faithfulness gate.** A backend below the gate did not keep the "
                    + "spoken language; no error rate buys that back.",
                "",
                "| Backend | WER raw ASR | Faithfulness raw | Reason |",
                "| --- | ---: | ---: | --- |",
            ]
            for exclusion in decision.excluded {
                lines.append(
                    "| \(exclusion.label) | \(format(exclusion.normalizedWER)) "
                        + "| \(format(exclusion.faithfulness)) | \(exclusion.reason) |"
                )
            }
            lines.append("")
        }

        lines += corpusBreakdown(decision, receipt: receipt)

        if !decision.absent.isEmpty {
            lines += [
                "**Not ranked — no data on this cohort.** Absent from the ranking rather than last.",
                "",
            ]
            lines += decision.absent.map { "- \($0.label): \($0.reason)" }
            lines.append("")
        }

        if !decision.comparisons.isEmpty {
            lines += [
                "<details><summary>Paired bootstrap against the leader</summary>",
                "",
                "| Challenger | Margin | \(percent(receipt.thresholds.confidenceLevel)) interval "
                    + "| Paired n | Leader n | Challenger n | Separated |",
                "| --- | ---: | --- | ---: | ---: | ---: | --- |",
            ]
            for comparison in decision.comparisons {
                lines.append(
                    "| \(decision.label(for: comparison.challenger)) | \(format(comparison.margin)) "
                        + "| \(interval(comparison)) "
                        + "| \(comparison.pairedUtterances) | \(comparison.leaderUtterances) "
                        + "| \(comparison.challengerUtterances) "
                        + "| \(comparison.isSignificant ? "yes" : "no") |"
                )
            }
            if decision.comparisons.contains(where: { !$0.isFullyPaired }) {
                lines += [
                    "",
                    "Where the paired count is below either backend's own, the ranking and the "
                        + "interval rest on different populations: the ranking pools every utterance a "
                        + "backend measured, while a paired interval can only use the ones both "
                        + "measured. Read the interval as a statement about the overlap.",
                ]
            }
            lines += ["", "</details>", ""]
        }
        return lines
    }

    // MARK: Per-corpus breakdown

    /// One backend's rows in the breakdown: its label, and its slice of the cohort.
    private struct CorpusBreakdownRow {
        let label: String
        let result: TranscriptionQualityReceipt.CohortResult
        /// Where the reader already met this backend in the section above.
        let position: Int
    }

    /// The cohort's figures again, one corpus at a time.
    ///
    /// A cohort is a language condition, not a corpus, and the corpora that satisfy one are chosen
    /// separately: `egyptian-arabic` is read speech from FLEURS pooled with spontaneous broadcast
    /// speech from MGB-3. Pooling holds a long utterance at its true weight, but it cannot hold two
    /// registers apart — the cohort figure lands between them and describes neither, and a reader
    /// deciding what to ship for dictation needs the spontaneous half specifically.
    ///
    /// This is a reporting split and nothing more. Every figure is the same pooled statistic the
    /// ranking uses, computed by the same code over fewer rows (`CohortResult.restricted(toCorpus:)`);
    /// the ranking, the gate and the verdict above are untouched by it. A cohort backed by one
    /// corpus renders nothing here, since restating its own figures would say nothing.
    private static func corpusBreakdown(
        _ decision: TranscriptionQualityDecision.CohortDecision,
        receipt: TranscriptionQualityReceipt
    ) -> [String] {
        let rows = breakdownRows(decision, receipt: receipt)
        let corpora = orderedCorpusIDs(in: rows.map(\.result), receipt: receipt)
        guard corpora.count > 1 else { return [] }

        var lines = [
            "**Per-corpus breakdown.** This cohort pools \(corpora.count) corpora, and corpora "
                + "differ in register — read speech and spontaneous speech are not equally hard — so "
                + "the single figure above can sit between two results and describe neither. Below is "
                + "the same pooling over one corpus at a time; the ranking and the verdict are "
                + "unchanged by it.",
            "",
            "| Backend | Corpus | n | WER raw ASR | Faithfulness raw | p50 s |",
            "| --- | --- | ---: | ---: | ---: | ---: |",
        ]
        for row in rows {
            for corpus in corpora {
                let slice = row.result.restricted(toCorpus: corpus)
                // A backend that measured nothing from this corpus gets no row: an empty row would
                // read as a result, and its absence is already visible in the counts.
                guard slice.sampleCount > 0 else { continue }
                lines.append(
                    "| \(row.label) | \(corpus) | \(slice.sampleCount) "
                        + "| \(format(slice.pooledNormalizedWER(at: .rawASR))) "
                        + "| \(format(slice.meanFaithfulness(at: .rawASR))) "
                        + "| \(format(slice.endToEndLatency?.p50, places: 2)) |"
                )
            }
        }
        return lines + [""]
    }

    /// Every backend with utterances in this cohort, in the order the section above introduced it.
    ///
    /// Gate-excluded backends belong here rather than being filtered to the ranking: a per-corpus
    /// split is precisely what explains an exclusion — a backend that holds together on read speech
    /// and collapses on spontaneous speech has a diagnosis, not just a failing average. A backend
    /// can also carry utterances and appear in neither list, when no reference in the cohort held
    /// language evidence for the gate to judge, so the fall-through keeps it too.
    private static func breakdownRows(
        _ decision: TranscriptionQualityDecision.CohortDecision,
        receipt: TranscriptionQualityReceipt
    ) -> [CorpusBreakdownRow] {
        let introduced = decision.ranking.map(\.identity)
            + decision.excluded.map(\.identity)
            + decision.absent.map(\.identity)
        let position = Dictionary(
            introduced.enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: min
        )
        return receipt.backends
            .compactMap { backend -> CorpusBreakdownRow? in
                guard let result = backend.result(for: decision.cohort), result.sampleCount > 0 else {
                    return nil
                }
                return CorpusBreakdownRow(
                    label: backend.label,
                    result: result,
                    position: position[backend.identity] ?? Int.max
                )
            }
            // `sorted(by:)` is not documented as stable, so receipt order is the explicit tiebreak
            // rather than an assumption — otherwise two unplaced backends could swap between runs.
            .enumerated()
            .sorted { left, right in
                left.element.position == right.element.position
                    ? left.offset < right.offset
                    : left.element.position < right.element.position
            }
            .map(\.element)
    }

    /// Corpus ids in the order the corpora table above lists them, so a reader can look one up
    /// where its revision and licence already are. Anything the table does not name — a corpus that
    /// measured utterances without being recorded in the run's corpus list — follows, rather than
    /// being dropped from a breakdown whose whole job is to account for every utterance.
    private static func orderedCorpusIDs(
        in results: [TranscriptionQualityReceipt.CohortResult],
        receipt: TranscriptionQualityReceipt
    ) -> [String] {
        var present: Set<String> = []
        var firstSeen: [String] = []
        for result in results {
            for id in result.corpusIDs where present.insert(id).inserted { firstSeen.append(id) }
        }
        let listed = receipt.corpora.map(\.id).filter(present.contains)
        return listed + firstSeen.filter { !listed.contains($0) }
    }

    /// A final-stage column of `n/a` is the honest rendering of a cleanup stage that did not run,
    /// but it looks identical to a rendering bug. Saying which it is costs one line.
    private static func finalStageCaveat(
        _ decision: TranscriptionQualityDecision.CohortDecision
    ) -> [String] {
        let unmeasured = decision.ranking.filter { $0.finalOutputMeasuredCount < $0.sampleCount }
        guard !unmeasured.isEmpty else { return [] }
        let described = unmeasured
            .map { "\($0.label) (\($0.finalOutputMeasuredCount)/\($0.sampleCount))" }
            .joined(separator: ", ")
        return [
            "The final-stage columns cover only the utterances where the cleanup stage actually ran: "
                + "\(described). An absent figure there is a cleanup that did not happen, not a "
                + "cleanup that changed nothing.",
            "",
        ]
    }

    private static func verdictLine(_ decision: TranscriptionQualityDecision.CohortDecision) -> String {
        switch decision.verdict {
        case let .winner(identity, comparison):
            return "**Winner: \(decision.label(for: identity))** — ahead of "
                + "`\(decision.label(for: comparison.challenger))` by "
                + "\(format(comparison.margin)) normalized WER "
                + "(interval \(interval(comparison)), "
                + "\(comparison.pairedUtterances) paired utterances)."
        case let .soleEligible(identity):
            return "**Sole eligible backend: \(decision.label(for: identity))** — it is the only one "
                + "that passed the faithfulness gate, so there was no contest to win."
        case let .tie(identities):
            let labels = identities.map { decision.label(for: $0) }
            return "**Tie: \(labels.joined(separator: ", "))** — the differences sit inside the "
                + "paired bootstrap interval, so no winner is claimed. Listed fastest first."
        case .noEligibleBackend:
            return "**No winner** — no backend passed the faithfulness gate on this cohort."
        }
    }

    /// R9's cold start, and the place a warmup failure becomes visible to a reader.
    ///
    /// The receipt has always recorded it; the document never read it, so a backend whose model
    /// failed its first call could win a cohort and be named the Qwen3 comparison with no sign in
    /// the artifact a maintainer actually reads.
    private static func coldStartSection(_ receipt: TranscriptionQualityReceipt) -> [String] {
        let warmed = receipt.backends.filter { $0.warmup != nil }
        guard !warmed.isEmpty else { return [] }
        var lines = [
            "## Cold start",
            "",
            "The first sample of the sweep, measured separately (R9): it pays model load and, for "
                + "CoreML backends, first-run compilation.",
            "",
            "| Backend | Model | Sample | Cold start s | Outcome |",
            "| --- | --- | --- | ---: | --- |",
        ]
        for backend in warmed {
            guard let warmup = backend.warmup else { continue }
            let outcome = warmup.failureMessage.map { "**failed** — \($0)" } ?? "ok"
            lines.append(
                "| \(backend.label) | \(backend.model) | \(warmup.sampleID) "
                    + "| \(format(warmup.endToEndSeconds, places: 2)) | \(outcome) |"
            )
        }
        if warmed.contains(where: { $0.warmup?.didFail == true }) {
            lines += [
                "",
                "A failed cold start does not cost a backend its measured samples — one bad first call "
                    + "must not delete a whole run — but it is a signal about the model's stability on "
                    + "this host, and a ranking row for such a backend is marked ✖︎ above.",
            ]
        }
        return lines + [""]
    }

    /// Why individual samples threw under a backend that still produced a result.
    ///
    /// A backend that scored *nothing* carries its reasons in the not-runnable sentence below; this
    /// section is for the other case, which the document used to lose entirely — a backend with a
    /// real ranking row and four samples missing from it, with no statement anywhere of what went
    /// wrong on those four.
    private static func sampleFailureSection(_ receipt: TranscriptionQualityReceipt) -> [String] {
        let partial = receipt.backends.filter { $0.isRunnable && !$0.failures.isEmpty }
        guard !partial.isEmpty else { return [] }
        var lines = [
            "## Sample failures",
            "",
            "Samples that threw under a backend that still measured others. They are absent from "
                + "every figure above, so a row here is a cohort figure resting on fewer utterances "
                + "than the corpus holds.",
            "",
            "| Backend | Model | Samples | Reason |",
            "| --- | --- | ---: | --- |",
        ]
        for backend in partial {
            for reason in TranscriptionQualityReceipt.SampleFailure.distinctReasons(in: backend.failures) {
                let ids = backend.failures.filter { $0.reason == reason }.map(\.sampleID)
                lines.append(
                    "| \(backend.label) | \(backend.model) | \(ids.count) | \(reason) |"
                )
            }
            // A reason that sanitized away to nothing still cost the samples, so it is counted.
            let unexplained = backend.failures.filter(\.reason.isEmpty)
            if !unexplained.isEmpty {
                lines.append(
                    "| \(backend.label) | \(backend.model) | \(unexplained.count) "
                        + "| the error carried no description |"
                )
            }
        }
        return lines + [""]
    }

    private static func notRunnableSection(_ receipt: TranscriptionQualityReceipt) -> [String] {
        let unrunnable = receipt.backends.filter { !$0.isRunnable }
        guard !unrunnable.isEmpty else { return [] }
        var lines = [
            "## Not runnable on this host",
            "",
            "| Backend | Model | Reason |",
            "| --- | --- | --- |",
        ]
        for backend in unrunnable {
            lines.append(
                "| \(backend.label) | \(backend.model) | \(backend.notRunnableDescription ?? "unknown") |"
            )
        }
        return lines + [""]
    }

    private static func qwen3Section(_ verdict: TranscriptionQualityDecision.Qwen3Verdict) -> [String] {
        [
            "## Qwen3 verdict: \(verdict.decision.rawValue)",
            "",
            verdict.rationale,
            "",
        ]
    }

    // MARK: Formatting

    private static func interval(_ comparison: TranscriptionQualityDecision.Comparison) -> String {
        guard let lower = comparison.lowerBound, let upper = comparison.upperBound else {
            return "none"
        }
        return "[\(format(lower)), \(format(upper))]"
    }

    /// `n/a` rather than `0` for an absent figure. A zero WER and an unmeasured WER read identically
    /// in a table, and only one of them is a result.
    private static func format(_ value: Double?, places: Int = 3) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.\(places)f", value)
    }

    private static func format(_ value: Double, places: Int = 3) -> String {
        String(format: "%.\(places)f", value)
    }

    private static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }

    private static func gigabytes(_ bytes: UInt64) -> String {
        String(format: "%.0f GB", Double(bytes) / 1_073_741_824)
    }
}
