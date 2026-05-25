#if os(macOS)
import AppKit
import SwiftUI

enum TestAppTheme {
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let sidebar = Color(nsColor: .windowBackgroundColor)
    static let panel = Color.primary.opacity(0.045)
    static let panelBorder = Color.primary.opacity(0.08)
    static let inlineFill = Color.primary.opacity(0.05)
    static let inlineStroke = Color.primary.opacity(0.08)
    static let accent = Color.accentColor
}

@MainActor
final class TestAppStreamWindowManager: NSObject, NSWindowDelegate {
    private weak var model: TestAppModel?
    private var window: NSWindow?

    func show(model: TestAppModel, fullscreen: Bool) {
        self.model = model
        let window = existingWindow(for: model)

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        if fullscreen, !window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        } else if !fullscreen, window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
    }

    func close() {
        window?.close()
    }

    private func existingWindow(for model: TestAppModel) -> NSWindow {
        if let window {
            update(window: window, model: model)
            return window
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "swift-moonlight stream"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        window.backgroundColor = NSColor.black
        window.minSize = NSSize(width: 960, height: 540)
        window.center()

        let toolbar = NSToolbar(identifier: "SwiftMoonlightStreamToolbar")
        toolbar.displayMode = .iconOnly
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.delegate = self

        update(window: window, model: model)
        self.window = window
        return window
    }

    private func update(window: NSWindow, model: TestAppModel) {
        let controller: NSHostingController<TestAppStreamWindowRoot>
        if let existing = window.contentViewController as? NSHostingController<TestAppStreamWindowRoot> {
            controller = existing
            controller.rootView = TestAppStreamWindowRoot(model: model)
        } else {
            controller = NSHostingController(rootView: TestAppStreamWindowRoot(model: model))
            window.contentViewController = controller
        }
    }

    func windowWillClose(_ notification: Notification) {
        model?.updateSurfaceFocus(false)
    }
}

@MainActor
final class TestAppSettingsWindowManager {
    private var window: NSWindow?

    func show(model: TestAppModel) {
        if let window {
            update(window: window, model: model)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let controller = NSHostingController(rootView: TestAppSettingsWindowRoot(model: model))
        let window = NSWindow(contentViewController: controller)
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(TestAppTheme.canvas)
        window.minSize = NSSize(width: 760, height: 560)
        window.setContentSize(NSSize(width: 840, height: 660))
        window.center()

        let toolbar = NSToolbar(identifier: "SwiftMoonlightSettingsToolbar")
        toolbar.displayMode = .iconOnly
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        self.window = window
        window.makeKeyAndOrderFront(nil)
    }

    private func update(window: NSWindow, model: TestAppModel) {
        guard let controller = window.contentViewController as? NSHostingController<TestAppSettingsWindowRoot> else {
            window.contentViewController = NSHostingController(rootView: TestAppSettingsWindowRoot(model: model))
            return
        }
        controller.rootView = TestAppSettingsWindowRoot(model: model)
    }
}

struct TestAppMainWindowChromeBridge: NSViewRepresentable {
    let windowTitle: String
    let backgroundColor: Color

    func makeNSView(context: Context) -> NSView {
        WindowObserverView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? WindowObserverView else { return }
        view.windowTitle = windowTitle
        view.backgroundColor = backgroundColor
        view.applyIfPossible()
    }

    private func configure(_ window: NSWindow, title: String, backgroundColor: Color) {
        let nsBackgroundColor = NSColor(backgroundColor)
        if window.title != title {
            window.title = title
        }
        window.backgroundColor = nsBackgroundColor
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.styleMask.insert(.fullSizeContentView)
        window.toolbarStyle = .unified
        window.toolbar?.showsBaselineSeparator = false
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = nsBackgroundColor.cgColor
        window.contentView?.superview?.wantsLayer = true
        window.contentView?.superview?.layer?.backgroundColor = nsBackgroundColor.cgColor
    }

    final class WindowObserverView: NSView {
        var windowTitle = ""
        var backgroundColor: Color = .clear

        override var intrinsicContentSize: NSSize { .zero }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyIfPossible()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            applyIfPossible()
        }

        func applyIfPossible() {
            guard let window else { return }
            TestAppMainWindowChromeBridge(
                windowTitle: windowTitle,
                backgroundColor: backgroundColor
            )
            .configure(
                window,
                title: windowTitle,
                backgroundColor: backgroundColor
            )
        }
    }
}

private struct TestAppStreamWindowRoot: View {
    @ObservedObject var model: TestAppModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            MetalSurfaceView(
                device: model.device,
                streamDimensions: model.currentVideoDimensions,
                mouseMode: model.mouseMode,
                hideLocalCursor: model.hasActiveSession && !model.showLocalCursor,
                onLayerReady: { layer in
                    model.attachLayer(layer)
                },
                onSurfaceSizeChanged: { size in
                    model.handleStreamSurfaceSizeChanged(size)
                },
                onInput: { event in
                    model.sendInput(event)
                },
                onFocusChanged: { isFocused in
                    model.updateSurfaceFocus(isFocused)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)

            TestAppSurfaceBadge(
                headline: model.hasActiveSession
                    ? (model.surfaceHasFocus ? "Input active" : "Click to focus stream input")
                    : "Stream window ready",
                detail: model.hasActiveSession
                    ? "Mouse, keyboard, and scroll events are routed into the active session."
                    : "Start a session from the main window to attach video, audio, and input."
            )
            .padding(18)
        }
        .background(TestAppTheme.canvas.ignoresSafeArea())
        .tint(TestAppTheme.accent)
    }
}

private struct TestAppSettingsWindowRoot: View {
    @ObservedObject var model: TestAppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                TestAppPanel("Stream Settings") {
                    TestAppStreamSettingsEditor(model: model)
                }

                TestAppPanel("Input") {
                    TestAppInputPreferencesPanel(model: model)
                }
            }
            .padding(20)
        }
        .background(TestAppTheme.canvas.ignoresSafeArea())
        .tint(TestAppTheme.accent)
    }
}

struct TestAppInputPreferencesPanel: View {
    @ObservedObject var model: TestAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Mouse Mode", selection: $model.mouseMode) {
                ForEach(TestAppMouseMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Text(model.mouseMode.detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Show local cursor over stream", isOn: $model.showLocalCursor)
        }
    }
}

struct TestAppStreamSettingsEditor: View {
    @ObservedObject var model: TestAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Picker("Resolution", selection: binding(\.resolution)) {
                    ForEach(TestAppResolutionPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }

                Picker("FPS", selection: binding(\.frameRate)) {
                    ForEach(TestAppFrameRatePreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
            }
            .pickerStyle(.menu)

            HStack(spacing: 12) {
                Picker("Codec", selection: binding(\.videoCodec)) {
                    ForEach(TestAppVideoCodecPreference.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }

                Picker("Audio", selection: binding(\.audioMode)) {
                    ForEach(TestAppAudioModePreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
            }
            .pickerStyle(.menu)

            HStack(spacing: 12) {
                Picker("Dynamic Range", selection: binding(\.dynamicRange)) {
                    ForEach(TestAppDynamicRangePreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }

                Picker("Decode", selection: binding(\.decodeMode)) {
                    ForEach(TestAppDecodeModePreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
            }
            .pickerStyle(.menu)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Bitrate")
                    Spacer()
                    Text("\(model.streamSettings.bitrateKbps) Kbps")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Slider(
                    value: Binding(
                        get: { Double(model.streamSettings.bitrateKbps) },
                        set: { newValue in
                            model.updateStreamSettings { $0.bitrateKbps = Int(newValue.rounded()) }
                        }
                    ),
                    in: 5_000...80_000,
                    step: 1_000
                )
            }

            Toggle("Open stream window in fullscreen on start", isOn: binding(\.openFullscreenOnStart))

            HStack {
                Text(model.streamSettings.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset Defaults") {
                    model.resetStreamSettings()
                }
            }
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<TestAppStreamSettings, Value>) -> Binding<Value> {
        Binding(
            get: { model.streamSettings[keyPath: keyPath] },
            set: { newValue in
                model.updateStreamSettings {
                    $0[keyPath: keyPath] = newValue
                }
            }
        )
    }
}
#endif
