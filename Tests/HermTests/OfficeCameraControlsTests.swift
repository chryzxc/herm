import AppKit
import RealityKit
import Testing

@testable import Herm

struct OfficeCameraControlsTests {
    /// Opt-in because measuring rendered frames requires a visible Metal-backed window.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["OFFICE_CAMERA_FRAME_SAMPLE"] == "1"))
    @MainActor func sampleDraggingInAnOccupiedOffice() async throws {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 960, height: 600), styleMask: [.titled], backing: .buffered,
            defer: false)
        let view = OfficePreviewARView(frame: window.contentView!.bounds)
        window.contentView = view
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        let suite = "OfficeCameraControlsTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let scene = OfficePreviewSceneView.Coordinator(
            placementStore: OfficePlacementStore(defaults: defaults), onSelectAgent: { _ in })
        let agents = (0..<8).map { OfficePreviewAgentPresentation(id: "bot-\($0)", name: "Bot \($0)", tasks: []) }
        scene.showsAgents = true
        scene.install(in: view, agents: agents, reduceMotion: true)
        defer { scene.stop() }
        try await Task.sleep(for: .seconds(2))
        let camera = try #require(view.scene.anchors.first?.children.first { $0 is PerspectiveCamera })
        let initial = camera.position
        var intervals: [Double] = []
        let subscription = view.scene.subscribe(to: SceneEvents.Update.self) { event in
            MainActor.assumeIsolated {
                let before = camera.position
                for _ in 0..<4 { scene.applyCameraGesture(.orbit, x: 0.5, y: 0) }
                #expect(camera.position == before)
                intervals.append(event.deltaTime * 1000)
            }
        }
        defer { subscription.cancel() }
        let reviewing = agents.map { agent in
            let task = KanbanTaskSummary(
                id: agent.id, title: "Review", status: "review", detail: nil, priority: nil, assignee: agent.id)
            return OfficePreviewAgentPresentation(id: agent.id, name: agent.name, tasks: [OfficePreviewTaskData(task)])
        }
        scene.update(agents: reviewing, reduceMotion: false)
        try await Task.sleep(for: .seconds(10))
        try #require(intervals.count > 1)
        #expect(camera.position != initial)
        let sorted = intervals.sorted()
        print(
            "Office orbit (ms), frames=\(sorted.count), median=\(sorted[sorted.count / 2]), p95=\(sorted[sorted.count * 95 / 100]), max=\(sorted.last!)"
        )
    }

    @MainActor
    @Test func movingLabelsKeepTheirSizeUntilContentChanges() {
        let bubble = OfficePreviewTaskBubble(frame: .zero)
        let short = OfficePreviewAgentPresentation(id: "bot", name: "Bo", tasks: [])
        let long = OfficePreviewAgentPresentation(id: "bot", name: "A considerably longer bot name", tasks: [])
        bubble.update(agent: short, reduceMotion: true, isDataCurrent: true)
        let initial = bubble.size(for: .compact)
        bubble.setTier(.dot)
        #expect(bubble.size(for: .compact) == initial)
        bubble.update(agent: long, reduceMotion: true, isDataCurrent: true)
        #expect(bubble.size(for: .compact).width > initial.width)
        bubble.update(agent: short, reduceMotion: true, isDataCurrent: true)
        #expect(bubble.size(for: .compact) == initial)
    }

    @Test func movementUsesCameraHeadingAndNormalizesDiagonals() {
        var forward = OfficePreviewCameraState()
        forward.azimuth = 0
        var diagonal = forward
        forward.advance(input: .init(forward: 1), delta: 0.02)
        diagonal.advance(input: .init(right: 1, forward: 1), delta: 0.02)
        let a = forward.orbitTarget - OfficePreviewCameraState.target
        let b = diagonal.orbitTarget - OfficePreviewCameraState.target
        #expect(a.z < 0 && a.x == 0)
        #expect(abs(a.z * a.z - (b.x * b.x + b.z * b.z)) < 0.00001)
        var rotated = OfficePreviewCameraState()
        rotated.azimuth = .pi / 2
        rotated.advance(input: .init(forward: 1), delta: 0.02)
        #expect(rotated.orbitTarget.x < 0)
        #expect(abs(rotated.orbitTarget.z) < 0.00001)
    }

    @Test func heldControlsAreFrameRateIndependentAndStopWithoutInput() {
        var thirty = OfficePreviewCameraState()
        var sixty = thirty
        for _ in 0..<30 { thirty.advance(input: .init(right: 1), delta: 1.0 / 30) }
        for _ in 0..<60 { sixty.advance(input: .init(right: 1), delta: 1.0 / 60) }
        #expect(abs(thirty.orbitTarget.x - sixty.orbitTarget.x) < 0.0001)
        let stopped = sixty
        sixty.advance(input: .init(), delta: 0.02)
        #expect(sixty == stopped)
    }

    @Test func tiltClampsAndZoomSettlesWithoutOvershooting() {
        var camera = OfficePreviewCameraState()
        for _ in 0..<200 { camera.advance(input: .init(tilt: 1), delta: 0.05) }
        #expect(camera.elevation == OfficePreviewCameraState.elevationRange.max)
        for _ in 0..<200 { camera.advance(input: .init(tilt: -1), delta: 0.05) }
        #expect(camera.elevation == OfficePreviewCameraState.elevationRange.min)
        camera.applyZoom(delta: 100_000)
        #expect(camera.distance == OfficePreviewCameraState.distanceRange.min)
        camera.applyZoom(delta: -100_000)
        #expect(camera.distance == OfficePreviewCameraState.distanceRange.max)
        for _ in 0..<120 {
            camera.easeZoom(toward: 8, delta: 1.0 / 60)
            #expect(camera.distance >= 8)
        }
        #expect(abs(camera.distance - 8) < 0.001)
    }
}
