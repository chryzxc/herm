import Foundation
import Testing
import UserNotifications

@testable import Herm

struct HermNotificationPreferencesTests {
    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let suite = "HermNotificationPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults)
    }

    private func notice(_ kind: HermNotice.Kind, source: HermNotice.Source = .session) -> HermNotice {
        HermNotice(kind: kind, source: source, profileID: nil, sourceID: "source", eventID: "event")
    }

    @Test func existingAttentionAndSoundDefaultsArePreserved() {
        withDefaults { defaults in
            #expect(HermNotificationPreferences.sound(defaults: defaults) != nil)
            #expect(HermNotificationPreferences.allows(notice(.approval), defaults: defaults))
            #expect(HermNotificationPreferences.allows(notice(.clarification), defaults: defaults))
            #expect(HermNotificationPreferences.allows(notice(.failure), defaults: defaults))
            #expect(!HermNotificationPreferences.allows(notice(.completion), defaults: defaults))
            defaults.set(false, forKey: HermNotificationPreferences.soundKey)
            defaults.set(false, forKey: HermNotificationPreferences.attentionKey)
            #expect(HermNotificationPreferences.sound(defaults: defaults) == nil)
            #expect(!HermNotificationPreferences.allows(notice(.approval), defaults: defaults))
            #expect(!HermNotificationPreferences.allows(notice(.clarification), defaults: defaults))
            #expect(HermNotificationPreferences.allows(notice(.failure), defaults: defaults))
        }
    }

    @Test func featureSwitchesAreIndependentOfChatCompletionPreference() {
        withDefaults { defaults in
            let features: [(HermNotice.Source, String)] = [
                (.routine, HermNotificationPreferences.automationKey),
                (.kanban, HermNotificationPreferences.kanbanKey),
                (.quota, HermNotificationPreferences.quotaKey),
                (.repository, HermNotificationPreferences.pullRequestKey),
            ]
            defaults.set(true, forKey: HermNotificationPreferences.completionKey)
            for (source, key) in features {
                #expect(!HermNotificationPreferences.allows(notice(.information, source: source), defaults: defaults))
                defaults.set(true, forKey: key)
                #expect(HermNotificationPreferences.allows(notice(.completion, source: source), defaults: defaults))
                #expect(HermNotificationPreferences.allows(notice(.failure, source: source), defaults: defaults))
                defaults.set(false, forKey: key)
            }
            #expect(HermNotificationPreferences.allows(notice(.completion), defaults: defaults))
        }
    }

    @Test func snoozeSuppressesEvenBlockingBannersAndExpiresAcrossRestart() {
        withDefaults { defaults in
            let now = Date(timeIntervalSince1970: 1000)
            defaults.set(1100.0, forKey: HermNotificationPreferences.snoozeKey)
            for kind in [HermNotice.Kind.approval, .clarification, .failure] {
                #expect(!HermNotificationPreferences.allows(notice(kind), defaults: defaults, now: now))
                #expect(
                    HermNotificationPreferences.allows(
                        notice(kind), defaults: defaults, now: Date(timeIntervalSince1970: 1100)))
            }
            #expect(defaults.double(forKey: HermNotificationPreferences.snoozeKey) == 1100)
        }
    }

    @Test func everyBannerCategoryOffersSnoozeWithoutAnsweringARequest() {
        for category in HermNotificationAction.categories {
            #expect(category.actions.contains { $0.identifier == HermNotificationAction.snooze })
        }
        #expect(HermNotificationAction.choice(for: HermNotificationAction.snooze) == nil)
    }
}
