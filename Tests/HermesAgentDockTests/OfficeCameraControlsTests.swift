import Foundation
import Testing
@testable import HermesAgentDock

struct OfficeCameraControlsTests {
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
