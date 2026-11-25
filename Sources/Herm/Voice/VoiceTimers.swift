import AppKit
import Combine
import SwiftUI
import UserNotifications

/// A one-shot Hermes cron job shown as a countdown. Hermes never delivers a TUI
/// session's job back to it, so Herm raises the alert itself at `due`.
struct VoiceTimer: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let due: Date
    var isDue = false
    var canCancel = false

    func countdown(at now: Date) -> ClosedRange<Date>? {
        guard !isDue, now < due else { return nil }
        return now...due
    }
}

/// The upcoming one-shot reminders from Hermes' cron list, with one wake-up scheduled
/// for the soonest change. Nothing polls; a `cron.changed` refresh reschedules it.
@MainActor
final class VoiceTimerBoard: ObservableObject {
    /// How far ahead a reminder shows as a timer, and how long "Due" stays up.
    static let horizon: TimeInterval = 24 * 60 * 60
    static let dueHold: TimeInterval = 60
    /// How close a reminder must be to count down in the closed notch.
    static let countdownWindow: TimeInterval = 60 * 60

    @Published private(set) var timers: [VoiceTimer] = []
    /// The soonest reminder within `countdownWindow` that isn't due yet.
    @Published private(set) var soonest: VoiceTimer?
    /// Runs once per timer, when it comes due.
    var onDue: ((VoiceTimer) -> Void)?
    /// Deletes the timer's Hermes job.
    var onCancel: ((VoiceTimer) -> Void)?

    private let now: () -> Date
    private var jobs: [CronSummary] = []
    /// Fired timers stay as "Due" for a minute after Hermes drops the finished job.
    private var held: [VoiceTimer] = []
    private var fired = Set<String>()
    private var wake: Task<Void, Never>?
    private var source: AnyCancellable?

    init(now: @escaping () -> Date = Date.init) { self.now = now }

    func observeWake() {
        source = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
    }

    func applyConfirmedJobs(_ jobs: [CronSummary], profileID: String?) {
        update(jobs)
        guard HermesAppRuntime.supportsUserNotifications else { return }
        let timers = jobs.compactMap(Self.projectTimer)
        VoiceTimerNotifications.shared.reconcile(timers, profileID: profileID)
    }

    /// Stops following a Control Center that moved to another model.
    func detach() {
        source = nil
        onDue = nil
        onCancel = nil
        update([])
    }

    func update(_ jobs: [CronSummary]) {
        self.jobs = jobs
        refresh()
    }

    func cancel(_ timer: VoiceTimer) {
        guard timer.canCancel, !timer.isDue, timers.contains(timer), timer.due > now() else { return }
        onCancel?(timer)
    }

    /// Enabled one-shot jobs with a timestamp from a minute ago to a day ahead, soonest first.
    /// A `nextRun` Hermes did not report as a timestamp is dropped rather than guessed.
    static func upcoming(_ jobs: [CronSummary], now: Date) -> [VoiceTimer] {
        jobs.compactMap(projectTimer)
            .filter { $0.due > now.addingTimeInterval(-dueHold) && $0.due <= now.addingTimeInterval(horizon) }
            .map { timer in
                var timer = timer
                timer.isDue = timer.due <= now
                return timer
            }
            .sorted { ($0.due, $0.id) < ($1.due, $1.id) }
    }

    static func projectTimer(_ job: CronSummary) -> VoiceTimer? {
        guard job.enabled, job.schedule.lowercased().hasPrefix("once"),
            let due = job.nextRun.flatMap(HumanDateFormatting.date)
        else { return nil }
        return VoiceTimer(id: job.id, name: job.name, due: due, canCancel: AssistantTimers.owns(job))
    }

    private func refresh() {
        let now = now()
        let listed = Self.upcoming(jobs, now: now)
        let confirmed = jobs.compactMap(Self.projectTimer)
        // A late refresh still delivers a known timer after sleep. The short "Due now" display
        // window only controls the UI.
        for timer in timers
        where !timer.isDue && timer.due <= now.addingTimeInterval(-Self.dueHold)
            && confirmed.contains(where: { Self.key($0) == Self.key(timer) })
            && fired.insert(Self.key(timer)).inserted
        {
            var due = timer
            due.isDue = true
            onDue?(due)
        }
        held = held.filter { $0.due > now.addingTimeInterval(-Self.dueHold) }
        let next = (listed + held.filter { timer in !listed.contains { $0.id == timer.id } })
            .sorted { ($0.due, $0.id) < ($1.due, $1.id) }
        for timer in next where timer.isDue && fired.insert(Self.key(timer)).inserted {
            held.append(timer)
            onDue?(timer)
        }
        if next != timers { timers = next }
        let counting = next.first { !$0.isDue && $0.due.timeIntervalSince(now) <= Self.countdownWindow }
        if counting != soonest { soonest = counting }
        scheduleWake(now: now)
    }

    /// The next moment anything changes: a timer comes due, its "Due" ends, or it
    /// enters the closed notch's countdown window.
    private func scheduleWake(now: Date) {
        wake?.cancel()
        let moments = timers.flatMap { timer -> [Date] in
            if timer.isDue { return [timer.due.addingTimeInterval(Self.dueHold)] }
            let entersCountdown = timer.due.addingTimeInterval(-Self.countdownWindow)
            return entersCountdown > now ? [entersCountdown, timer.due] : [timer.due]
        }
        guard let soonest = moments.min() else { return }
        let delay = max(0.05, soonest.timeIntervalSince(now))
        wake = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    private static func key(_ timer: VoiceTimer) -> String {
        "\(timer.id)@\(Int(timer.due.timeIntervalSince1970))"
    }
}

/// The closed notch's countdown to the soonest reminder within the hour.
struct VoiceTimerCountdown: View {
    let timer: VoiceTimer

    var body: some View {
        HStack(spacing: 3) {
            DockIcon(.timer, size: 11)
                .foregroundStyle(Color.dockSecondaryText)
            Group {
                if let interval = timer.countdown(at: .now) {
                    Text(timerInterval: interval, countsDown: true)
                } else {
                    Text("Due now")
                }
            }
            .dockFont(size: 11, weight: .medium)
            .monospacedDigit()
            .foregroundStyle(Color.dockPrimaryText)
            .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Reminder: \(timer.name)")
        .help("Reminder: \(timer.name)")
    }
}
