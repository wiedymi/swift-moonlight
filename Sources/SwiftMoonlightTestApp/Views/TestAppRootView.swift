#if os(macOS)
import AppKit
import Metal
import QuartzCore
import SwiftMoonlight
import SwiftUI
struct TestAppRootView: View {
    @StateObject private var model: TestAppModel

    init() {
        let model: TestAppModel
        do {
            model = try TestAppModel.makeDefault()
        } catch {
            model = TestAppModel(client: nil, hostStore: nil, device: MTLCreateSystemDefaultDevice(), initializationError: error)
        }
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        NavigationSplitView {
            TestAppSidebarShell(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 300)
        } detail: {
            TestAppWorkspaceView(model: model)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1100, minHeight: 760)
        .background(TestAppTheme.canvas)
        .tint(TestAppTheme.accent)
        .background(
            TestAppMainWindowChromeBridge(
                windowTitle: "swift-moonlight test app",
                backgroundColor: TestAppTheme.canvas
            )
            .frame(width: 0, height: 0)
        )
        .task {
            model.loadStoredHosts()
        }
    }
}

#endif
