import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("DictationStyleRulesetCodec")
struct DictationStyleRulesetCodecTests {
    @Test("export is narrow deterministic and preserves divergent global prompt bytes")
    func exportIsNarrowAndDeterministic() throws {
        var config = sampleConfig()
        config.postProcessorSystemPrompt = "Global bytes\nremain exact\t"
        let first = try DictationStyleRulesetCodec.encode(config)
        var reordered = config
        reordered.dictationStyleGroups.reverse()
        reordered.customTranscriptCleanupPrompts.reverse()
        let second = try DictationStyleRulesetCodec.encode(reordered)
        let json = try #require(JSONSerialization.jsonObject(with: first) as? [String: Any])

        #expect(first == second)
        #expect(json["openai_api_key"] == nil)
        #expect(json["post_processor_backend"] == nil)
        #expect(json["enable_screen_context"] == nil)
        let decoded = try DictationStyleRulesetCodec.decode(first)
        #expect(decoded.globalDefault.prompt == "Global bytes\nremain exact\t")
        #expect(decoded.globalDefault.styleID == "default")
    }

    @Test("strict decode rejects unsupported and unsafe documents")
    func strictDecodeRejectsInvalidDocuments() throws {
        #expect(throws: DictationStyleRulesetCodec.Error.self) {
            try DictationStyleRulesetCodec.decode(Data("{\"version\":2}".utf8))
        }
        var invalid = try DictationStyleRulesetCodec.ruleset(from: sampleConfig())
        invalid.groups.append(invalid.groups[0])
        let data = try JSONEncoder().encode(invalid)
        #expect(throws: DictationStyleRulesetCodec.Error.self) {
            try DictationStyleRulesetCodec.decode(data)
        }
        var controls = try DictationStyleRulesetCodec.ruleset(from: sampleConfig())
        controls.customStyles[0].name = "bad\u{202E}name"
        #expect(throws: DictationStyleRulesetCodec.Error.self) {
            try DictationStyleRulesetCodec.decode(try JSONEncoder().encode(controls))
        }
        var paddedIdentifier = try DictationStyleRulesetCodec.ruleset(from: sampleConfig())
        paddedIdentifier.groups[0].id = " padded "
        #expect(throws: DictationStyleRulesetCodec.Error.self) {
            try DictationStyleRulesetCodec.decode(try JSONEncoder().encode(paddedIdentifier))
        }
        #expect(throws: DictationStyleRulesetCodec.Error.self) {
            try DictationStyleRulesetCodec.decode(Data(repeating: 0x20, count: DictationStyleRulesetCodec.maximumFileBytes + 1))
        }
    }

    @Test("preview is replacement-only, preserves disabled state, and identifies semantic changes")
    func previewPreservesDisabledState() throws {
        var current = sampleConfig()
        current.adaptiveDictationStylesEnabled = false
        var imported = try DictationStyleRulesetCodec.ruleset(from: current)
        imported.groups[0].styleID = "default"
        let preview = try DictationStyleRulesetCodec.preview(imported: imported, replacing: current)
        let candidate = try DictationStyleRulesetCodec.candidate(from: preview.ruleset, replacing: current)

        #expect(!preview.rulesWillBeActive)
        #expect(!preview.changes.isEmpty)
        #expect(candidate.adaptiveDictationStylesEnabled == false)
        #expect(candidate.dictationStyleGroups[0].styleID == "default")
    }

    @Test("preview resolves wildcard witnesses instead of treating patterns as targets")
    func previewUsesValidWildcardWitnesses() throws {
        var current = sampleConfig()
        current.adaptiveDictationStylesEnabled = true
        current.dictationStyleGroups[0].matchers = [
            DictationStyleMatcher(id: "work-mail", kind: .hostname, pattern: "*.example.com"),
        ]
        var imported = try DictationStyleRulesetCodec.ruleset(from: current)
        imported.groups[0].styleID = "default"

        let preview = try DictationStyleRulesetCodec.preview(imported: imported, replacing: current)

        #expect(preview.effectiveChanges == ["Effective style changed for a.example.com"])
    }

    @Test("preview reports source changes even when the effective style is unchanged")
    func previewIncludesSelectionProvenance() throws {
        var current = sampleConfig()
        current.adaptiveDictationStylesEnabled = true
        current.dictationStyleGroups = [
            DictationStyleGroup(id: "mail", name: "Mail", styleID: "email", matchers: [
                DictationStyleMatcher(id: "mail-app", kind: .bundleID, pattern: "com.apple.mail"),
            ]),
        ]
        current.dictationStyleExactExceptions = [
            DictationStyleExactException(id: "mail-exception", kind: .bundleID, target: "com.apple.mail", styleID: "email"),
        ]
        var imported = try DictationStyleRulesetCodec.ruleset(from: current)
        imported.exactExceptions = []

        let preview = try DictationStyleRulesetCodec.preview(imported: imported, replacing: current)

        #expect(preview.effectiveChanges == ["Effective style changed for com.apple.mail"])
    }

    @Test("URL import rejects oversized and non-regular files before decoding")
    func boundedURLImport() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let oversized = directory.appendingPathComponent("oversized.json")
        try Data(repeating: 0x20, count: DictationStyleRulesetCodec.maximumFileBytes + 1).write(to: oversized)

        #expect(throws: DictationStyleRulesetCodec.Error.fileTooLarge) {
            try DictationStyleRulesetCodec.decode(contentsOf: oversized)
        }
        #expect(throws: DictationStyleRulesetCodec.Error.invalidFormat) {
            try DictationStyleRulesetCodec.decode(contentsOf: directory)
        }
    }

    @Test("unmodified export and import keep the portable projection equivalent")
    func unchangedRoundTripIsEquivalent() throws {
        let config = sampleConfig()
        let exported = try DictationStyleRulesetCodec.decode(DictationStyleRulesetCodec.encode(config))
        let candidate = try DictationStyleRulesetCodec.candidate(from: exported, replacing: config)
        #expect(try DictationStyleRulesetCodec.ruleset(from: candidate) == exported)
    }

    private func sampleConfig() -> AppConfig {
        var config = AppConfig()
        config.dictationStyleRulesetInitialized = true
        config.customTranscriptCleanupPrompts = [
            CustomTranscriptCleanupPrompt(id: "formal", name: "Formal", prompt: "Use a formal tone."),
        ]
        config.activeTranscriptCleanupPromptId = "default"
        config.postProcessorSystemPrompt = "Global prompt"
        config.dictationStyleGroups = [
            DictationStyleGroup(id: "work", name: "Work", styleID: "formal", matchers: [
                DictationStyleMatcher(id: "work-mail", kind: .hostname, pattern: "mail.example.com"),
            ]),
        ]
        config.dictationStyleExactExceptions = [
            DictationStyleExactException(id: "mail-exception", kind: .bundleID, target: "com.apple.mail", styleID: "email"),
        ]
        return config
    }
}
