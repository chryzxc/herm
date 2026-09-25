import AppKit
import RealityKit
import Testing
@testable import HermesAgentDock

/// Opt-in visual check: `OFFICE_SNAPSHOT_DIR=/path swift test --filter OfficeRenderSnapshot`.
/// Set `OFFICE_SNAPSHOT_DARK=1` for the dark palette and `OFFICE_SNAPSHOT_HOUR=19.5`
/// to render a time of day (local, on the summer solstice).
struct OfficeRenderSnapshotTests {
    @MainActor @Test func renderOffice() async throws {
        guard let dir = ProcessInfo.processInfo.environment["OFFICE_SNAPSHOT_DIR"] else { return }
        let dark = ProcessInfo.processInfo.environment["OFFICE_SNAPSHOT_DARK"] == "1"
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1600, height: 1000), styleMask: [.titled], backing: .buffered, defer: false)
        let view = OfficePreviewARView(frame: window.contentView!.bounds)
        window.contentView = view
        window.orderFrontRegardless()
        let palette = OfficeScenePalette(theme: DockThemeRuntime.current, isDark: dark)
        view.environment.background = .color(palette.background)
        let coordinator = OfficePreviewSceneView.Coordinator(onSelectAgent: { _ in })
        coordinator.palette = palette
        coordinator.showsAgents = true
        let hour = ProcessInfo.processInfo.environment["OFFICE_SNAPSHOT_HOUR"].flatMap(Double.init)
        if let hour {
            var components = DateComponents(year: 2026, month: 6, day: 21)
            components.hour = Int(hour); components.minute = Int((hour - Double(Int(hour))) * 60)
            let date = Calendar.current.date(from: components)!
            coordinator.clock = { date }
        }
        let statuses = ["running", "running", "review", "running", "blocked", "todo", "running", "ready"]
        let steps = ["verify", "deploy", nil, "research", nil, nil, "design", nil]
        let agents = (0..<8).map { index in
            OfficePreviewAgentPresentation(id: "bot-\(index)", name: "Bot \(index)", tasks: [OfficePreviewTaskData(
                KanbanTaskSummary(id: "t\(index)", title: "Task \(index)", status: statuses[index], detail: nil, priority: nil,
                                  assignee: "bot-\(index)", currentStepKey: steps[index]))])
        }
        coordinator.install(in: view, agents: agents)
        var shots: [(String, OfficePreviewCameraState)] = []
        var whole = OfficePreviewCameraState()
        whole.orbitTarget = [0, 0.55, 2]; whole.distance = 44
        shots.append(("whole", whole))
        var west = OfficePreviewCameraState()
        west.orbitTarget = [-10.5, 0.55, -2]; west.distance = 24; west.azimuth = -0.35; west.elevation = 0.85
        shots.append(("west", west))
        var east = OfficePreviewCameraState()
        east.orbitTarget = [9, 0.55, 0]; east.distance = 22; east.azimuth = 0.4; east.elevation = 0.8
        shots.append(("east", east))
        var horizon = OfficePreviewCameraState()
        horizon.orbitTarget = [0, 0.55, 6]; horizon.distance = 40; horizon.azimuth = 0.5; horizon.elevation = 0.24
        shots.append(("horizon", horizon))
        var close = OfficePreviewCameraState()
        close.orbitTarget = [-12, 0.55, -6]; close.distance = 9; close.azimuth = 0.2; close.elevation = 0.7
        shots.append(("close", close))
        var lounge = OfficePreviewCameraState()
        lounge.orbitTarget = [-4.5, 0.8, -2.5]; lounge.distance = 6; lounge.azimuth = 0; lounge.elevation = 0.45
        shots.append(("lounge", lounge))
        try await Task.sleep(for: .seconds(3))
        for (name, state) in shots {
            coordinator.setCamera(state)
            try await Task.sleep(for: .seconds(1.2))
            let image: NSImage? = await withCheckedContinuation { c in view.snapshot(saveToHDR: false) { c.resume(returning: $0) } }
            if let tiff = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
                try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)\(dark ? "-dark" : "")\(hour.map { "-\($0)" } ?? "").jpg"))
            }
        }
        coordinator.stop()
    }
}
