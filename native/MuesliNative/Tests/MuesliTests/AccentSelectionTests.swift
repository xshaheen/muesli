import Foundation
import Testing
@testable import MuesliNativeApp

private func decodeConfig(_ json: String) throws -> AppConfig {
    try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
}

@Suite("Accent selection")
struct AccentSelectionTests {
    @Test("an empty config uses the product default")
    func emptyConfigUsesDefault() throws {
        let config = try decodeConfig("{}")

        #expect(config.recordingColorHex == AppConfig.defaultAccentMarker)
        #expect(config.accentOverrideHex == nil)
        #expect(MuesliTheme.resolvedAccentDarkHex(overrideHex: config.accentOverrideHex)
            == MuesliTheme.defaultAccentDarkHex)
    }

    @Test("the product default is Spark coral")
    func defaultAccentIsCoral() {
        #expect(MuesliTheme.defaultAccentDarkHex == 0xFF7043)
        #expect(MuesliTheme.defaultAccentDarkHex == DictationMiniPalette.accentHex)
    }

    @Test("a legacy sentinel migrates to the default and renders as it did before")
    func legacySentinelMigratesToDefault() throws {
        // 1e1e2e was both the shipped default and a selectable preset, so the two were the
        // same bytes. The app already treated it as "no override", so mapping it to the
        // explicit default marker preserves what every existing install renders today.
        let config = try decodeConfig(#"{"recording_color_hex":"1e1e2e"}"#)

        #expect(config.recordingColorHex == AppConfig.defaultAccentMarker)
        #expect(config.accentOverrideHex == nil)
        #expect(config.accentSelectionMigrated)
    }

    @Test("Dark chosen after the migration is kept as a real override")
    func darkSurvivesOnceMigrated() throws {
        // The migration is one-time. Without that gate it would re-fire on every launch and
        // silently erase a deliberate Dark pick.
        let config = try decodeConfig(
            #"{"recording_color_hex":"1e1e2e","accent_selection_migrated":true}"#
        )

        #expect(config.recordingColorHex == "1e1e2e")
        #expect(config.accentOverrideHex == "1e1e2e")
        #expect(MuesliTheme.resolvedAccentDarkHex(overrideHex: config.accentOverrideHex) == 0x1E1E2E)
    }

    @Test("any other preset resolves to itself")
    func presetResolvesToItself() throws {
        let config = try decodeConfig(#"{"recording_color_hex":"8b5cf6"}"#)

        #expect(config.accentOverrideHex == "8b5cf6")
        #expect(MuesliTheme.resolvedAccentDarkHex(overrideHex: config.accentOverrideHex) == 0x8B5CF6)
    }

    @Test("a malformed override falls back to the default")
    func malformedOverrideFallsBack() throws {
        let config = try decodeConfig(#"{"recording_color_hex":"not-a-color"}"#)

        #expect(MuesliTheme.resolvedAccentDarkHex(overrideHex: config.accentOverrideHex)
            == MuesliTheme.defaultAccentDarkHex)
    }

    @Test("the accent survives a snake_case round trip")
    func roundTripKeepsSnakeCase() throws {
        var config = try decodeConfig("{}")
        config.recordingColorHex = "10b981"
        config.accentSelectionMigrated = true

        let data = try JSONEncoder().encode(config)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("recording_color_hex"))
        #expect(json.contains("accent_selection_migrated"))

        let reloaded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(reloaded.accentOverrideHex == "10b981")
    }
}
