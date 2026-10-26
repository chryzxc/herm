import Foundation
import Testing

@testable import Herm

struct HermesSimulatorPreferenceTests {
    @Test func defaultsOnAndPersistsExplicitOff() throws {
        let name = "SimulatorPreference-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(HermesSimulatorPreference.isEnabled(defaults: defaults))
        defaults.set(false, forKey: HermesSimulatorPreference.key)
        #expect(!HermesSimulatorPreference.isEnabled(defaults: defaults))
        #expect(!HermesSimulatorPreference.isEnabled(defaults: try #require(UserDefaults(suiteName: name))))
        defaults.set(true, forKey: HermesSimulatorPreference.key)
        #expect(HermesSimulatorPreference.isEnabled(defaults: defaults))
    }

    @Test func submissionsAndSteeringUseCurrentPreferenceWithoutChangingScope() throws {
        let name = "SimulatorPreference-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        for method in [HermesFeatureIDs.ID.promptSubmit, .sessionRedirect, .sessionSteer] {
            let params: [String: Any] = [
                "text": "Launch Android", "session_id": "a", "profile_id": "b", "queued": true,
            ]
            let on = HermesSimulatorPreference.applying(to: params, method: method.rawValue, defaults: defaults)
            let text = try #require(on["text"] as? String)
            #expect(text.hasPrefix("Launch Android\n\n"))
            #expect(text.contains("ON."))
            #expect(text.contains("use the herm_simulator tool"))
            #expect(text.contains("If the tool is unavailable"))
            #expect(on["session_id"] as? String == "a")
            #expect(on["profile_id"] as? String == "b")
            #expect(on["queued"] as? Bool == true)
            defaults.set(false, forKey: HermesSimulatorPreference.key)
            let off = HermesSimulatorPreference.applying(to: params, method: method.rawValue, defaults: defaults)
            #expect((off["text"] as? String)?.contains("supersedes earlier ON instructions") == true)
            defaults.removeObject(forKey: HermesSimulatorPreference.key)
        }
        let untouched = HermesSimulatorPreference.applying(
            to: ["text": "command"], method: "shell.exec", defaults: defaults)
        #expect(untouched["text"] as? String == "command")
        #expect(
            HermesSimulatorPreference.applying(
                to: [:], method: HermesFeatureIDs.ID.promptSubmit.rawValue, defaults: defaults
            ).isEmpty)
    }
}
