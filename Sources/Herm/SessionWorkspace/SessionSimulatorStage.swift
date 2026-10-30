import SwiftUI

/// The rail shares the fitted device's canvas without covering pixels or changing touch coordinates.
struct SessionSimulatorStage: View {
    @ObservedObject var capture: SessionSimulatorCapture
    let image: CGImage
    let platform: SessionSimulatorPlatform
    let sessionKey: String
    let annotate: (String) -> Bool
    @State private var resetPreview = 0

    var body: some View {
        GeometryReader { geometry in
            let size = SessionSimulatorGeometry.stageCanvasSize(
                source: CGSize(width: image.width, height: image.height), available: geometry.size)
            HStack(alignment: .center, spacing: 6) {
                device(size: size)
                SessionSimulatorDebugTools(
                    capture: capture, diagnostics: capture.diagnostics, platform: platform, sessionKey: sessionKey
                )
                .frame(width: 40, height: max(0, min(size.height, geometry.size.height - 16)), alignment: .center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.dockDeviceCanvas)

    }

    private func device(size: CGSize) -> some View {
        Group {
            if capture.isPreviewing {
                VStack(spacing: 8) {
                    SessionSimulatorPreview(image: image, platform: platform, reset: resetPreview) {
                        capture.setPreviewing(false)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    HStack(spacing: 8) {
                        Button("Reset view") { resetPreview += 1 }.buttonStyle(.dockSecondary)
                    }
                    .dockPadding(.bottom, 8)
                }
            } else {
                SessionSimulatorCanvas(
                    capture: capture, image: image, platform: platform, annotate: annotate,
                    diagnostics: capture.diagnostics)
            }
        }
        .frame(width: size.width, height: size.height)
    }
}
