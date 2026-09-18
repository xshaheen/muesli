import Foundation

/// R10: did a dependency upgrade move transcription quality?
///
/// The question is *not* the one the ranking answers. A run's own interval compares two backends
/// within a single run — "is this backend separated from the leader today?" — and reusing it here
/// would compare a single backend's before/after delta against the spread of a two-backend
/// difference. Those are different quantities, and an earlier draft of the upgrade plan specified
/// exactly that mistake (see KTD5).
///
/// What is correct, and what this does, is to pair each backend against *itself* across the two
/// runs. Both runs scored the identical sample set, so an utterance appears on both sides and the
/// corpus's own difficulty variation cancels — the same reason the ranking's bootstrap is paired.
/// The mechanics are then literally the ranking's: `TranscriptionQualityBootstrap.compare` pairs on
/// `(corpusID, sampleID)`, pools, and resamples with SplitMix64 from the recorded seed. Reusing it
/// rather than writing a second bootstrap is deliberate — a parallel implementation would be free to
/// drift from the one whose numbers this is being compared against.
///
/// A movement whose 95% interval excludes zero is reported for investigation. One whose interval
/// contains zero is recorded as unmoved: that is the upgrade clearing its gate, not a null result.
public enum TranscriptionQualityUpgradeComparison {

    /// One backend's before/after on one cohort.
    public struct Movement: Sendable, Equatable {
        public let backend: String
        public let label: String
        public let cohort: TranscriptionQuality.Cohort
        /// Pooled normalized WER at `rawASR` in each run.
        public let before: Double
        public let after: Double
        /// `after - before`. Positive means the upgrade made this backend worse.
        public let margin: Double
        public let lowerBound: Double?
        public let upperBound: Double?
        public let pairedUtterances: Int

        /// True when the interval excludes zero — the upgrade moved this backend on this cohort.
        ///
        /// An absent interval is *not* movement: it means the comparison could not be resampled
        /// (nothing paired, or a receipt carrying zero resamples), which is a coverage gap to
        /// report rather than a regression to claim.
        public var moved: Bool {
            guard let lowerBound, let upperBound else { return false }
            return lowerBound > 0 || upperBound < 0
        }

        public var hasInterval: Bool { lowerBound != nil && upperBound != nil }
    }

    /// Why a comparison could not be made at all.
    public enum Voided: Sendable, Equatable {
        /// The two runs did not score the same corpora, so nothing can be paired honestly.
        case corpusChanged(detail: String)

        public var explanation: String {
            switch self {
            case let .corpusChanged(detail):
                "the corpora differ between the two runs, so no pairing is valid — \(detail)"
            }
        }
    }

    public struct Result: Sendable {
        public let voided: Voided?
        public let movements: [Movement]
        /// Backends measured in the baseline that the later run did not measure, and the reverse.
        /// Reported rather than silently dropped: a backend that vanished between runs is a fact
        /// about the change, and here it is usually the intended removal of one.
        public let onlyInBefore: [String]
        public let onlyInAfter: [String]
        public let beforeDependencies: TranscriptionQualityReceipt.Dependencies?
        public let afterDependencies: TranscriptionQualityReceipt.Dependencies?

        public var moved: [Movement] { movements.filter(\.moved) }
        public var unmoved: [Movement] { movements.filter { !$0.moved && $0.hasInterval } }
        public var withoutInterval: [Movement] { movements.filter { !$0.hasInterval } }
    }

    public static func compare(
        before: TranscriptionQualityReceipt,
        after: TranscriptionQualityReceipt
    ) -> Result {
        let voided = corpusMismatch(before: before, after: after)

        let beforeByBackend = measuredBackends(before)
        let afterByBackend = measuredBackends(after)
        let shared = beforeByBackend.keys.filter { afterByBackend.keys.contains($0) }.sorted()

        var movements: [Movement] = []
        // Even when the comparison is voided, the roster difference is still reported: it is what
        // tells a reader the removal landed. Only the numbers are withheld.
        if voided == nil {
            for key in shared {
                guard let beforeBackend = beforeByBackend[key], let afterBackend = afterByBackend[key] else { continue }
                let beforeCohorts = Dictionary(
                    (beforeBackend.cohorts ?? []).map { ($0.cohort, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                for afterCohort in afterBackend.cohorts ?? [] {
                    guard let beforeCohort = beforeCohorts[afterCohort.cohort] else { continue }
                    // `compare` names its sides leader/challenger because the ranking asks a
                    // ranking question. Here the "leader" is the baseline and the "challenger" is
                    // the upgraded run, so its margin — challenger minus leader — reads directly as
                    // after minus before.
                    let comparison = TranscriptionQualityBootstrap.compare(
                        leader: key,
                        leaderUtterances: beforeCohort.utterances,
                        challenger: key,
                        challengerUtterances: afterCohort.utterances,
                        thresholds: after.thresholds
                    )
                    movements.append(Movement(
                        backend: key,
                        label: afterBackend.label,
                        cohort: afterCohort.cohort,
                        before: pooledWER(beforeCohort.utterances),
                        after: pooledWER(afterCohort.utterances),
                        margin: comparison.margin,
                        lowerBound: comparison.lowerBound,
                        upperBound: comparison.upperBound,
                        pairedUtterances: comparison.pairedUtterances
                    ))
                }
            }
        }

        return Result(
            voided: voided,
            movements: movements.sorted {
                ($0.label, $0.cohort.rawValue) < ($1.label, $1.cohort.rawValue)
            },
            onlyInBefore: beforeByBackend.keys.filter { !afterByBackend.keys.contains($0) }.sorted(),
            onlyInAfter: afterByBackend.keys.filter { !beforeByBackend.keys.contains($0) }.sorted(),
            beforeDependencies: before.dependencies,
            afterDependencies: after.dependencies
        )
    }

    /// R10's precondition. Pairing is only meaningful over the identical sample set, so a corpus
    /// that gained, lost, or re-revved a sample voids the whole comparison rather than quietly
    /// pairing whatever happens to overlap.
    private static func corpusMismatch(
        before: TranscriptionQualityReceipt,
        after: TranscriptionQualityReceipt
    ) -> Voided? {
        let beforeByID = Dictionary(before.corpora.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let afterByID = Dictionary(after.corpora.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        let beforeIDs = Set(beforeByID.keys)
        let afterIDs = Set(afterByID.keys)
        guard beforeIDs == afterIDs else {
            let added = afterIDs.subtracting(beforeIDs).sorted()
            let removed = beforeIDs.subtracting(afterIDs).sorted()
            var parts: [String] = []
            if !added.isEmpty { parts.append("added \(added.joined(separator: ", "))") }
            if !removed.isEmpty { parts.append("removed \(removed.joined(separator: ", "))") }
            return .corpusChanged(detail: parts.joined(separator: "; "))
        }

        for id in beforeIDs.sorted() {
            guard let lhs = beforeByID[id], let rhs = afterByID[id] else { continue }
            if lhs.revision != rhs.revision {
                return .corpusChanged(detail: "\(id) moved from revision \(lhs.revision) to \(rhs.revision)")
            }
            if lhs.sampleCount != rhs.sampleCount {
                return .corpusChanged(
                    detail: "\(id) went from \(lhs.sampleCount) to \(rhs.sampleCount) samples"
                )
            }
        }
        return nil
    }

    private static func measuredBackends(
        _ receipt: TranscriptionQualityReceipt
    ) -> [String: TranscriptionQualityReceipt.Backend] {
        Dictionary(
            receipt.backends
                .filter { !($0.cohorts ?? []).isEmpty }
                .map { ("\($0.backend)/\($0.model)", $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// The same pooling the ranking reports, so a movement's endpoints are the figures a reader
    /// already saw rather than a second statistic computed a different way.
    private static func pooledWER(_ utterances: [TranscriptionQualityReceipt.Utterance]) -> Double {
        var errors = 0
        var words = 0
        for utterance in utterances {
            errors += utterance.rawASR.normalizedWordErrors
            words += utterance.rawASR.normalizedReferenceWords
        }
        return TranscriptionQualityScoring.errorRate(errors: errors, referenceLength: words)
    }
}
