#if canImport(MetalFX)
import Metal
import MetalFX
import QuartzCore
import Testing
@testable import SwiftMoonlight

@Test
func metalPictureBoundsDoNotStretchEdges() throws {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return }
    let library = try device.makeDefaultSwiftMoonlightLibrary()
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(name: "vertexMain")
    descriptor.fragmentFunction = library.makeFunction(name: "fragmentRGB")
    descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
    let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    let sourceDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
    sourceDescriptor.usage = .shaderRead
    let source = try #require(device.makeTexture(descriptor: sourceDescriptor))
    var red: [UInt8] = [0, 0, 255, 255]
    source.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &red, bytesPerRow: 4)
    let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 16, height: 16, mipmapped: false)
    targetDescriptor.usage = .renderTarget
    targetDescriptor.storageMode = .shared
    let target = try #require(device.makeTexture(descriptor: targetDescriptor))
    let command = try #require(queue.makeCommandBuffer())
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = target
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    let encoder = try #require(command.makeRenderCommandEncoder(descriptor: pass))
    let vertices: [Float] = [-1, -1, 0, 1, 3, -1, 2, 1, -1, 3, 0, -1]
    let buffer = try #require(device.makeBuffer(bytes: vertices, length: vertices.count * MemoryLayout<Float>.stride))
    var presentation = MetalPresentationUniform(scale: SIMD2(0.5, 0.5))
    encoder.setRenderPipelineState(pipeline)
    encoder.setVertexBuffer(buffer, offset: 0, index: 0)
    encoder.setVertexBytes(&presentation, length: MemoryLayout<MetalPresentationUniform>.stride, index: 1)
    encoder.setFragmentTexture(source, index: 0)
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    encoder.endEncoding()
    command.commit()
    command.waitUntilCompleted()
    #expect(command.status == .completed)
    var bytes = [UInt8](repeating: 0, count: 16 * 16 * 4)
    target.getBytes(&bytes, bytesPerRow: 16 * 4, from: MTLRegionMake2D(0, 0, 16, 16), mipmapLevel: 0)
    for y in 0..<16 {
        for x in 0..<16 {
            let expected: UInt8 = (4..<12).contains(x) && (4..<12).contains(y) ? 255 : 0
            #expect(bytes[(y * 16 + x) * 4 + 2] == expected)
        }
    }
}

@Test(arguments: [false, true])
func metalSpatialUpscalerEncodesSDRAndHDR(hdr: Bool) throws {
    guard let device = MTLCreateSystemDefaultDevice(),
          MTLFXSpatialScalerDescriptor.supportsDevice(device),
          let queue = device.makeCommandQueue() else { return }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: hdr ? .rgba16Float : .bgra8Unorm,
        width: 64, height: 36, mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .private
    let input = try #require(device.makeTexture(descriptor: descriptor))
    let upscaler = try #require(MetalSpatialUpscaler(device: device, input: input, width: 128, height: 72, hdr: hdr))
    let command = try #require(queue.makeCommandBuffer())
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = input
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
    let encoder = try #require(command.makeRenderCommandEncoder(descriptor: pass))
    encoder.endEncoding()
    let output = try #require(upscaler.encode(input: input, commandBuffer: command))
    #expect(output.width == 128 && output.height == 72)
    command.commit()
    command.waitUntilCompleted()
    #expect(command.status == .completed)
    #expect(command.error == nil)
}

@Test
func metalBackgroundBlurRemovesSmallTextDetail() throws {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 64, height: 64, mipmapped: false)
    descriptor.usage = .shaderRead
    descriptor.storageMode = .shared
    let input = try #require(device.makeTexture(descriptor: descriptor))
    var pixels = [UInt8](repeating: 255, count: 64 * 64 * 4)
    for y in 0..<64 {
        for x in 0..<64 {
            let value: UInt8 = (x + y) % 2 == 0 ? 255 : 0
            for channel in 0..<3 { pixels[(y * 64 + x) * 4 + channel] = value }
        }
    }
    input.replace(region: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0, withBytes: &pixels, bytesPerRow: 64 * 4)
    let blur = try #require(MetalBlurredBackground(device: device, source: input))
    let library = try device.makeDefaultSwiftMoonlightLibrary()
    let pipelineDescriptor = MTLRenderPipelineDescriptor()
    pipelineDescriptor.vertexFunction = library.makeFunction(name: "vertexMain")
    pipelineDescriptor.fragmentFunction = library.makeFunction(name: "fragmentRGB")
    pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
    let pipeline = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    let vertices: [Float] = [-1, -1, 0, 1, 3, -1, 2, 1, -1, 3, 0, -1]
    let buffer = try #require(device.makeBuffer(bytes: vertices, length: vertices.count * MemoryLayout<Float>.stride))
    let command = try #require(queue.makeCommandBuffer())
    let output = try #require(blur.encode(source: input, pipeline: pipeline, vertices: buffer, commandBuffer: command))
    let readback = try #require(device.makeTexture(descriptor: descriptor))
    let blit = try #require(command.makeBlitCommandEncoder())
    blit.copy(from: output, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
        sourceSize: MTLSize(width: 64, height: 64, depth: 1), to: readback,
        destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
    blit.endEncoding()
    command.commit()
    command.waitUntilCompleted()
    #expect(command.status == .completed)
    readback.getBytes(&pixels, bytesPerRow: 64 * 4, from: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0)
    for y in 16..<48 {
        for x in 16..<48 { #expect((120...135).contains(Int(pixels[(y * 64 + x) * 4]))) }
    }
}

@Test
func metalBlurCacheUpdatesForANewFrameWithTheSameTimestamp() throws {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 16, height: 16, mipmapped: false)
    descriptor.storageMode = .shared
    descriptor.usage = .shaderRead
    let source = try #require(device.makeTexture(descriptor: descriptor))
    let library = try device.makeDefaultSwiftMoonlightLibrary()
    let pipelineDescriptor = MTLRenderPipelineDescriptor()
    pipelineDescriptor.vertexFunction = library.makeFunction(name: "vertexMain")
    pipelineDescriptor.fragmentFunction = library.makeFunction(name: "fragmentRGB")
    pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
    let pipeline = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    let vertices: [Float] = [-1, -1, 0, 1, 3, -1, 2, 1, -1, 3, 0, -1]
    let buffer = try #require(device.makeBuffer(bytes: vertices, length: vertices.count * MemoryLayout<Float>.stride))
    let blur = try #require(MetalBlurredBackground(device: device, source: source))
    var previous: MetalPresentedFrame?
    for color in [UInt8(50), 200] {
        var pixels = [UInt8](repeating: color, count: 16 * 16 * 4)
        source.replace(region: MTLRegionMake2D(0, 0, 16, 16), mipmapLevel: 0, withBytes: &pixels, bytesPerRow: 64)
        let frame = MetalPresentedFrame(timestamp: 1, dimensions: CGSize(width: 16, height: 16), textures: .rgb(source))
        let command = try #require(queue.makeCommandBuffer())
        let output = try #require(blur.encode(source: source, frame: frame, pipeline: pipeline,
            vertices: buffer, commandBuffer: command))
        // Redrawing this same frame must reuse its existing filtered texture.
        #expect(blur.encode(source: source, frame: frame, pipeline: pipeline, vertices: buffer, commandBuffer: command) === output)
        let readback = try #require(device.makeTexture(descriptor: descriptor))
        let blit = try #require(command.makeBlitCommandEncoder())
        blit.copy(from: output, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: 16, height: 16, depth: 1), to: readback,
            destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        #expect(command.status == .completed)
        readback.getBytes(&pixels, bytesPerRow: 64, from: MTLRegionMake2D(0, 0, 16, 16), mipmapLevel: 0)
        #expect(abs(Int(pixels[0]) - Int(color)) <= 1)
        // Keep the previous object alive: equal timestamps still need a new blur.
        withExtendedLifetime(previous) {}
        previous = frame
    }
}
#endif
