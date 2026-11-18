import AppKit
import Combine
import Foundation
import IOKit.ps
import MachO
import OSLog
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
    @Published var includeStackSamples = false
    @Published private(set) var isFinalizing = false
    @Published private(set) var error: String?

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
    private var captureID = UUID()
    private var sampler: Process?
    private var endedAt: CFTimeInterval = 0
    private var lastArrival: CFTimeInterval = 0
    private var gaps: [Double] = []
    private var expectedIntervals: [Int: Int] = [:]
    private var environment: [String] = []
    private var secondWasSampled = false
    private var stopTask: Task<Void, Never>?
    private var sessionOpens: [String] = []
    private var origins = PublicationOrigins()
    /// Running-session count sampled once per second; set by the workspace root.
    var runningSessionCount: (() -> Int)?

    /// Instruments "Points of Interest" lane for the same work the report measures.
    nonisolated static let signposter = OSSignposter(subsystem: "io.github.chryzxc.Herm", category: .pointsOfInterest)
    /// Broad observables whose publications are attributed to the Herm code that caused them.
    private static let attributedSources: Set<String> = [
        "DockModel", "ControlCenterModel", "botMode", "sessionNavNavigation", "workspaceStore",
    ]

    private struct Counters {
        var frames = 0
        var droppedFrames = 0
        var lostTime: CFTimeInterval = 0
        var worstFrame: CFTimeInterval = 0
        var publications: [String: Int] = [:]
        var bodies: [String: Int] = [:]
        var workMilliseconds: [String: Double] = [:]
        /// Scenario context: gateway events per session class, scroll events, transcript pages.
        var marks: [String: Int] = [:]
        var runningSessions = 0

        mutating func absorb(_ other: Counters) {
            marks.merge(other.marks, uniquingKeysWith: +)
            runningSessions = max(runningSessions, other.runningSessions)
            frames += other.frames
            droppedFrames += other.droppedFrames
            lostTime += other.lostTime
            worstFrame = max(worstFrame, other.worstFrame)
            publications.merge(other.publications, uniquingKeysWith: +)
            bodies.merge(other.bodies, uniquingKeysWith: +)
            workMilliseconds.merge(other.workMilliseconds, uniquingKeysWith: +)
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

    static func recordWork(_ name: String, since start: CFTimeInterval) {
        guard active else { return }
        shared.second.bodies[name, default: 0] += 1
        shared.second.workMilliseconds[name, default: 0] += (CACurrentMediaTime() - start) * 1000
    }

    /// Counts a scenario event (for example a background-session gateway event) in the current second.
    static func mark(_ name: String, count: Int = 1) {
        guard active else { return }
        shared.second.marks[name, default: 0] += count
    }

    /// Measures `body` as named work while recording and always emits an
    /// Instruments signpost interval, so Time Profiler and the report agree.
    @discardableResult
    static func measure<T>(_ signpost: StaticString, as metric: @autoclosure () -> String, _ body: () throws -> T)
        rethrows -> T
    {
        let state = signposter.beginInterval(signpost)
        let start = active ? CACurrentMediaTime() : 0
        defer {
            signposter.endInterval(signpost, state)
            if start > 0 { recordWork(metric(), since: start) }
        }
        return try body()
    }

    /// Session-open stages (resume, parse, history_project, cached/fresh layout) for the report.
    static func recordSessionOpen(stage: String, milliseconds: Double) {
        signposter.emitEvent("session_open")
        guard active else { return }
        let recorder = shared
        recorder.second.marks["session_open.\(stage)", default: 0] += 1
        recorder.sessionOpens.append(
            String(
                format: "t=%6.2fs %@ %.1fms", CACurrentMediaTime() - recorder.startedAt, stage, milliseconds))
    }

    func start() {
        guard !isRecording, !isFinalizing, let screen = NSScreen.main else { return }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Herm/Performance/\(stamp)", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil
        else { return }
        directory = folder
        error = nil
        gaps = []
        expectedIntervals = [:]
        environment = []
        endedAt = 0
        lastArrival = 0
        secondWasSampled = false
        second = Counters()
        total = Counters()
        timeline = []
        stackCaptures = []
        sessionOpens = []
        origins = PublicationOrigins()
        captureID = UUID()
        isCapturingStack = false
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
            do { try await Task.sleep(for: .seconds(Self.duration)) } catch { return }
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
        endedAt = CACurrentMediaTime()
        closeSecond(at: endedAt)
        if let sampler {
            isFinalizing = true
            if sampler.isRunning { sampler.terminate() }
            return
        }
        saveReport()
    }

    private func saveReport() {
        guard let directory else {
            isFinalizing = false
            return
        }
        isFinalizing = true
        let addresses = origins.addresses
        let id = captureID
        Task.detached(priority: .utility) {
            let symbols = PublicationOrigins.symbolicate(addresses)
            await MainActor.run {
                let recorder = HermPerformanceRecorder.shared
                guard recorder.captureID == id else { return }
                recorder.writeReport(to: directory, symbols: symbols)
            }
        }
    }

    private func writeReport(to directory: URL, symbols: [UInt: String]) {
        isFinalizing = false
        let report = directory.appendingPathComponent("report.txt")
        do { try renderReport(symbols: symbols).write(to: report, atomically: true, encoding: .utf8) } catch {
            self.error = "Performance report could not be saved."
            return
        }
        lastReportURL = report
        NSWorkspace.shared.activateFileViewerSelecting([report])
    }

    private func subscribe(_ name: String, _ publisher: AnyPublisher<Void, Never>) {
        let attributes = Self.attributedSources.contains(name)
        publisher.sink { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.second.publications[name, default: 0] += 1
                if attributes { self.origins.record(name, stack: Thread.callStackReturnAddresses.map(\.uintValue)) }
            }
        }
        .store(in: &subscriptions)
    }

    @objc private func frame(_ link: CADisplayLink) {
        let arrival = CACurrentMediaTime()
        if lastArrival > 0 { gaps.append(arrival - lastArrival) }
        lastArrival = arrival
        let now = link.timestamp
        let expected = max(link.targetTimestamp - link.timestamp, 1.0 / 240)
        expectedIntervals[Int((expected * 1_000_000).rounded()), default: 0] += 1
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
        let power: String
        if let info = IOPSCopyPowerSourcesInfo() {
            power = IOPSGetProvidingPowerSourceType(info.takeRetainedValue()).takeUnretainedValue() as String
        } else {
            power = "unavailable"
        }
        let state =
            "power=\(power) low_power=\(ProcessInfo.processInfo.isLowPowerModeEnabled) thermal=\(ProcessInfo.processInfo.thermalState.rawValue)"
        if environment.last?.hasSuffix(state) != true {
            environment.append(String(format: "t=%.2fs %@", now - startedAt, state))
        }
        let elapsed = now - secondStart
        guard elapsed > 0 else { return }
        second.runningSessions = runningSessionCount?() ?? 0
        let lostRatio = second.lostTime / elapsed
        let t = Int((secondStart - startedAt).rounded())
        timeline.append(
            String(
                format:
                    "t=%3ds%@ callbacks=%3d dropped=%3d lost=%4.0fms worst=%4.0fms running=%d  ctx: %@  pubs: %@  bodies: %@  work: %@",
                t, secondWasSampled ? "*" : " ", second.frames, second.droppedFrames, second.lostTime * 1000,
                second.worstFrame * 1000, second.runningSessions,
                Self.ranked(second.marks, limit: 6), Self.ranked(second.publications, limit: 5),
                Self.ranked(second.bodies, limit: 4), Self.rankedWork(second.workMilliseconds, limit: 4)))
        if isRecording && includeStackSamples && lostRatio >= Self.stallCaptureRatio { captureStack(label: "t\(t)s") }
        total.absorb(second)
        second = Counters()
        secondWasSampled = isCapturingStack
        secondStart = now
    }

    /// The lag reported so far is sustained, so sampling right after a bad
    /// second still lands inside it. `sample` is the same tool used by hand.
    private func captureStack(label: String) {
        guard isRecording, includeStackSamples, !isCapturingStack, stackCaptures.count < Self.maxStackCaptures,
            let directory
        else { return }
        let file = directory.appendingPathComponent("stack-\(label).txt")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        // 10ms rather than the 1ms default: each sample suspends Herm, so a dense capture causes the stalls it records.
        process.arguments = ["\(ProcessInfo.processInfo.processIdentifier)", "3", "10", "-mayDie", "-file", file.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let id = captureID
        process.terminationHandler = { terminated in
            let status = terminated.terminationStatus
            Task { @MainActor in
                let recorder = HermPerformanceRecorder.shared
                guard recorder.captureID == id else { return }
                if let index = recorder.stackCaptures.firstIndex(of: file.lastPathComponent) {
                    recorder.stackCaptures[index] = Self.stackCaptureResult(
                        name: file.lastPathComponent, status: status,
                        hasFile: FileManager.default.fileExists(atPath: file.path))
                }
                recorder.isCapturingStack = false
                recorder.sampler = nil
                if recorder.isFinalizing { recorder.saveReport() }
            }
        }
        do { try process.run() } catch {
            stackCaptures.append("Stack sample unavailable")
            return
        }
        sampler = process
        isCapturingStack = true
        secondWasSampled = true
        stackCaptures.append(file.lastPathComponent)
    }

    nonisolated static func stackCaptureResult(name: String, status: Int32, hasFile: Bool) -> String {
        status == 0 && hasFile ? name : "Stack sample unavailable"
    }

    private func renderReport(symbols: [UInt: String]) -> String {
        let seconds = max(endedAt - startedAt, 0.001)
        let build = HermBuildInfo.current
        return """
            Herm performance capture
            build: \(build.channel.rawValue) \(build.commit ?? "unavailable")   duration: \(Int(seconds))s   display maximum: \(NSScreen.main?.maximumFramesPerSecond ?? 0) Hz
            callbacks: \(total.frames)   estimated dropped: \(total.droppedFrames)   estimated lost: \(Int(total.lostTime * 1000))ms \
            (\(Int(total.lostTime / seconds * 100))% of wall time)   worst frame: \(Int(total.worstFrame * 1000))ms

            Observed publications (→root names identify scoped workspace subscriptions; other names are broad observables):
            \(Self.ranked(total.publications, limit: 40, separator: "\n"))

            Callback arrival gaps: \(Self.gapSummary(gaps))
            Observed callback rate: \(String(format: "%.1f", Double(total.frames) / seconds))/s
            Expected intervals (microseconds: callbacks): \(expectedIntervals.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: " "))
            Power context:
            \(environment.joined(separator: "\n"))

            Measured UI work (total milliseconds; overlapping work may be counted):
            \(Self.rankedWork(total.workMilliseconds, limit: 60, separator: "\n"))

            Scenario context (running sessions peak: \(total.runningSessions); events.background = other sessions' gateway events handled on the main thread):
            \(Self.ranked(total.marks, limit: 40, separator: "\n"))

            Session opens (stage, milliseconds since the switch started):
            \(sessionOpens.isEmpty ? "none" : sessionOpens.joined(separator: "\n"))

            Publication origins (Herm frames that caused broad publications; first frame is usually the property setter):
            \(origins.render(symbols: symbols))

            Body evaluations:
            \(Self.ranked(total.bodies, limit: 40, separator: "\n"))

            Stack captures (seconds losing ≥\(Int(Self.stallCaptureRatio * 100))% of frames):
            \(stackCaptures.isEmpty ? "none" : stackCaptures.joined(separator: "\n"))

            Per second (* = a stack capture was running and may inflate that second):
            \(timeline.joined(separator: "\n"))

            """
    }

    nonisolated static func gapSummary(_ gaps: [Double]) -> String {
        let sorted = gaps.sorted()
        guard !sorted.isEmpty else { return "unavailable" }
        func percentile(_ fraction: Double) -> Double {
            sorted[min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * fraction)) - 1))] * 1000
        }
        return String(
            format: "p50=%.1fms p95=%.1fms p99=%.1fms max=%.1fms >50ms=%d >100ms=%d",
            percentile(0.5), percentile(0.95), percentile(0.99), percentile(1),
            gaps.filter { $0 > 0.05 }.count, gaps.filter { $0 > 0.1 }.count)
    }

    nonisolated static func rankedWork(_ work: [String: Double], limit: Int, separator: String = " ") -> String {
        let rows = work.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(limit)
        return rows.isEmpty
            ? "-" : rows.map { "\($0.key)=\(String(format: "%.1f", $0.value))ms" }.joined(separator: separator)
    }

    nonisolated static func ranked(_ counts: [String: Int], limit: Int, separator: String = " ") -> String {
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
        recorder.watch("developerWorkflow→root", owner: developerWorkflow, developerWorkflow.rootPresentationChanges)
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
        recorder.runningSessionCount = { [weak model] in
            model?.sessions.reduce(0) { $0 + ($1.isWorking ? 1 : 0) } ?? 0
        }
    }
}

/// Aggregates which Herm call sites made a broad observable publish. The stack
/// is cut after the last Combine frame, so the first kept frame is the
/// `@Published` setter (or `objectWillChange.send()` caller) and the rest are
/// its callers. Addresses only; symbolicated with `atos` when the report is saved.
struct PublicationOrigins {
    static let maxSamples = 6000
    static let framesKept = 4
    private(set) var stacks: [String: [[UInt]: Int]] = [:]
    private(set) var samples = 0
    private var imageCache: [UInt: Image] = [:]

    enum Image { case herm, combine, other }

    mutating func record(_ name: String, stack: [UInt]) {
        guard samples < Self.maxSamples else { return }
        samples += 1
        let images = stack.prefix(48).map { address in
            if let cached = imageCache[address] { return cached }
            let image = Self.image(of: address)
            imageCache[address] = image
            return image
        }
        let key = Self.originFrames(stack: Array(stack.prefix(48)), images: images)
        stacks[name, default: [:]][key, default: 0] += 1
    }

    /// Herm frames after the last Combine frame; pure so it can be tested.
    static func originFrames(stack: [UInt], images: [Image]) -> [UInt] {
        let count = min(stack.count, images.count)
        let start = (images[..<count].lastIndex(of: .combine)).map { $0 + 1 } ?? 0
        return Array((start..<count).filter { images[$0] == .herm }.map { stack[$0] }.prefix(framesKept))
    }

    var addresses: [UInt] {
        Array(Set(stacks.values.flatMap { $0.keys.flatMap { $0 } }))
    }

    func render(symbols: [UInt: String], limit: Int = 12) -> String {
        guard !stacks.isEmpty else { return "none" }
        var lines: [String] = []
        for (name, counts) in stacks.sorted(by: { $0.key < $1.key }) {
            let total = counts.values.reduce(0, +)
            lines.append("\(name) (\(total) sampled):")
            let ranked = counts.sorted { $0.value == $1.value ? $0.key.count < $1.key.count : $0.value > $1.value }
            for (frames, count) in ranked.prefix(limit) {
                let names =
                    frames.isEmpty ? ["(no Herm frame)"] : frames.map { symbols[$0] ?? String(format: "0x%lx", $0) }
                lines.append("  \(count)× " + names.joined(separator: " ← "))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Load address of the Herm executable (image 0).
    private static let mainHeader: UInt? = _dyld_get_image_header(0).map { UInt(bitPattern: UnsafeRawPointer($0)) }

    private static func image(of address: UInt) -> Image {
        var info = Dl_info()
        guard let pointer = UnsafeRawPointer(bitPattern: address), dladdr(pointer, &info) != 0 else { return .other }
        if let base = info.dli_fbase, UInt(bitPattern: base) == mainHeader { return .herm }
        if let file = info.dli_fname, String(cString: file).hasSuffix("/Combine") { return .combine }
        return .other
    }

    /// Runs `atos` against the Herm executable; unresolved addresses stay raw in the report.
    nonisolated static func symbolicate(_ addresses: [UInt]) -> [UInt: String] {
        guard !addresses.isEmpty, let header = mainHeader, let executable = Bundle.main.executablePath else {
            return [:]
        }
        let sorted = addresses.sorted()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/atos")
        process.arguments =
            ["-o", executable, "-l", String(format: "0x%lx", header)]
            + sorted.map { String(format: "0x%lx", $0) }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [:] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { return [:] }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var symbols: [UInt: String] = [:]
        for (address, line) in zip(sorted, lines) where !line.hasPrefix("0x") {
            symbols[address] = shortSymbol(String(line))
        }
        return symbols
    }

    /// `foo(bar:) (in Herm) (File.swift:12)` → `foo(bar:) File.swift:12`.
    nonisolated static func shortSymbol(_ line: String) -> String {
        var text = line.replacingOccurrences(of: " (in Herm)", with: "")
        if let open = text.lastIndex(of: "("), text.hasSuffix(")"), text[open...].contains(".swift:") {
            let location = text[text.index(after: open)..<text.index(before: text.endIndex)]
            text = text[..<open].trimmingCharacters(in: .whitespaces) + " " + location
        }
        return text.count > 160 ? String(text.prefix(157)) + "…" : text
    }
}
