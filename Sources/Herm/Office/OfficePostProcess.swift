import CoreImage
import Metal
import RealityKit
import os

/// A fixed GPU finish: quarter-resolution separable blur, then one full-resolution composite.
/// Pipelines and two small working textures are reused across frames.
final class OfficePostProcess: @unchecked Sendable {
    private struct Parameters {
        var tiltShift: Float = 0
        var isDark: Float = 0
    }

    private let parameters = OSAllocatedUnfairLock(initialState: Parameters())
    private var deviceID: UInt64?
    private var horizontal: (any MTLComputePipelineState)?
    private var composite: (any MTLComputePipelineState)?
    private var blurredColor: (any MTLTexture)?
    private var blurredHighlights: (any MTLTexture)?
    private var fallback: CIContext?

    func update(cameraDistance: Float, isDark: Bool) {
        let strength = min(1, max(0, (cameraDistance - 12) / 18))
        parameters.withLock { $0 = Parameters(tiltShift: strength, isDark: isDark ? 1 : 0) }
    }

    /// Compile once per GPU, including when rendering standalone test frames.
    @discardableResult
    func prepare(device: any MTLDevice) -> Bool {
        if deviceID == device.registryID { return horizontal != nil && composite != nil }
        deviceID = device.registryID
        horizontal = nil
        composite = nil
        blurredColor = nil
        blurredHighlights = nil
        fallback = nil
        guard let library = try? device.makeLibrary(source: Self.shader, options: nil),
            let first = library.makeFunction(name: "officeHorizontal"),
            let last = library.makeFunction(name: "officeComposite"),
            let firstPipeline = try? device.makeComputePipelineState(function: first),
            let lastPipeline = try? device.makeComputePipelineState(function: last)
        else { return false }
        horizontal = firstPipeline
        composite = lastPipeline
        return true
    }

    func process(_ frame: ARView.PostProcessContext) {
        let width = max(1, (frame.sourceColorTexture.width + 3) / 4)
        let height = max(1, (frame.sourceColorTexture.height + 3) / 4)
        if prepare(device: frame.device),
            blurredColor?.width != width || blurredColor?.height != height || blurredHighlights == nil
        {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
            descriptor.storageMode = .private
            descriptor.usage = [.shaderRead, .shaderWrite]
            blurredColor = frame.device.makeTexture(descriptor: descriptor)
            blurredHighlights = frame.device.makeTexture(descriptor: descriptor)
        }
        guard let horizontal, let composite, let blurredColor, let blurredHighlights,
            let first = frame.commandBuffer.makeComputeCommandEncoder()
        else {
            copyFrame(frame)
            return
        }
        var settings = parameters.withLock { $0 }
        first.setComputePipelineState(horizontal)
        first.setTexture(frame.sourceColorTexture, index: 0)
        first.setTexture(blurredColor, index: 1)
        first.setTexture(blurredHighlights, index: 2)
        first.setBytes(&settings, length: MemoryLayout<Parameters>.stride, index: 0)
        first.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        first.endEncoding()
        guard let last = frame.commandBuffer.makeComputeCommandEncoder() else {
            copyFrame(frame)
            return
        }
        last.setComputePipelineState(composite)
        last.setTexture(frame.sourceColorTexture, index: 0)
        last.setTexture(blurredColor, index: 1)
        last.setTexture(blurredHighlights, index: 2)
        last.setTexture(frame.targetColorTexture, index: 3)
        last.setBytes(&settings, length: MemoryLayout<Parameters>.stride, index: 0)
        last.dispatchThreads(
            MTLSize(width: frame.targetColorTexture.width, height: frame.targetColorTexture.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        last.endEncoding()
    }

    /// An unavailable effect must still deliver the original frame.
    private func copyFrame(_ frame: ARView.PostProcessContext) {
        let context = fallback ?? CIContext(mtlDevice: frame.device, options: [.cacheIntermediates: false])
        fallback = context
        guard let image = CIImage(mtlTexture: frame.sourceColorTexture, options: nil)?.oriented(.downMirrored) else {
            return
        }
        let destination = CIRenderDestination(mtlTexture: frame.targetColorTexture, commandBuffer: frame.commandBuffer)
        destination.isFlipped = true
        _ = try? context.startTask(toRender: image, to: destination)
    }

    private static let shader = """
        #include <metal_stdlib>
        using namespace metal;
        struct Parameters { float tiltShift; float isDark; };
        constant float weights[5] = {0.204164, 0.180174, 0.123832, 0.066282, 0.027631};
        constexpr sampler linearSample(coord::normalized, address::clamp_to_edge, filter::linear);

        float3 grade(float3 color, float dark) {
            float luminance = dot(color, float3(0.2126, 0.7152, 0.0722));
            color = mix(float3(luminance), color, mix(1.08, 1.06, dark));
            color = (color - 0.5) * mix(1.05, 1.06, dark) + 0.5;
            return max(float3(0), color * mix(float3(1.02, 1, 0.975), float3(1, 1, 1.02), dark));
        }

        kernel void officeHorizontal(
            texture2d<float, access::sample> source [[texture(0)]],
            texture2d<half, access::write> color [[texture(1)]],
            texture2d<half, access::write> highlights [[texture(2)]],
            constant Parameters &settings [[buffer(0)]], uint2 pixel [[thread_position_in_grid]]) {
            if (pixel.x >= color.get_width() || pixel.y >= color.get_height()) return;
            float2 uv = (float2(pixel) + 0.5) / float2(color.get_width(), color.get_height());
            float spread = float(source.get_height()) / (180.0 * float(source.get_width()));
            float threshold = mix(0.86, 0.62, settings.isDark);
            float3 blurred = 0, bright = 0;
            for (int i = -4; i <= 4; ++i) {
                float3 sample = grade(source.sample(linearSample, uv + float2(i * spread, 0)).rgb, settings.isDark);
                blurred += sample * weights[abs(i)];
                bright += saturate((sample - threshold) / (1 - threshold)) * weights[abs(i)];
            }
            color.write(half4(half3(blurred), 1), pixel);
            highlights.write(half4(half3(bright), 1), pixel);
        }

        kernel void officeComposite(
            texture2d<float, access::sample> source [[texture(0)]],
            texture2d<half, access::sample> color [[texture(1)]],
            texture2d<half, access::sample> highlights [[texture(2)]],
            texture2d<float, access::write> destination [[texture(3)]],
            constant Parameters &settings [[buffer(0)]], uint2 pixel [[thread_position_in_grid]]) {
            if (pixel.x >= destination.get_width() || pixel.y >= destination.get_height()) return;
            float2 size = float2(destination.get_width(), destination.get_height());
            float2 uv = (float2(pixel) + 0.5) / size;
            float3 blurred = 0, bright = 0;
            for (int i = -4; i <= 4; ++i) {
                float2 sampleUV = uv + float2(0, i / 180.0);
                blurred += float3(color.sample(linearSample, sampleUV).rgb) * weights[abs(i)];
                bright += float3(highlights.sample(linearSample, sampleUV).rgb) * weights[abs(i)];
            }
            float4 original = source.sample(linearSample, uv);
            float mask = max(saturate((0.4 - uv.y) / 0.4), saturate((uv.y - 0.66) / 0.34)) * settings.tiltShift;
            float3 result = mix(grade(original.rgb, settings.isDark), blurred, mask);
            result += bright * mix(float3(0.42, 0.36, 0.3), float3(0.75, 0.62, 0.5), settings.isDark);
            float radius = length((uv - 0.5) * size) / (max(size.x, size.y) * 0.62);
            result *= 1 - 0.16 * smoothstep(0.45, 1.0, radius);
            destination.write(float4(result, 1.0), pixel);
        }
        """
}
