import Foundation

/// The job remains owned by Hermes. The bundled no-op exits silently and never calls an agent.
@MainActor
final class AssistantTimers {
    nonisolated static let scriptName = "herm-voice-timer-v1.sh"
    private static let script = Data("#!/bin/sh\nexit 0\n".utf8)
    private var recent: [String: String] = [:]

    private enum Operation {
        case check
        case extend(Int)
        case cancel
    }

    func perform(_ intent: AssistantIntent, on control: ControlCenterModel) async throws -> AssistantReply {
        guard let rpc = control.rpc, control.dockModel?.isHermesConnected == true else {
            return AssistantReply("Timers need a connected Hermes runtime.")
        }
        let profile = control.routineProfileID ?? "default"
        let jobs = try await rpc.workflow(profileID: profile).routineJobs()
        try Task.checkCancellation()
        let timers = jobs.compactMap { job in Self.due(job).map { (job, $0) } }.sorted { $0.1 < $1.1 }
        switch intent {
        case .timerCreate(let name, let seconds):
            guard GatewayConnectionStore.isLocalBackend, Self.installScript(profile: profile) else {
                return AssistantReply("Timer creation needs a local Hermes profile with a writable scripts folder.")
            }
            let label = String((name ?? "Timer").prefix(100))
            let due = Date(timeIntervalSince1970: floor(Date.now.timeIntervalSince1970) + Double(seconds))
            do {
                try Task.checkCancellation()
                let job = try await rpc.createAssistantTimer(
                    name: label, schedule: Self.schedule(due), profileID: profile)
                guard Self.due(job) == due else { return AssistantReply(Self.unknown) }
                recent[profile] = job.id
                let alert = await refresh(control, rpc: rpc, profile: profile, expecting: job)
                return AssistantReply("Set \(job.name) for \(HumanDateFormatting.timeOnly(due))." + alert)
            } catch {
                return AssistantReply(Self.unknown)
            }
        case .timers:
            guard !timers.isEmpty else { return AssistantReply("There are no running voice timers in \(profile).") }
            let lines = timers.prefix(5).map { "\($0.0.name) at \(HumanDateFormatting.timeOnly($0.1))" }
            let more = timers.count > 5 ? " \(timers.count - 5) more." : ""
            return AssistantReply(lines.joined(separator: ". ") + "." + more)
        case .timerRemaining(let name):
            return select(name, from: timers, profile: profile, operation: .check, control: control, rpc: rpc)
        case .timerExtend(let name, let seconds):
            return select(name, from: timers, profile: profile, operation: .extend(seconds), control: control, rpc: rpc)
        case .timerCancel(let name):
            return select(name, from: timers, profile: profile, operation: .cancel, control: control, rpc: rpc)
        default: return AssistantReply("Which timer?")
        }
    }

    private func select(
        _ name: String?, from timers: [(CronSummary, Date)], profile: String,
        operation: Operation, control: ControlCenterModel, rpc: HermesControlRPC
    ) -> AssistantReply {
        let generic = name.map { ["timer", "it", "that", "my timer"].contains(AssistantIntent.normalized($0)) } ?? true
        let matches =
            generic
            ? timers
            : timers.filter {
                AssistantIntent.normalized($0.0.name) == AssistantIntent.normalized(name ?? "")
            }
        if let only = matches.first, matches.count == 1 {
            return respond(only, profile: profile, operation: operation, control: control, rpc: rpc)
        }
        if generic, let last = matches.first(where: { $0.0.id == recent[profile] }) {
            return respond(last, profile: profile, operation: operation, control: control, rpc: rpc)
        }
        guard !matches.isEmpty else {
            return AssistantReply(
                name.map { "I couldn't find a running timer named \($0)." } ?? "No voice timers are running.")
        }
        return .choose(
            "Which timer?", choices: matches.map { ("\($0.0.name) at \(HumanDateFormatting.timeOnly($0.1))", $0) }
        ) { [weak self, weak control] selected in
            guard let self, let control else { return AssistantReply("Timers are unavailable.") }
            return respond(selected, profile: profile, operation: operation, control: control, rpc: rpc)
        }
    }

    private func respond(
        _ selection: (CronSummary, Date), profile: String, operation: Operation,
        control: ControlCenterModel, rpc: HermesControlRPC
    ) -> AssistantReply {
        let (job, deadline) = selection
        recent[profile] = job.id
        let time = HumanDateFormatting.timeOnly(deadline)
        let extended: Date?
        let question: String
        switch operation {
        case .check:
            let remaining = max(1, Int(ceil(deadline.timeIntervalSinceNow)))
            let duration =
                remaining >= 60
                ? "\(remaining / 60) minutes and \(remaining % 60) seconds" : "\(remaining) seconds"
            return AssistantReply("\(job.name) has \(duration) left, until \(time).")
        case .extend(let seconds):
            let newDeadline = deadline.addingTimeInterval(Double(seconds))
            extended = newDeadline
            question = "Extend \(job.name) from \(time) to \(HumanDateFormatting.timeOnly(newDeadline))?"
        case .cancel:
            extended = nil
            question = "Cancel \(job.name) due at \(time)?"
        }
        return .confirm(question) { [weak self, weak control] in
            guard let self, let control, control.rpc === rpc else { return "The timer connection changed." }
            let current = try await rpc.cronJob(job, profileID: profile)
            guard Self.due(current) == deadline else { return "That timer changed. Ask again for its current state." }
            try Task.checkCancellation()
            do {
                if let extended {
                    var draft = CronEditDraft(job: current)
                    draft.schedule = Self.schedule(extended)
                    try await rpc.updateCron(current, draft: draft, profileID: profile)
                    let changed = try await rpc.cronJob(current, profileID: profile)
                    guard Self.due(changed) == extended else { return Self.unknown }
                    let alert = await refresh(control, rpc: rpc, profile: profile, expecting: changed)
                    return "Extended \(job.name) to \(HumanDateFormatting.timeOnly(extended))." + alert
                }
                _ = try await rpc.removeCron(jobID: job.id, profileID: profile)
                let alert = await refresh(control, rpc: rpc, profile: profile, removing: job.id)
                return "Cancelled \(job.name)." + alert
            } catch {
                return Self.unknown
            }
        }
    }

    private func refresh(
        _ control: ControlCenterModel, rpc: HermesControlRPC, profile: String,
        expecting job: CronSummary? = nil, removing removedID: String? = nil
    ) async -> String {
        guard let jobs = try? await rpc.workflow(profileID: profile).routineJobs(), control.rpc === rpc,
            job.map({ expected in jobs.contains { $0.id == expected.id && Self.due($0) == Self.due(expected) } })
                != false,
            removedID.map({ id in !jobs.contains { $0.id == id } }) != false
        else { return " I couldn't refresh the Mac alerts. Check the timers in Herm." }
        if (control.routineProfileID ?? "default") == profile {
            control.dockModel?.voiceTimers.update(jobs)
            control.refresh()
        }
        guard HermesAppRuntime.supportsUserNotifications else { return " Mac alerts are unavailable in this build." }
        let scheduled = await VoiceTimerNotifications.shared.apply(
            jobs.compactMap(VoiceTimerBoard.projectTimer), profileID: profile)
        return scheduled ? "" : " I couldn't verify the Mac alert. Check notification settings."
    }

    static func owns(_ job: CronSummary) -> Bool {
        job.details.noAgent == true && job.details.script == scriptName
    }

    static func due(_ job: CronSummary, now: Date = .now) -> Date? {
        guard owns(job),
            let due = VoiceTimerBoard.projectTimer(job)?.due, due > now
        else { return nil }
        return due
    }

    private static let unknown = "I couldn't verify the timer change. Say “list my timers” to check its state."

    private static func schedule(_ date: Date) -> String { date.ISO8601Format() }

    private static func installScript(profile: String) -> Bool {
        guard profile.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else { return false }
        let home = HermesDesktopPluginCatalog.defaultHome().standardizedFileURL
        let root = profile == "default" ? home : home.appendingPathComponent("profiles/\(profile)", isDirectory: true)
        let scripts = root.appendingPathComponent("scripts", isDirectory: true)
        let target = scripts.appendingPathComponent(scriptName)
        let fm = FileManager.default
        guard root.resolvingSymlinksInPath().path == root.path,
            scripts.resolvingSymlinksInPath().path == scripts.path,
            target.resolvingSymlinksInPath().path == target.path,
            (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        else { return false }
        do {
            try fm.createDirectory(at: scripts, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: target.path) { try script.write(to: target, options: .withoutOverwriting) }
            let properties = try target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard properties.isRegularFile == true, properties.isSymbolicLink != true,
                properties.fileSize == script.count, try Data(contentsOf: target) == script
            else { return false }
            if !fm.isExecutableFile(atPath: target.path) {
                try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
            }
            return true
        } catch {
            return false
        }
    }
}
