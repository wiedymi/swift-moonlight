#if canImport(Metal) && canImport(QuartzCore) && canImport(UIKit) && os(iOS)
import UIKit

public extension MetalPresentationEDRCapabilities {
    @MainActor
    init(screen: UIScreen) {
        self.init(
            currentHeadroom: Double(screen.currentEDRHeadroom),
            potentialHeadroom: Double(screen.potentialEDRHeadroom)
        )
    }
}
#endif
