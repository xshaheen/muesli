import Foundation
import MuesliCore
import Testing

/// Contract for the local corpus store. Nothing here reads a real corpus: every case builds its
/// own store in a temporary directory, so the suite is green on a machine that has never
/// downloaded a dataset.
@Suite("Transcription corpus store")
struct TranscriptionCorpusStoreTests {
    @Test("an unset corpus directory yields an empty store and no error")
    func absentStore() {
        let store = TranscriptionCorpusStore.discover(environment: [:])

        #expect(store.root == nil)
        #expect(store.isEmpty)
        #expect(store.corpora.isEmpty)
        #expect(store.refusals.isEmpty)
        #expect(store.samples.isEmpty)
        #expect(store.uncoveredCohorts == TranscriptionQuality.Cohort.allCases)
    }

    @Test("a blank corpus directory value is treated as unset")
    func blankStorePath() {
        let store = TranscriptionCorpusStore.discover(
            environment: [TranscriptionCorpusStore.environmentVariable: "   "]
        )

        #expect(store.root == nil)
        #expect(store.isEmpty)
        #expect(store.refusals.isEmpty)
    }

    @Test("a licensed corpus evaluates, an unlicensed one is refused by name, and cohorts are reported")
    func licenceGate() throws {
        try withTemporaryStore { root in
            try Corpus(directory: "mgb3", id: "mgb-3", cohort: "egyptian-arabic")
                .withLicence("cc-by-nc-4.0")
                .adding(id: "mgb3-001", audio: "audio/001.wav", reference: "الشغل خلص امبارح")
                .adding(id: "mgb3-002", audio: "audio/002.wav", reference: "الاجتماع الساعة تسعة")
                .write(in: root)
            try Corpus(directory: "arabic-egy-cleaned", id: "arabic-egy-cleaned", cohort: "egyptian-arabic")
                .adding(id: "aec-001", audio: "audio/001.wav", reference: "كلام مسجل")
                .write(in: root)

            let store = TranscriptionCorpusStore.discover(
                environment: [TranscriptionCorpusStore.environmentVariable: root.path]
            )

            #expect(store.corpora.map(\.id) == ["mgb-3"])
            #expect(store.samples.count == 2)
            #expect(store.samples.allSatisfy { $0.corpusID == "mgb-3" })
            #expect(store.samples(for: .egyptianArabic).count == 2)
            #expect(store.corpora[0].descriptor.licence?.identifier == "cc-by-nc-4.0")
            #expect(store.corpora[0].descriptor.revision == "v1")
            #expect(store.corpora[0].descriptor.acquisition == .huggingFace)
            #expect(store.corpora[0].issues.isEmpty)

            let refusal = try #require(store.refusals.first)
            #expect(store.refusals.count == 1)
            #expect(refusal.name == "arabic-egy-cleaned")
            #expect(refusal.directoryName == "arabic-egy-cleaned")
            #expect(refusal.reason == .missingLicence)
            #expect(refusal.description.contains("arabic-egy-cleaned"))
            #expect(refusal.description.contains("licence"))

            #expect(store.coveredCohorts == [.egyptianArabic])
            #expect(store.uncoveredCohorts == [.english, .arabicEnglish])
        }
    }

    @Test("a descriptor with an unknown cohort is refused, naming the offending value")
    func unknownCohort() throws {
        try withTemporaryStore { root in
            try Corpus(directory: "masri", id: "masri", cohort: "masri-arabic")
                .withLicence("cc-by-4.0")
                .adding(id: "masri-001", audio: "audio/001.wav", reference: "كلام")
                .write(in: root)

            let store = TranscriptionCorpusStore.load(root: root)

            #expect(store.corpora.isEmpty)
            let refusal = try #require(store.refusals.first)
            #expect(refusal.name == "masri")
            #expect(refusal.description.contains("masri-arabic"))
            #expect(refusal.description.contains("cohort"))
        }
    }

    @Test("a descriptor with an unknown acquisition method is refused, naming the offending value")
    func unknownAcquisition() throws {
        try withTemporaryStore { root in
            try Corpus(directory: "mixat", id: "mixat", cohort: "arabic-english")
                .withLicence("cc-by-4.0")
                .withAcquisition("carrier-pigeon")
                .adding(id: "mixat-001", audio: "audio/001.wav", reference: "yalla let's go")
                .write(in: root)

            let store = TranscriptionCorpusStore.load(root: root)

            #expect(store.corpora.isEmpty)
            let refusal = try #require(store.refusals.first)
            #expect(refusal.description.contains("carrier-pigeon"))
        }
    }

    @Test("an unsupported descriptor schema version is refused")
    func unsupportedSchemaVersion() throws {
        try withTemporaryStore { root in
            try Corpus(directory: "zaebuc", id: "zaebuc-spoken", cohort: "arabic-english")
                .withLicence("cc-by-4.0")
                .withSchemaVersion(99)
                .adding(id: "z-001", audio: "audio/001.wav", reference: "hello يا صاحبي")
                .write(in: root)

            let store = TranscriptionCorpusStore.load(root: root)

            #expect(store.corpora.isEmpty)
            let refusal = try #require(store.refusals.first)
            #expect(refusal.reason == .unsupportedSchemaVersion(99))
        }
    }

    @Test("a corpus directory with no descriptor is refused by directory name")
    func missingDescriptor() throws {
        try withTemporaryStore { root in
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("stray", isDirectory: true),
                withIntermediateDirectories: true
            )

            let store = TranscriptionCorpusStore.load(root: root)

            #expect(store.corpora.isEmpty)
            let refusal = try #require(store.refusals.first)
            #expect(refusal.name == "stray")
            #expect(refusal.reason == .missingDescriptor)
        }
    }

    @Test("a corpus whose sample index is missing is refused rather than silently empty")
    func missingSampleIndex() throws {
        try withTemporaryStore { root in
            try Corpus(directory: "casablanca", id: "casablanca", cohort: "egyptian-arabic")
                .withLicence("cc-by-nc-sa-4.0")
                .withSampleIndex("rows.jsonl", writeIndex: false)
                .write(in: root)

            let store = TranscriptionCorpusStore.load(root: root)

            #expect(store.corpora.isEmpty)
            let refusal = try #require(store.refusals.first)
            #expect(refusal.reason == .unreadableSampleIndex("rows.jsonl"))
        }
    }

    @Test("a sample with missing audio is reported per sample, leaving the corpus usable")
    func missingAudioIsPerSample() throws {
        try withTemporaryStore { root in
            try Corpus(directory: "mgb3", id: "mgb-3", cohort: "egyptian-arabic")
                .withLicence("cc-by-nc-4.0")
                .adding(id: "mgb3-001", audio: "audio/001.wav", reference: "موجود")
                .adding(id: "mgb3-002", audio: "audio/002.wav", reference: "ناقص", writeAudio: false)
                .write(in: root)

            let store = TranscriptionCorpusStore.load(root: root)

            let corpus = try #require(store.corpora.first)
            #expect(corpus.samples.map(\.id) == ["mgb3-001"])
            #expect(store.coveredCohorts == [.egyptianArabic])

            let issue = try #require(corpus.issues.first)
            #expect(corpus.issues.count == 1)
            #expect(issue.sampleID == "mgb3-002")
            #expect(issue.description.contains("audio/002.wav"))
            #expect(issue.description.contains("missing"))
        }
    }

    @Test("a reference over the field cap is rejected per sample")
    func oversizedReferenceIsRejected() throws {
        let overCap = String(repeating: "a", count: TranscriptionCorpusStore.maximumReferenceBytes + 1)
        let atCap = String(repeating: "b", count: TranscriptionCorpusStore.maximumReferenceBytes)

        try withTemporaryStore { root in
            try Corpus(directory: "arzen", id: "arzen", cohort: "arabic-english")
                .withLicence("author-granted")
                .adding(id: "arzen-001", audio: "audio/001.wav", reference: atCap)
                .adding(id: "arzen-002", audio: "audio/002.wav", reference: overCap)
                .adding(id: "arzen-003", audio: "audio/003.wav", reference: "   ")
                .write(in: root)

            let store = TranscriptionCorpusStore.load(root: root)

            let corpus = try #require(store.corpora.first)
            #expect(corpus.samples.map(\.id) == ["arzen-001"])
            #expect(corpus.issues.map(\.sampleID) == ["arzen-002", "arzen-003"])
            #expect(corpus.issues[0].description.contains("\(TranscriptionCorpusStore.maximumReferenceBytes)"))
            #expect(corpus.issues[1].description.contains("empty"))
        }
    }

    @Test("audio paths escaping the corpus directory are rejected per sample")
    func audioEscapingCorpusIsRejected() throws {
        try withTemporaryStore { root in
            try Corpus(directory: "mgb3", id: "mgb-3", cohort: "egyptian-arabic")
                .withLicence("cc-by-nc-4.0")
                .adding(id: "mgb3-001", audio: "../outside.wav", reference: "برة", writeAudio: false)
                .write(in: root)
            FileManager.default.createFile(
                atPath: root.appendingPathComponent("outside.wav").path,
                contents: Data([0])
            )

            let store = TranscriptionCorpusStore.load(root: root)

            let corpus = try #require(store.corpora.first)
            #expect(corpus.samples.isEmpty)
            let issue = try #require(corpus.issues.first)
            #expect(issue.description.contains("outside the corpus directory"))
        }
    }

    @Test("an undecodable index line is reported with its line number, not the whole corpus")
    func undecodableIndexLine() throws {
        try withTemporaryStore { root in
            let corpus = try Corpus(directory: "mgb3", id: "mgb-3", cohort: "egyptian-arabic")
                .withLicence("cc-by-nc-4.0")
                .adding(id: "mgb3-001", audio: "audio/001.wav", reference: "تمام")
                .write(in: root)
            let index = corpus.appendingPathComponent("samples.jsonl")
            let existing = try String(contentsOf: index, encoding: .utf8)
            try (existing + "\n{ not json }\n").write(to: index, atomically: true, encoding: .utf8)

            let store = TranscriptionCorpusStore.load(root: root)

            let loaded = try #require(store.corpora.first)
            #expect(loaded.samples.count == 1)
            let issue = try #require(loaded.issues.first)
            #expect(issue.sampleID == nil)
            #expect(issue.description.contains("line 3"))
        }
    }

    @Test("a per-sample cohort overrides the descriptor's default")
    func perSampleCohortOverride() throws {
        try withTemporaryStore { root in
            try Corpus(directory: "arzen", id: "arzen", cohort: "arabic-english")
                .withLicence("author-granted")
                .adding(id: "arzen-001", audio: "audio/001.wav", reference: "yalla let's ship it")
                .adding(id: "arzen-002", audio: "audio/002.wav", reference: "قفلنا الموضوع", cohort: "egyptian-arabic")
                .write(in: root)

            let store = TranscriptionCorpusStore.load(root: root)

            #expect(store.samples(for: .arabicEnglish).map(\.id) == ["arzen-001"])
            #expect(store.samples(for: .egyptianArabic).map(\.id) == ["arzen-002"])
            #expect(store.uncoveredCohorts == [.english])
        }
    }

    @Test("a corpus store path that does not exist is refused, not thrown")
    func unreadableRoot() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-corpus-absent-\(UUID().uuidString)", isDirectory: true)

        let store = TranscriptionCorpusStore.discover(
            environment: [TranscriptionCorpusStore.environmentVariable: missing.path]
        )

        #expect(store.root == missing)
        #expect(store.isEmpty)
        #expect(store.refusals.count == 1)
        #expect(store.uncoveredCohorts == TranscriptionQuality.Cohort.allCases)
    }
}

// MARK: - Fixtures

private func withTemporaryStore(_ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("muesli-corpus-store-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root)
}

/// Writes a corpus directory the way the runbook describes one: a `corpus.json` descriptor beside
/// a JSON Lines sample index and its audio. Descriptors are emitted as raw JSON so the tests
/// exercise the real decoder rather than a Swift-side round trip.
private struct Corpus {
    let directory: String
    let id: String
    let cohort: String
    var schemaVersion = 1
    var licence: String?
    var acquisition = "hugging-face"
    var sampleIndex = "samples.jsonl"
    var writesIndex = true
    var rows: [Row] = []

    struct Row {
        let id: String
        let audio: String
        let reference: String
        let cohort: String?
        let writeAudio: Bool
    }

    func withLicence(_ identifier: String) -> Corpus {
        var copy = self
        copy.licence = identifier
        return copy
    }

    func withAcquisition(_ method: String) -> Corpus {
        var copy = self
        copy.acquisition = method
        return copy
    }

    func withSchemaVersion(_ version: Int) -> Corpus {
        var copy = self
        copy.schemaVersion = version
        return copy
    }

    func withSampleIndex(_ path: String, writeIndex: Bool) -> Corpus {
        var copy = self
        copy.sampleIndex = path
        copy.writesIndex = writeIndex
        return copy
    }

    func adding(
        id: String,
        audio: String,
        reference: String,
        cohort: String? = nil,
        writeAudio: Bool = true
    ) -> Corpus {
        var copy = self
        copy.rows.append(Row(id: id, audio: audio, reference: reference, cohort: cohort, writeAudio: writeAudio))
        return copy
    }

    @discardableResult
    func write(in root: URL) throws -> URL {
        let fileManager = FileManager.default
        let corpusURL = root.appendingPathComponent(directory, isDirectory: true)
        try fileManager.createDirectory(at: corpusURL, withIntermediateDirectories: true)

        var descriptor: [String: Any] = [
            "schemaVersion": schemaVersion,
            "id": id,
            "revision": "v1",
            "acquisition": acquisition,
            "cohort": cohort,
            "sampleIndex": sampleIndex,
        ]
        if let licence {
            descriptor["licence"] = [
                "identifier": licence,
                "sourceURL": "https://example.invalid/\(id)",
            ]
        }
        try JSONSerialization.data(withJSONObject: descriptor, options: [.sortedKeys])
            .write(to: corpusURL.appendingPathComponent("corpus.json"))

        var lines: [String] = []
        for row in rows {
            var object: [String: Any] = [
                "id": row.id,
                "audio": row.audio,
                "reference": row.reference,
            ]
            if let rowCohort = row.cohort {
                object["cohort"] = rowCohort
            }
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            lines.append(String(decoding: data, as: UTF8.self))

            guard row.writeAudio else { continue }
            let audioURL = corpusURL.appendingPathComponent(row.audio)
            try fileManager.createDirectory(
                at: audioURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            fileManager.createFile(atPath: audioURL.path, contents: Data([0x52, 0x49, 0x46, 0x46]))
        }
        if writesIndex {
            try (lines.joined(separator: "\n") + "\n")
                .write(to: corpusURL.appendingPathComponent(sampleIndex), atomically: true, encoding: .utf8)
        }
        return corpusURL
    }
}
