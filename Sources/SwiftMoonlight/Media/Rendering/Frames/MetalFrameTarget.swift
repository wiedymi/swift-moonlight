#if canImport(Metal) && canImport(CoreVideo)
import CoreGraphics
import CoreVideo
import Foundation
import Metal

public protocol MetalFrameTarget: Sendable {
    func prepare(format: VideoFormat) async throws
    func present(_ frame: MetalPresentedFrame) async
    func teardown() async
}
#endif
