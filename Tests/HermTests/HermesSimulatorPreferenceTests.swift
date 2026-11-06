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
            #expect(text.contains("herm_simulator_interact"))
            #expect(text.contains("Capture first"))
            #expect(
                HermesSimulatorPreference.agentSurface(defaults: defaults)?.rules.contains("herm_simulator_interact")
                    == true)
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

    @Test func hermPluginReplacesPerMessageNotes() {
        let params: [String: Any] = ["text": "Launch Android"]
        let served = HermesSimulatorPreference.applying(
            to: params, method: HermesFeatureIDs.ID.promptSubmit.rawValue, servedByPlugin: true)
        #expect(served["text"] as? String == "Launch Android")
        #expect(GenerativeUIIntegration.preparePrompt("Request", enabled: true, servedByPlugin: true) == "Request")
        #expect(HermPlugin.isEnabled(in: ["plugins": [["name": "herm", "enabled": true]]]))
        #expect(!HermPlugin.isEnabled(in: ["plugins": [["name": "herm", "enabled": false]]]))
        #expect(!HermPlugin.isEnabled(in: ["plugins": [["name": "herm-simulator", "enabled": true]]]))
        #expect(!HermPlugin.isEnabled(in: nil))
    }

    @Test func missingPluginProbeKeepsLastAnswer() {
        #expect(HermPlugin.isLoaded(after: nil) == nil)
        #expect(HermPlugin.isLoaded(after: ["plugins": [["name": "herm", "enabled": false]]]) == false)
        #expect(HermPlugin.isLoaded(after: ["plugins": [["name": "herm", "enabled": true]]]) == true)
    }
}
