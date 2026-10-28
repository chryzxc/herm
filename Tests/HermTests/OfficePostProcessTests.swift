import CoreImage
import Metal
import RealityKit
import Testing

@testable import Herm

struct OfficePostProcessTests {
    @Test func sRGBSceneExposureMatchesThePreviousFinish() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let source = try texture(device, width: 128, height: 96, format: .bgra8Unorm_srgb)
        let output = try texture(device, width: 128, height: 96, format: .bgra8Unorm_srgb)
        let reference = try texture(device, width: 128, height: 96, format: .bgra8Unorm_srgb)
        let swatch: [UInt8] = [80, 120, 160, 255]
        var pixels = Array(repeating: swatch, count: 128 * 96).flatMap { $0 }
        source.replace(region: MTLRegionMake2D(0, 0, 128, 96), mipmapLevel: 0, withBytes: &pixels, bytesPerRow: 128 * 4)
        let image = try #require(CIImage(mtlTexture: source, options: nil)).oriented(.downMirrored)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.08, kCIInputContrastKey: 1.05])
            .applyingFilter(
                "CIColorMatrix",
                parameters: [
                    "inputRVector": CIVector(x: 1.02, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 0.975, w: 0),
                ]
            ).applyingFilter(
                "CIVignetteEffect",
                parameters: [
                    kCIInputCenterKey: CIVector(x: 64, y: 48), kCIInputRadiusKey: 128 * 0.62,
                    kCIInputIntensityKey: 0.16, "inputFalloff": 0.6,
                ])
        let context = CIContext(mtlDevice: device)
        let oldCommand = try #require(queue.makeCommandBuffer())
        let destination = CIRenderDestination(mtlTexture: reference, commandBuffer: oldCommand)
        destination.isFlipped = true
        _ = try context.startTask(toRender: image, to: destination)
        oldCommand.commit()
        oldCommand.waitUntilCompleted()
        let finish = OfficePostProcess()
        #expect(finish.prepare(device: device))
        let command = try #require(queue.makeCommandBuffer())
        finish.process(.init(device, command, source, source, output, matrix_identity_float4x4, 0))
        command.commit()
        command.waitUntilCompleted()
        var actual = [UInt8](repeating: 0, count: 4)
        var expected = actual
        for (x, y) in [(64, 48), (64, 64), (32, 48), (64, 0), (0, 0)] {
            output.getBytes(&actual, bytesPerRow: 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
            reference.getBytes(&expected, bytesPerRow: 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
            for channel in 0..<3 { #expect(abs(Int(actual[channel]) - Int(expected[channel])) <= 4) }
        }
    }

    @Test func finishPreservesOrientationThroughThemeAndSizeChanges() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let finish = OfficePostProcess()
        #expect(finish.prepare(device: device))
        for (width, height, distance, dark) in [(128, 96, Float(3), false), (160, 112, 44, true), (128, 96, 3, false)] {
            let source = try texture(device, width: width, height: height)
            let destination = try texture(device, width: width, height: height)
            let depth = try texture(device, width: width, height: height)
            var pixels = [SIMD4<Float>](repeating: [0.1, 0.1, 0.1, 1], count: width * height)
            for y in 0..<(height / 3) {
                for x in 0..<width { pixels[y * width + x] = [0.8, 0.4, 0.2, 1] }
            }
            source.replace(
                region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: &pixels,
                bytesPerRow: width * MemoryLayout<SIMD4<Float>>.stride)
            finish.update(cameraDistance: distance, isDark: dark)
            let command = try #require(queue.makeCommandBuffer())
            finish.process(.init(device, command, source, depth, destination, matrix_identity_float4x4, 0))
            command.commit()
            command.waitUntilCompleted()
            #expect(command.status == .completed)
            var output = pixels
            destination.getBytes(
                &output, bytesPerRow: width * MemoryLayout<SIMD4<Float>>.stride,
                from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            #expect(output.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
            #expect(output[(height / 6) * width + width / 2].x > output[(height * 5 / 6) * width + width / 2].x + 0.3)
            #expect(output[(height / 2) * width + width / 2].x > 0.01)
        }
    }

    /// Opt in with OFFICE_RENDER_BENCHMARK=1, or OFFICE_RENDER_SOAK_SECONDS=330 for a sustained run.
    @Test func repeatedFramesBenchmark() async throws {
        let soakSeconds = ProcessInfo.processInfo.environment["OFFICE_RENDER_SOAK_SECONDS"].flatMap(Int.init) ?? 0
        guard ProcessInfo.processInfo.environment["OFFICE_RENDER_BENCHMARK"] == "1" || soakSeconds > 0 else { return }
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let source = try texture(device, width: 1600, height: 1000, format: .bgra8Unorm_srgb)
        let destination = try texture(device, width: 1600, height: 1000, format: .bgra8Unorm_srgb)
        var pixels = [SIMD4<UInt8>](repeating: [80, 120, 160, 255], count: 1600 * 1000)
        source.replace(
            region: MTLRegionMake2D(0, 0, 1600, 1000), mipmapLevel: 0, withBytes: &pixels, bytesPerRow: 1600 * 4)
        let finish = OfficePostProcess()
        #expect(finish.prepare(device: device))
        finish.update(cameraDistance: 44, isDark: false)
        let clock = ContinuousClock()
        var durations: [Double] = []
        let began = clock.now
        var lastReport = began
        var index = 0
        func report() {
            guard !durations.isEmpty else { return }
            durations.sort()
            let median = durations[durations.count / 2]
            let p95 = durations[min(durations.count - 1, durations.count * 95 / 100)]
            let line =
                "Office finish 1600x1000: median \(median) ms, p95 \(p95) ms over \(durations.count) frames; "
                + "GPU allocation \(device.currentAllocatedSize / 1_048_576) MiB; elapsed \(began.duration(to: clock.now))"
            FileHandle.standardOutput.write(Data((line + "\n").utf8))
            durations.removeAll(keepingCapacity: true)
        }
        while soakSeconds > 0 ? began.duration(to: clock.now) < .seconds(soakSeconds) : index < 65 {
            let elapsed: Duration = try autoreleasepool {
                let command = try #require(queue.makeCommandBuffer())
                let start = clock.now
                finish.process(
                    .init(device, command, source, source, destination, matrix_identity_float4x4, Double(index)))
                command.commit()
                command.waitUntilCompleted()
                try #require(command.status == .completed)
                return start.duration(to: clock.now)
            }
            if index >= 5 {
                durations.append(
                    Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
            }
            index += 1
            if lastReport.duration(to: clock.now) >= .seconds(30) {
                report()
                lastReport = clock.now
            }
            if soakSeconds > 0 { try await Task.sleep(for: .milliseconds(33)) }
        }
        report()
    }

    private func texture(
        _ device: any MTLDevice, width: Int, height: Int, format: MTLPixelFormat = .rgba32Float
    ) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        return try #require(device.makeTexture(descriptor: descriptor))
    }
}
