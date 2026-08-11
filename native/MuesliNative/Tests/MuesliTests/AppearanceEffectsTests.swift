import Testing
import AppKit
@testable import MuesliNativeApp

@Suite("SoundController")
@MainActor
struct SoundControllerTests {

    @Test("playDictationStart with enabled=false does not throw")
    func playStartDisabled() {
        // NSSound.play() is a no-op in the test runner (no audio device required)
        SoundController.playDictationStart(enabled: false)
    }

    @Test("playDictationInsert with enabled=false does not throw")
    func playInsertDisabled() {
        SoundController.playDictationInsert(enabled: false)
    }

    @Test("playDictationStart with enabled=true does not throw")
    func playStartEnabled() {
        SoundController.playDictationStart(enabled: true)
    }

    @Test("playDictationInsert with enabled=true does not throw")
    func playInsertEnabled() {
        SoundController.playDictationInsert(enabled: true)
    }
}

@Suite("MenuBarIconRenderer")
struct MenuBarIconRendererTests {

    @Test("make(choice:) returns a non-nil image for SF Symbol")
    func makeReturnsImage() {
        let image = MenuBarIconRenderer.make(choice: "mic.fill")
        #expect(image != nil)
    }

    @Test("every selectable SF Symbol is available as a template image")
    func makeIsTemplate() {
        for option in MenuBarIconRenderer.options where option.id != "muesli" {
            let image = MenuBarIconRenderer.make(choice: option.id)
            #expect(image != nil, "Missing selectable icon: \(option.id)")
            #expect(image?.isTemplate == true, "Non-template selectable icon: \(option.id)")
        }
    }

    @Test("make(choice:) returns a non-zero size image")
    func makeHasSize() {
        let image = MenuBarIconRenderer.make(choice: "mic.fill")
        #expect((image?.size.width ?? 0) > 0)
        #expect((image?.size.height ?? 0) > 0)
    }

    @MainActor
    @Test("floating indicator preserves template rendering across setup and refresh")
    func floatingIndicatorPreservesTemplateRendering() {
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let configStore = ConfigStore(supportDirectory: supportDirectory)
        var config = AppConfig()
        config.menuBarIcon = "sparkles"
        configStore.save(config)
        let indicator = FloatingIndicatorController(configStore: configStore)

        indicator.setState(.idle, config: config)
        #expect(indicator.idleIconIsTemplateForTesting == true)

        indicator.refreshIcon()
        #expect(indicator.idleIconIsTemplateForTesting == true)
        indicator.close()
    }
}
