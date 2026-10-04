#if canImport(Metal) && canImport(QuartzCore) && canImport(AppKit)
import AppKit

public extension MetalPresentationEDRCapabilities {
    @MainActor
    init(screen: NSScreen) {
        self.init(
            currentHeadroom: Double(screen.maximumExtendedDynamicRangeColorComponentValue),
            potentialHeadroom: Double(screen.maximumPotentialExtendedDynamicRangeColorComponentValue)
        )
    }
}
#endif
