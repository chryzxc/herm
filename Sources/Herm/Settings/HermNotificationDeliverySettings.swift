import AppKit
import SwiftUI
import UserNotifications

struct HermNotificationDeliverySettings: View {
    @AppStorage(HermNotificationPreferences.soundKey) private var sound = true
    @AppStorage(HermNotificationPreferences.snoozeKey) private var snoozeUntil = 0.0
    @State private var deliveryStatus = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPreferenceRow(
                title: "Notification sound", detail: "Use the macOS alert sound for desktop notifications."
            ) {
                Toggle("Notification sound", isOn: $sound).labelsHidden().toggleStyle(.switch)
            }
            Divider().overlay(Color.dockBorderLight)
            TimelineView(.everyMinute) { context in
                let snoozed = snoozeUntil > context.date.timeIntervalSince1970
                SettingsPreferenceRow(
                    title: "Snooze desktop alerts",
                    detail: snoozed
                        ? "Paused until \(Date(timeIntervalSince1970: snoozeUntil).formatted(date: .omitted, time: .shortened)). In-app attention stays visible."
                        : "Pause all desktop banners and sounds, including approvals and failures. Missed banners are not replayed."
                ) {
                    DockChipFlow(spacing: 6) {
                        ForEach([15, 30, 60], id: \.self) { minutes in
                            Button("\(minutes) min") {
                                snoozeUntil = Date().addingTimeInterval(Double(minutes) * 60).timeIntervalSince1970
                            }.buttonStyle(.dockSecondary)
                        }
                        if snoozed {
                            Button("Resume") { snoozeUntil = 0 }.buttonStyle(.dockPrimary)
                        }
                    }
                    .dockButtonSize(.compact)
                }
            }
            Divider().overlay(Color.dockBorderLight)
            HermNotificationToggle(
                title: "Approvals and questions", detail: "Notify when a session needs your approval or an answer.",
                key: HermNotificationPreferences.attentionKey, defaultValue: true)
            Divider().overlay(Color.dockBorderLight)
            HermNotificationToggle(
                title: "Session failures", detail: "Notify when a session reports an error.",
                key: HermNotificationPreferences.failureKey, defaultValue: true)
            Divider().overlay(Color.dockBorderLight)
            HermNotificationToggle(
                title: "Automation results", detail: "Notify when an observed scheduled run finishes or needs review.",
                key: HermNotificationPreferences.automationKey)
            Divider().overlay(Color.dockBorderLight)
            HermNotificationToggle(
                title: "Kanban updates", detail: "Notify about new running, blocked, or review card updates.",
                key: HermNotificationPreferences.kanbanKey)
            Divider().overlay(Color.dockBorderLight)
            HermNotificationToggle(
                title: "Quota warnings", detail: "Notify when a provider's remaining quota drops to a lower band.",
                key: HermNotificationPreferences.quotaKey)
            Divider().overlay(Color.dockBorderLight)
            HermNotificationToggle(
                title: "Watched pull requests", detail: "Notify when a watched pull request changes.",
                key: HermNotificationPreferences.pullRequestKey)
            Divider().overlay(Color.dockBorderLight)
            SettingsPreferenceRow(
                title: "macOS delivery",
                detail: deliveryStatus.isEmpty
                    ? "Banners and sounds also depend on macOS notification and Focus settings." : deliveryStatus
            ) {
                DockChipFlow(spacing: 6) {
                    Button("Send test alert") { Task { await sendTest() } }
                        .buttonStyle(.dockSecondary)
                    Button("System Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
                        {
                            NSWorkspace.shared.open(url)
                        }
                    }.buttonStyle(.dockSecondary)
                }
                .dockButtonSize(.compact)
            }
        }
    }

    @MainActor private func sendTest() async {
        guard HermesAppRuntime.supportsUserNotifications else {
            deliveryStatus = "Desktop notifications require a bundled Herm app."
            return
        }
        guard snoozeUntil <= Date().timeIntervalSince1970 else {
            deliveryStatus = "Resume desktop alerts before sending a test."
            return
        }
        do {
            let center = UNUserNotificationCenter.current()
            guard try await center.requestAuthorization(options: [.alert, .sound]) else {
                deliveryStatus = "Notifications are disabled for Herm. Enable them in System Settings."
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "Herm test notification"
            content.body = "Desktop alerts are enabled in Herm."
            content.sound = HermNotificationPreferences.sound(defaults: .standard)
            content.categoryIdentifier = HermNotificationAction.activityCategory
            try await center.add(
                UNNotificationRequest(identifier: "herm.notification-test", content: content, trigger: nil))
            deliveryStatus = "Test sent. If it stays silent, check macOS notification sound and Focus settings."
        } catch {
            deliveryStatus = HermesDiagnosticsService.safeSummary(error.localizedDescription)
        }
    }
}

private struct HermNotificationToggle: View {
    let title: String
    let detail: String
    @AppStorage private var enabled: Bool

    init(title: String, detail: String, key: String, defaultValue: Bool = false) {
        self.title = title
        self.detail = detail
        _enabled = AppStorage(wrappedValue: defaultValue, key)
    }

    var body: some View {
        SettingsPreferenceRow(title: title, detail: detail) {
            Toggle(title, isOn: $enabled).labelsHidden().toggleStyle(.switch)
        }
    }
}
