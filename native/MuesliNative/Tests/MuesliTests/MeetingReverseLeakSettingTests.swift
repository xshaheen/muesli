import Foundation
import Testing

@testable import MuesliNativeApp

@Suite("Meeting reverse leak setting")
struct MeetingReverseLeakSettingTests {
    @Test("the setting defaults on")
    func settingDefaultsOn() {
        #expect(AppConfig().meetingReverseLeakSuppression)
    }

    @Test("a config saved before this feature decodes as on")
    func absentKeyDecodesOn() throws {
        let json = Data(#"{"enable_post_processor": true}"#.utf8)

        let config = try JSONDecoder().decode(AppConfig.self, from: json)

        #expect(config.meetingReverseLeakSuppression)
    }

    @Test("an explicit false decodes as off")
    func explicitFalseDecodesOff() throws {
        let json = Data(#"{"meeting_reverse_leak_suppression": false}"#.utf8)

        let config = try JSONDecoder().decode(AppConfig.self, from: json)

        #expect(config.meetingReverseLeakSuppression == false)
    }

    @Test("the setting round-trips through encoding under its snake_case key")
    func settingRoundTrips() throws {
        var config = AppConfig()
        config.meetingReverseLeakSuppression = false

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(decoded.meetingReverseLeakSuppression == false)
        #expect(object["meeting_reverse_leak_suppression"] as? Bool == false)
    }

    @Test("the environment override disables the gate only for the value 0")
    func environmentOverrideDisablesOnlyForZero() {
        let key = MeetingReverseLeakSuppressor.environmentKey

        #expect(MeetingReverseLeakSuppressor.isDisabledByEnvironment([key: "0"]))
        #expect(MeetingReverseLeakSuppressor.isDisabledByEnvironment([:]) == false)
        #expect(MeetingReverseLeakSuppressor.isDisabledByEnvironment([key: "1"]) == false)
        #expect(MeetingReverseLeakSuppressor.isDisabledByEnvironment([key: "true"]) == false)
        #expect(MeetingReverseLeakSuppressor.isDisabledByEnvironment([key: ""]) == false)
    }
}
