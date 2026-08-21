import Foundation

/// One evaluation corpus in the local store: what it is, what it is licensed for, and which of its
/// rows resolved to real audio.
///
/// The corpus itself never enters this repository (R2). Only the identities and hashes recorded
/// here are ever committed, which is why the descriptor carries revision and licence: a score is
/// meaningless without knowing which version of which corpus produced it.
public struct TranscriptionCorpus: Sendable {
    /// The store subdirectory holding this corpus, which is how a maintainer finds it on disk even
    /// when the descriptor's `id` says something else.
    public let directoryName: String
    public let directory: URL
    public let descriptor: Descriptor
    /// Rows that are usable: reference within the field cap, audio present under this corpus.
    public let samples: [Sample]
    /// Rows that are not usable, each named. A bad row is not a broken corpus (R4).
    public let issues: [Issue]

    public init(
        directoryName: String,
        directory: URL,
        descriptor: Descriptor,
        samples: [Sample],
        issues: [Issue]
    ) {
        self.directoryName = directoryName
        self.directory = directory
        self.descriptor = descriptor
        self.samples = samples
        self.issues = issues
    }

    public var id: String { descriptor.id }

    /// The cohorts this corpus actually contributes data to — derived from usable samples, not from
    /// the descriptor, so a corpus whose audio is all missing does not claim to cover anything.
    public var cohorts: Set<TranscriptionQuality.Cohort> { Set(samples.map(\.cohort)) }
}

public extension TranscriptionCorpus {
    /// The machine-readable record R3 requires of every corpus: identity, revision, licence,
    /// how it was obtained, and how its rows map onto the harness's cohorts.
    struct Descriptor: Decodable, Sendable {
        public let schemaVersion: Int
        public let id: String
        /// Dataset version, release tag, or repository commit — whatever pins the bytes that were
        /// measured. Free-form because corpora version themselves in incompatible ways.
        public let revision: String
        /// Optional in the schema and only in the schema: a corpus that decodes without one is
        /// refused rather than evaluated, so the absence is reportable instead of fatal.
        public let licence: Licence?
        public let acquisition: Acquisition
        /// The cohort every row belongs to unless the row overrides it.
        public let cohort: TranscriptionQuality.Cohort
        /// Relative path of the JSON Lines sample index. Kept out of the descriptor itself because
        /// a large corpus's index is thousands of rows long.
        public let sampleIndex: String
        /// Anything a future maintainer needs to know about this copy — grant terms, preprocessing,
        /// which subset was taken.
        public let notes: String?

        public static let defaultSampleIndex = "samples.jsonl"

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, id, revision, licence, acquisition, cohort, sampleIndex, notes
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
            id = try container.decode(String.self, forKey: .id)
            revision = try container.decode(String.self, forKey: .revision)
            licence = try container.decodeIfPresent(Licence.self, forKey: .licence)
            acquisition = try container.decode(Acquisition.self, forKey: .acquisition)
            cohort = try container.decode(TranscriptionQuality.Cohort.self, forKey: .cohort)
            sampleIndex = try container.decodeIfPresent(String.self, forKey: .sampleIndex)
                ?? Self.defaultSampleIndex
            notes = try container.decodeIfPresent(String.self, forKey: .notes)
        }
    }

    /// What permits this corpus to be evaluated locally. `identifier` is an SPDX id where one
    /// exists and a plain description of the grant where none does (request-gated corpora).
    struct Licence: Decodable, Sendable {
        public let identifier: String
        /// Where the terms can be re-read months from now — licence file, dataset card, or the
        /// project page for a corpus obtained by request.
        public let sourceURL: URL
    }

    /// How a copy of this corpus is obtained, so the runbook step is recorded next to the data
    /// rather than only in prose.
    enum Acquisition: String, Codable, CaseIterable, Sendable {
        case huggingFace = "hugging-face"
        case directDownload = "direct-download"
        /// Access granted by the authors on request — no public download exists.
        case authorRequest = "author-request"
        /// Assembled by hand from sources the corpus only references, such as media URLs.
        case manual

        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let acquisition = Acquisition(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "unknown acquisition method \"\(raw)\""
                )
            }
            self = acquisition
        }
    }

    /// A usable row: one audio file and the reference transcript it should produce.
    struct Sample: Sendable {
        public let corpusID: String
        public let id: String
        public let cohort: TranscriptionQuality.Cohort
        public let audioURL: URL
        public let reference: String
        /// Only present when the index records it; the harness measures duration from the audio.
        public let durationSeconds: Double?

        public init(
            corpusID: String,
            id: String,
            cohort: TranscriptionQuality.Cohort,
            audioURL: URL,
            reference: String,
            durationSeconds: Double?
        ) {
            self.corpusID = corpusID
            self.id = id
            self.cohort = cohort
            self.audioURL = audioURL
            self.reference = reference
            self.durationSeconds = durationSeconds
        }
    }

    /// A row the store refused to hand to the harness, named so the maintainer can fix the index.
    struct Issue: Sendable, CustomStringConvertible {
        /// `nil` when the row did not decode far enough to have an id.
        public let sampleID: String?
        public let reason: Reason

        public init(sampleID: String?, reason: Reason) {
            self.sampleID = sampleID
            self.reason = reason
        }

        public var description: String {
            guard let sampleID else { return reason.description }
            return "\(sampleID): \(reason.description)"
        }

        public enum Reason: Sendable, CustomStringConvertible {
            case undecodableEntry(line: Int, message: String)
            case emptyReference
            case referenceTooLong(bytes: Int, limit: Int)
            case audioOutsideCorpus(String)
            case missingAudio(String)

            public var description: String {
                switch self {
                case let .undecodableEntry(line, message):
                    return "sample index line \(line) did not decode (\(message))"
                case .emptyReference:
                    return "reference transcript is empty"
                case let .referenceTooLong(bytes, limit):
                    return "reference transcript is \(bytes) bytes, over the \(limit) byte cap"
                case let .audioOutsideCorpus(path):
                    return "audio path \"\(path)\" resolves outside the corpus directory"
                case let .missingAudio(path):
                    return "audio file \"\(path)\" is missing"
                }
            }
        }
    }
}

/// The local, never-committed store of evaluation corpora, discovered through the environment.
///
/// Discovery is total: an absent store, an unreadable one, and a corpus that may not be evaluated
/// are all *reported*, never thrown. The harness has to be able to run on whatever subset of
/// corpora a maintainer has managed to obtain (R4), and a missing store must skip the harness
/// rather than fail it (R1, AE2).
public struct TranscriptionCorpusStore: Sendable {
    /// Follows the repository's existing `MUESLI_*_DIR` convention for maintainer-only paths rather
    /// than adding a user-facing config key (KTD7).
    public static let environmentVariable = "MUESLI_ASR_CORPUS_DIR"

    public static let descriptorFileName = "corpus.json"

    public static let supportedSchemaVersion = 1

    /// Mirrors `maximumTextFieldBytes` in `Fixtures/TranscriptionQuality/manifest.json`. A reference
    /// far past this is an adapter that swept up a whole transcript file into one row, not a long
    /// utterance — and holding the line here keeps store rows comparable to fixture rows.
    public static let maximumReferenceBytes = 2048

    /// `nil` when `MUESLI_ASR_CORPUS_DIR` is unset — the store is absent rather than empty.
    public let root: URL?
    /// Corpora that may be evaluated: descriptor decoded, schema supported, licence recorded.
    public let corpora: [TranscriptionCorpus]
    /// Everything under the root that will not be evaluated, each with a name and a reason.
    public let refusals: [Refusal]

    public init(root: URL?, corpora: [TranscriptionCorpus], refusals: [Refusal]) {
        self.root = root
        self.corpora = corpora
        self.refusals = refusals
    }

    public var isEmpty: Bool { corpora.isEmpty }

    /// Every usable sample across every evaluable corpus, in corpus order.
    public var samples: [TranscriptionCorpus.Sample] { corpora.flatMap(\.samples) }

    public func samples(for cohort: TranscriptionQuality.Cohort) -> [TranscriptionCorpus.Sample] {
        samples.filter { $0.cohort == cohort }
    }

    public var coveredCohorts: Set<TranscriptionQuality.Cohort> {
        corpora.reduce(into: Set()) { $0.formUnion($1.cohorts) }
    }

    /// The cohorts this store cannot say anything about. The harness reports these rather than
    /// failing, so a partial acquisition still produces a valid, narrower result (R4, AE3).
    public var uncoveredCohorts: [TranscriptionQuality.Cohort] {
        let covered = coveredCohorts
        return TranscriptionQuality.Cohort.allCases.filter { !covered.contains($0) }
    }

    /// A corpus that will not be evaluated, and why.
    public struct Refusal: Sendable, CustomStringConvertible {
        /// The descriptor's `id` when it decoded, otherwise the directory name.
        public let name: String
        public let directoryName: String
        public let reason: Reason

        public init(name: String, directoryName: String, reason: Reason) {
            self.name = name
            self.directoryName = directoryName
            self.reason = reason
        }

        public var description: String { "\(name): \(reason.description)" }

        public enum Reason: Sendable, Equatable, CustomStringConvertible {
            case unreadableRoot(String)
            case missingDescriptor
            case undecodableDescriptor(String)
            case unsupportedSchemaVersion(Int)
            /// R3's gate. An unrecorded licence is not permission, so the corpus is skipped whole.
            case missingLicence
            case unreadableSampleIndex(String)

            public var description: String {
                switch self {
                case let .unreadableRoot(message):
                    return "corpus store directory could not be read (\(message))"
                case .missingDescriptor:
                    return "no \(TranscriptionCorpusStore.descriptorFileName) in the corpus directory"
                case let .undecodableDescriptor(message):
                    return "\(TranscriptionCorpusStore.descriptorFileName) did not decode (\(message))"
                case let .unsupportedSchemaVersion(version):
                    return "descriptor schema version \(version) is not supported"
                case .missingLicence:
                    return "no licence recorded, so the corpus may not be evaluated"
                case let .unreadableSampleIndex(path):
                    return "sample index \"\(path)\" could not be read"
                }
            }
        }
    }
}

// MARK: - Discovery

public extension TranscriptionCorpusStore {
    /// An absent `MUESLI_ASR_CORPUS_DIR` yields an empty store and no error: the harness that reads
    /// it must skip, and a machine with no corpora is the normal case for everyone but the
    /// maintainer running the sweep (R1, AE2).
    static func discover(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> TranscriptionCorpusStore {
        let path = environment[environmentVariable]?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let path, !path.isEmpty else {
            return TranscriptionCorpusStore(root: nil, corpora: [], refusals: [])
        }
        return load(root: URL(fileURLWithPath: path, isDirectory: true), fileManager: fileManager)
    }

    /// Reads every immediate subdirectory of `root` as one corpus, sorted by directory name so a
    /// run's corpus order does not depend on filesystem enumeration order.
    static func load(root: URL, fileManager: FileManager = .default) -> TranscriptionCorpusStore {
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey]
            )
        } catch {
            // A configured-but-unreadable store is a misconfiguration worth naming, but still not
            // worth failing over: the caller decides whether an empty store is fatal.
            return TranscriptionCorpusStore(
                root: root,
                corpora: [],
                refusals: [Refusal(
                    name: root.lastPathComponent,
                    directoryName: root.lastPathComponent,
                    reason: .unreadableRoot(error.localizedDescription)
                )]
            )
        }

        var corpora: [TranscriptionCorpus] = []
        var refusals: [Refusal] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory
            guard isDirectory == true else { continue }
            switch loadCorpus(at: entry, fileManager: fileManager) {
            case let .accepted(corpus):
                corpora.append(corpus)
            case let .refused(refusal):
                refusals.append(refusal)
            }
        }
        return TranscriptionCorpusStore(root: root, corpora: corpora, refusals: refusals)
    }

    private static func loadCorpus(
        at directory: URL,
        fileManager: FileManager
    ) -> CorpusOutcome {
        let directoryName = directory.lastPathComponent
        func refuse(_ name: String, _ reason: Refusal.Reason) -> CorpusOutcome {
            .refused(Refusal(name: name, directoryName: directoryName, reason: reason))
        }

        let descriptorURL = directory.appendingPathComponent(descriptorFileName)
        guard let descriptorData = try? Data(contentsOf: descriptorURL) else {
            return refuse(directoryName, .missingDescriptor)
        }
        let descriptor: TranscriptionCorpus.Descriptor
        do {
            descriptor = try JSONDecoder().decode(
                TranscriptionCorpus.Descriptor.self,
                from: descriptorData
            )
        } catch {
            return refuse(directoryName, .undecodableDescriptor(describe(error)))
        }
        guard descriptor.schemaVersion == supportedSchemaVersion else {
            return refuse(descriptor.id, .unsupportedSchemaVersion(descriptor.schemaVersion))
        }
        // R3's licence gate: a blank identifier records nothing, so it is treated as no licence.
        let identifier = descriptor.licence?.identifier
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !identifier.isEmpty else {
            return refuse(descriptor.id, .missingLicence)
        }

        let indexURL = directory.appendingPathComponent(descriptor.sampleIndex)
        guard let indexData = try? Data(contentsOf: indexURL) else {
            return refuse(descriptor.id, .unreadableSampleIndex(descriptor.sampleIndex))
        }
        let index = resolveSamples(
            indexData: indexData,
            descriptor: descriptor,
            directory: directory,
            fileManager: fileManager
        )
        return .accepted(TranscriptionCorpus(
            directoryName: directoryName,
            directory: directory,
            descriptor: descriptor,
            samples: index.samples,
            issues: index.issues
        ))
    }

    private static func resolveSamples(
        indexData: Data,
        descriptor: TranscriptionCorpus.Descriptor,
        directory: URL,
        fileManager: FileManager
    ) -> (samples: [TranscriptionCorpus.Sample], issues: [TranscriptionCorpus.Issue]) {
        let decoder = JSONDecoder()
        // Lexical standardization on both sides: `standardizedFileURL` touches the filesystem and
        // rewrites an existing `/var/...` path to `/private/var/...`, so a present and an absent
        // file under the same directory would not share a prefix.
        let base = directory.standardized.path
        var samples: [TranscriptionCorpus.Sample] = []
        var issues: [TranscriptionCorpus.Issue] = []

        // Line numbers count blank lines too, so a reported number matches what an editor shows.
        for (offset, line) in indexData.split(separator: 0x0A, omittingEmptySubsequences: false).enumerated() {
            let lineNumber = offset + 1
            guard !line.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) else { continue }
            let entry: SampleEntry
            do {
                entry = try decoder.decode(SampleEntry.self, from: Data(line))
            } catch {
                issues.append(TranscriptionCorpus.Issue(
                    sampleID: nil,
                    reason: .undecodableEntry(line: lineNumber, message: describe(error))
                ))
                continue
            }

            let referenceBytes = entry.reference.utf8.count
            guard !entry.reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                issues.append(TranscriptionCorpus.Issue(sampleID: entry.id, reason: .emptyReference))
                continue
            }
            guard referenceBytes <= maximumReferenceBytes else {
                issues.append(TranscriptionCorpus.Issue(
                    sampleID: entry.id,
                    reason: .referenceTooLong(bytes: referenceBytes, limit: maximumReferenceBytes)
                ))
                continue
            }

            let audioURL = directory.appendingPathComponent(entry.audio).standardized
            guard audioURL.path.hasPrefix(base + "/") else {
                issues.append(TranscriptionCorpus.Issue(
                    sampleID: entry.id,
                    reason: .audioOutsideCorpus(entry.audio)
                ))
                continue
            }
            // Per-sample, never per-corpus: one absent file must not cost the whole cohort (R4).
            guard fileManager.fileExists(atPath: audioURL.path) else {
                issues.append(TranscriptionCorpus.Issue(
                    sampleID: entry.id,
                    reason: .missingAudio(entry.audio)
                ))
                continue
            }

            samples.append(TranscriptionCorpus.Sample(
                corpusID: descriptor.id,
                id: entry.id,
                cohort: entry.cohort ?? descriptor.cohort,
                audioURL: audioURL,
                reference: entry.reference,
                durationSeconds: entry.durationSeconds
            ))
        }
        return (samples, issues)
    }

    /// `DecodingError.localizedDescription` says only that the data was in the wrong format, which
    /// would hide the one thing a maintainer needs — the offending key or value.
    private static func describe(_ error: any Error) -> String {
        guard let decoding = error as? DecodingError else { return error.localizedDescription }
        let context: DecodingError.Context
        switch decoding {
        case let .dataCorrupted(value): context = value
        case let .keyNotFound(_, value): context = value
        case let .typeMismatch(_, value): context = value
        case let .valueNotFound(_, value): context = value
        @unknown default: return error.localizedDescription
        }
        let path = context.codingPath.map(\.stringValue).joined(separator: ".")
        return path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
    }
}

/// The two ways a corpus directory can end up. A refusal is a report, not a thrown error, so it
/// deliberately does not travel as `Result`'s failure.
private enum CorpusOutcome {
    case accepted(TranscriptionCorpus)
    case refused(TranscriptionCorpusStore.Refusal)
}

/// One line of a corpus's sample index, as written on disk.
private struct SampleEntry: Decodable {
    let id: String
    /// Relative to the corpus directory.
    let audio: String
    let reference: String
    /// Overrides the descriptor's cohort for corpora that mix monolingual and code-switched rows.
    let cohort: TranscriptionQuality.Cohort?
    let durationSeconds: Double?
}
