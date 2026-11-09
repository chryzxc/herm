import AppKit
import Combine
import Foundation
import QuartzCore

/// Records what the running app actually does while the user reproduces lag:
/// frame pacing from the display link, publications from every object the
/// workspace root observes, heavy view body evaluations, and `sample` stack
/// captures of the worst seconds. The report holds counts, timings and
/// symbolicated Herm/system stacks only; no prompt, path or response data.
@MainActor
final class HermPerformanceRecorder: NSObject, ObservableObject {
    static let shared = HermPerformanceRecorder()
    static let duration: TimeInterval = 30
    /// A second losing this share of its frames gets a stack capture.
    private static let stallCaptureRatio = 0.25
    private static let maxStackCaptures = 3

    @Published private(set) var isRecording = false
    @Published private(set) var lastReportURL: URL?

    /// Checked on every counted body evaluation; kept outside `@Published` so
    /// counting never invalidates the views being measured.
    private(set) static var active = false

    private var sources: [String: (name: String, publisher: AnyPublisher<Void, Never>)] = [:]
    private var subscriptions: [AnyCancellable] = []
    private var displayLink: CADisplayLink?
    private var directory: URL?
    private var startedAt: CFTimeInterval = 0
    private var lastFrame: CFTimeInterval = 0
    private var secondStart: CFTimeInterval = 0
    private var second = Counters()
    private var total = Counters()
    private var timeline: [String] = []
    private var stackCaptures: [String] = []
    private var isCapturingStack = false
    private var stopTask: Task<Void, Never>?

    private struct Counters {
        var frames = 0
        var droppedFrames = 0
        var lostTime: CFTimeInterval = 0
        var worstFrame: CFTimeInterval = 0
        var publications: [String: Int] = [:]
        var bodies: [String: Int] = [:]

        mutating func absorb(_ other: Counters) {
            frames += other.frames
            droppedFrames += other.droppedFrames
            lostTime += other.lostTime
            worstFrame = max(worstFrame, other.worstFrame)
            publications.merge(other.publications, uniquingKeysWith: +)
            bodies.merge(other.bodies, uniquingKeysWith: +)
        }
    }

    /// Registers an observable the workspace root redraws for. Subscribed only while recording.
    func watch<Object: ObservableObject>(_ name: String, _ object: Object) {
        watch(name, owner: object, object.objectWillChange)
    }

    func watch<P: Publisher>(_ name: String, owner: AnyObject, _ publisher: P) where P.Failure == Never {
        let key = "\(name)@\(ObjectIdentifier(owner).hashValue)"
        guard sources[key] == nil else { return }
        let erased = publisher.map { _ in () }.eraseToAnyPublisher()
        sources[key] = (name, erased)
        if isRecording { subscribe(name, erased) }
    }

    /// `let _ = HermPerformanceRecorder.countBody("Name")` at the top of a heavy body.
    static func countBody(_ name: String) {
        guard active else { return }
        shared.second.bodies[name, default: 0] += 1
    }

    func start() {
        guard !isRecording, let screen = NSScreen.main else { return }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Herm/Performance/\(stamp)", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil
        else { return }
        directory = folder
        second = Counters()
        total = Counters()
        timeline = []
        stackCaptures = []
        startedAt = CACurrentMediaTime()
        secondStart = startedAt
        lastFrame = 0
        for source in sources.values { subscribe(source.name, source.publisher) }
        let link = screen.displayLink(target: self, selector: #selector(frame(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        Self.active = true
        isRecording = true
        stopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.duration))
            self?.stop()
        }
    }

    func stop() {
        guard isRecording else { return }
        stopTask?.cancel()
        displayLink?.invalidate()
        displayLink = nil
        subscriptions = []
        Self.active = false
        isRecording = false
        closeSecond(at: CACurrentMediaTime())
        guard let directory else { return }
        let report = directory.appendingPathComponent("report.txt")
        try? renderReport().write(to: report, atomically: true, encoding: .utf8)
        lastReportURL = report
        NSWorkspace.shared.activateFileViewerSelecting([report])
    }

    private func subscribe(_ name: String, _ publisher: AnyPublisher<Void, Never>) {
        publisher.sink { [weak self] in
            MainActor.assumeIsolated { self?.second.publications[name, default: 0] += 1 }
        }
        .store(in: &subscriptions)
    }

    @objc private func frame(_ link: CADisplayLink) {
        let now = link.timestamp
        let expected = max(link.targetTimestamp - link.timestamp, 1.0 / 240)
        if lastFrame > 0 {
            let delta = now - lastFrame
            second.frames += 1
            second.worstFrame = max(second.worstFrame, delta)
            let dropped = Self.droppedFrames(delta: delta, expected: expected)
            if dropped > 0 {
                second.droppedFrames += dropped
                second.lostTime += delta - expected
            }
        }
        lastFrame = now
        if now - secondStart >= 1 { closeSecond(at: now) }
    }

    /// Frames missed between two display-link callbacks; jitter under half a frame is not a drop.
    nonisolated static func droppedFrames(delta: CFTimeInterval, expected: CFTimeInterval) -> Int {
        max(0, Int((delta / expected).rounded()) - 1)
    }

    private func closeSecond(at now: CFTimeInterval) {
        let elapsed = now - secondStart
        guard elapsed > 0 else { return }
        let lostRatio = second.lostTime / elapsed
        let t = Int((secondStart - startedAt).rounded())
        timeline.append(
            String(
                format: "t=%3ds%@ fps=%3d dropped=%3d lost=%4.0fms worst=%4.0fms  pubs: %@  bodies: %@",
                t, isCapturingStack ? "*" : " ", second.frames, second.droppedFrames, second.lostTime * 1000,
                second.worstFrame * 1000,
                Self.ranked(second.publications, limit: 5), Self.ranked(second.bodies, limit: 4)))
        if lostRatio >= Self.stallCaptureRatio { captureStack(label: "t\(t)s") }
        total.absorb(second)
        second = Counters()
        secondStart = now
    }

    /// The lag reported so far is sustained, so sampling right after a bad
    /// second still lands inside it. `sample` is the same tool used by hand.
    private func captureStack(label: String) {
        guard !isCapturingStack, stackCaptures.count < Self.maxStackCaptures, let directory else { return }
        let file = directory.appendingPathComponent("stack-\(label).txt")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        // 10ms rather than the 1ms default: each sample suspends Herm, so a dense capture causes the stalls it records.
        process.arguments = ["\(ProcessInfo.processInfo.processIdentifier)", "3", "10", "-mayDie", "-file", file.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in
            Task { @MainActor in HermPerformanceRecorder.shared.isCapturingStack = false }
        }
        guard (try? process.run()) != nil else { return }
        isCapturingStack = true
        stackCaptures.append(file.lastPathComponent)
    }

    private func renderReport() -> String {
        let seconds = max(CACurrentMediaTime() - startedAt, 1)
        let build = Bundle.main.bundleURL.path.contains("/Debug/") ? "Debug" : "Release"
        return """
            Herm performance capture
            build: \(build)   duration: \(Int(seconds))s   display: \(NSScreen.main?.maximumFramesPerSecond ?? 0) Hz
            frames: \(total.frames)   dropped: \(total.droppedFrames)   lost: \(Int(total.lostTime * 1000))ms \
            (\(Int(total.lostTime / seconds * 100))% of wall time)   worst frame: \(Int(total.worstFrame * 1000))ms

            Publications (objectWillChange; each one re-renders the workspace root):
            \(Self.ranked(total.publications, limit: 40, separator: "\n"))

            Body evaluations:
            \(Self.ranked(total.bodies, limit: 40, separator: "\n"))

            Stack captures (seconds losing ≥\(Int(Self.stallCaptureRatio * 100))% of frames):
            \(stackCaptures.isEmpty ? "none" : stackCaptures.joined(separator: "\n"))

            Per second (* = a stack capture was running and may inflate that second):
            \(timeline.joined(separator: "\n"))

            """
    }

    private static func ranked(_ counts: [String: Int], limit: Int, separator: String = " ") -> String {
        let rows = counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(limit)
        return rows.isEmpty ? "-" : rows.map { "\($0.key)=\($0.value)" }.joined(separator: separator)
    }
}

extension DockPopover {
    /// Everything the root observes; a publication from any of these redraws the workspace.
    func registerPerformanceSources() {
        let recorder = HermPerformanceRecorder.shared
        recorder.watch("DockModel", model)
        recorder.watch("DockModel→root", owner: model, model.workspacePresentationChanges)
        for source in model.workspacePresentationSources() {
            recorder.watch("DockModel→root.\(source.name)", owner: model, source.publisher)
        }
        recorder.watch("ControlCenterModel→root", owner: controlCenter, controlCenter.workspacePresentationChanges)
        recorder.watch("ControlCenterModel", controlCenter)
        recorder.watch("panelPresentation", panelPresentation)
        recorder.watch("expandedReviewRouter", expandedReviewRouter)
        recorder.watch("hostPresentation", hostPresentation)
        recorder.watch("sidebarSessionSeenStore", sidebarSessionSeenStore)
        recorder.watch("filePreview", filePreview)
        recorder.watch("speechInput", speechInput)
        recorder.watch("voiceOutput", voiceOutput)
        recorder.watch("micLevelMeter", micLevelMeter)
        recorder.watch("messageActionState", messageActionState)
        recorder.watch("workspaceStore", workspaceStore)
        recorder.watch("agentUpdateService", agentUpdateService)
        recorder.watch("developerWorkflow", developerWorkflow)
        recorder.watch("pullRequestCenter", pullRequestCenter)
        recorder.watch("issueCenter", issueCenter)
        recorder.watch("gitHubInspector", gitHubInspector)
        recorder.watch("pullRequestChatLinks", pullRequestChatLinks)
        recorder.watch("repositoryPreferences", repositoryPreferences)
        recorder.watch("dockThemeStore", dockThemeStore)
        recorder.watch("botMode", botMode)
        recorder.watch("sessionNavNavigation", sessionNavNavigation)
        recorder.watch("sessionPullRequestCenter", sessionPullRequestCenter)
        recorder.watch("sessionIssueCenter", sessionIssueCenter)
    }
}
