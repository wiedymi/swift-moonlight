#if os(macOS)
import AppKit
import Metal
import QuartzCore
import SwiftMoonlight
import SwiftUI
@main
struct SwiftMoonlightTestApp: App {
    var body: some Scene {
        WindowGroup("swift-moonlight test app") {
            TestAppRootView()
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1260, height: 820)
    }
}
#endif
