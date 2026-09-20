import Foundation
import ImlaCore
import Testing
@testable import ImlaNativeApp

@Suite("Settings adaptive layout")
struct SettingsLayoutTests {
    @Test("wide rows reserve a shared trailing control column")
    func wideRows() {
        let columns = SettingsRowLayout(controlWidth: 275).columns(width: 700, idealLabelWidth: 180)
        #expect(!columns.isStacked)
        #expect(columns.labelWidth == 405)
        #expect(columns.controlWidth == 275)
    }

    @Test("narrow rows stack and constrain both children to the available width")
    func narrowRows() {
        let columns = SettingsRowLayout(controlWidth: 275).columns(width: 240, idealLabelWidth: 180)
        #expect(columns.isStacked)
        #expect(columns.labelWidth == 240)
        #expect(columns.controlWidth == 240)
    }

    @Test("a long label stacks before it collides with the control")
    func longLabels() {
        let layout = SettingsRowLayout(controlWidth: 275)
        #expect(!layout.columns(width: 540, idealLabelWidth: 180).isStacked)
        #expect(layout.columns(width: 540, idealLabelWidth: 400).isStacked)
        #expect(!layout.columns(width: 615, idealLabelWidth: 400).isStacked)
    }

    @Test("zero-width measurement never proposes a negative child width")
    func zeroWidth() {
        let columns = SettingsRowLayout().columns(width: 0, idealLabelWidth: 180)
        #expect(columns.isStacked)
        #expect(columns.labelWidth == 0)
        #expect(columns.controlWidth == 0)
    }

    @Test("language rows combine keyboard and saved languages without duplicates")
    @MainActor
    func languageRows() {
        var preferences = LanguageModelPreferences()
        preferences[.arabic] = .init(dictation: .init(.cohereArabic))
        preferences[.french] = .init()
        let languages = LanguageModelsSettingsView.displayedLanguages(keyboard: [.english, .arabic], preferences: preferences)
        #expect(Set(languages) == Set([.english, .arabic, .french]))
        #expect(languages.count == 3)
        #expect(LanguageModelsSettingsView.displayedLanguages(keyboard: [], preferences: .init()) == [.english])
    }
}
