#if canImport(Metal) && canImport(QuartzCore)
import CoreGraphics
import Foundation
import Metal
import QuartzCore

/// Layer access stays on the main actor, including view resize and display-link setup.
@MainActor final class MetalLayerReference {
    let layer: CAMetalLayer

    init(layer: CAMetalLayer) { self.layer = layer }
}
#endif
