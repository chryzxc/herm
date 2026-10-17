import CoreImage
import Metal
import os
import RealityKit

/// Screen-space finish for the office: a warm grade, soft bloom on lamps and
/// signs, and a tilt-shift blur that makes wide views read as a miniature.
/// Tilt-shift fades out as the camera moves in, so close views of a bot stay
/// sharp. The look is static; it adds no animation.
final class OfficePostProcess: @unchecked Sendable {
    private struct Parameters {
        var tiltShift: Float = 0
        var isDark = false
    }

    private let parameters = OSAllocatedUnfairLock(initialState: Parameters())
    private var context: CIContext?

    /// 0 keeps the frame sharp; 1 is the whole-office miniature.
    func update(cameraDistance: Float, isDark: Bool) {
        // Stepped: every distinct blur sigma is a new Core Image kernel, and
        // compiling one per zoom frame is what stutters.
        let strength = (min(1, max(0, (cameraDistance - 12) / 18)) * 12).rounded() / 12
        parameters.withLock { $0 = Parameters(tiltShift: strength, isDark: isDark) }
    }

    func process(_ frame: ARView.PostProcessContext) {
        let settings = parameters.withLock { $0 }
        let ciContext = context ?? CIContext(mtlDevice: frame.device, options: [.cacheIntermediates: false, .name: "office-post"])
        context = ciContext
        // Metal textures are top-left origin and Core Image is bottom-left:
        // orient the frame upright for the filters, then write it back flipped.
        guard let source = CIImage(mtlTexture: frame.sourceColorTexture, options: nil)?.oriented(.downMirrored) else { return }
        let extent = source.extent
        let graded = grade(source, isDark: settings.isDark)
        let bloomed = bloom(graded, extent: extent, isDark: settings.isDark)
        let focused = tiltShift(bloomed, extent: extent, strength: settings.tiltShift)
        let finished = vignette(focused, extent: extent)
        let destination = CIRenderDestination(mtlTexture: frame.targetColorTexture, commandBuffer: frame.commandBuffer)
        destination.isFlipped = true
        _ = try? ciContext.startTask(toRender: finished.cropped(to: extent), to: destination)
    }

    /// Richer, warmer colour: a touch more saturation and contrast, and a
    /// slight warm shift like late-afternoon light.
    private func grade(_ image: CIImage, isDark: Bool) -> CIImage {
        image
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: isDark ? 1.06 : 1.08,
                kCIInputContrastKey: isDark ? 1.06 : 1.05,
                kCIInputBrightnessKey: 0
            ])
            // Gains only: the frame is linear, so even a small bias would
            // tint every dark sign and trim.
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: isDark ? 1.0 : 1.02, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1.0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: isDark ? 1.02 : 0.975, w: 0)
            ])
    }

    /// Only near-white pixels glow: lamp shades, bulbs, neon and screens.
    private func bloom(_ image: CIImage, extent: CGRect, isDark: Bool) -> CIImage {
        let threshold: CGFloat = isDark ? 0.62 : 0.86
        let gain = 1 / (1 - threshold)
        let bright = image
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: gain, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: gain, w: 0),
                "inputBiasVector": CIVector(x: -threshold * gain, y: -threshold * gain, z: -threshold * gain, w: 0)
            ])
            .applyingFilter("CIColorClamp")
        let scale: CGFloat = 0.25
        let glow = bright
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .clampedToExtent()
            .applyingGaussianBlur(sigma: max(4, extent.height * scale / 90))
            .transformed(by: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
            .cropped(to: extent)
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: isDark ? 0.75 : 0.42, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: isDark ? 0.62 : 0.36, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: isDark ? 0.5 : 0.3, w: 0)
            ])
        return glow.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: image])
    }

    /// A sharp horizontal band through the middle; the top and bottom of the
    /// frame soften with a half-resolution blur.
    private func tiltShift(_ image: CIImage, extent: CGRect, strength: Float) -> CIImage {
        guard strength > 0.01 else { return image }
        let scale: CGFloat = 0.5
        let radius = CGFloat(strength) * extent.height * scale / 80
        let blurred = image
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .clampedToExtent()
            .applyingGaussianBlur(sigma: radius)
            .transformed(by: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
            .cropped(to: extent)
        let h = extent.height
        let amount = CIColor(red: CGFloat(strength), green: CGFloat(strength), blue: CGFloat(strength))
        func ramp(from: CGFloat, to: CGFloat) -> CIImage {
            CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: 0, y: extent.minY + from), "inputColor0": amount,
                "inputPoint1": CIVector(x: 0, y: extent.minY + to), "inputColor1": CIColor.black
            ])!.outputImage!.cropped(to: extent)
        }
        let mask = ramp(from: h, to: h * 0.60)
            .applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: ramp(from: 0, to: h * 0.34)])
        return blurred.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: mask
        ])
    }

    private func vignette(_ image: CIImage, extent: CGRect) -> CIImage {
        image.applyingFilter("CIVignetteEffect", parameters: [
            kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY),
            kCIInputRadiusKey: max(extent.width, extent.height) * 0.62,
            kCIInputIntensityKey: 0.16,
            "inputFalloff": 0.6
        ])
    }
}
