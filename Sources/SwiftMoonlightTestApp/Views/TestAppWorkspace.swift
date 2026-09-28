#if os(macOS)
import AppKit
import Metal
import QuartzCore
import SwiftMoonlight
import SwiftUI
struct TestAppWorkspaceView: View {
    @ObservedObject var model: TestAppModel

    var body: some View {
        ZStack {
            TestAppTheme.canvas.ignoresSafeArea()

            if let selectedHost = model.selectedHost {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        TestAppHostSummaryPanel(model: model, host: selectedHost)
                        HStack(alignment: .top, spacing: 18) {
                            TestAppAppsWorkspacePanel(model: model)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                            TestAppControlRail(model: model)
                                .frame(width: 340)
                        }

                        TestAppDiagnosticsWorkspacePanel(model: model)
                    }
                    .padding(20)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        TestAppPanel("Library") {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Add or discover a host")
                                    .font(.headline)
                                Text("The layout mirrors ViviTerm’s split view: hosts stay in the sidebar, and setup/app launch lives in the detail view.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                HStack(spacing: 10) {
                                    TextField("host or host:port", text: $model.manualHostAddress)
                                        .textFieldStyle(.plain)
                                    Button("Add") {
                                        model.addManualHost()
                                    }
                                    .disabled(model.manualHostAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(TestAppTheme.inlineFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(TestAppTheme.inlineStroke, lineWidth: 0.8)
                                )

                                HStack(spacing: 8) {
                                    Button("Discover Hosts") {
                                        model.discoverHosts()
                                    }
                                    .buttonStyle(.borderedProminent)

                                    Button("Open Stream Window") {
                                        model.presentStreamWindow()
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                    .padding(20)
                }
            }
        }
    }
}

struct TestAppHostSummaryPanel: View {
    @ObservedObject var model: TestAppModel
    let host: MoonlightHost

    private var selectedApp: RemoteApp? {
        model.apps.first(where: { $0.id == model.selectedAppID })
    }

    var body: some View {
        TestAppPanel("Session") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(host.name)
                            .font(.title2.weight(.semibold))
                        Text("\(host.endpoint.address):\(host.endpoint.port)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    HStack(spacing: 8) {
                        TestAppPillBadge(text: hostKindTitle(host.kind), tint: .blue)
                        TestAppPillBadge(
                            text: pairingTitle(host.pairingState),
                            tint: host.pairingState.isPaired ? .green : .orange
                        )
                    }
                }

                Divider()

                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Status")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(model.status)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Selected App")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(selectedApp?.name ?? "No app selected")
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Stream Profile")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(model.streamSettings.summary)
                    }
                }
            }
        }
    }
}

struct TestAppAppsWorkspacePanel: View {
    @ObservedObject var model: TestAppModel

    private var selectedApp: RemoteApp? {
        model.apps.first(where: { $0.id == model.selectedAppID })
    }

    var body: some View {
        TestAppPanel("Apps") {
            VStack(alignment: .leading, spacing: 12) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(model.apps) { app in
                            Button {
                                model.selectedAppID = app.id
                            } label: {
                                TestAppAppRow(app: app, isSelected: model.selectedAppID == app.id)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(minHeight: 320)

                HStack {
                    Button("Fetch Apps") { model.fetchApps() }
                        .buttonStyle(.borderedProminent)
                    Button("Start Session") { model.startSelectedApp() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.selectedAppID == nil)
                    Button("Stop") { model.stopSession() }
                        .disabled(!model.hasActiveSession)
                }
            }
        }
    }
}

struct TestAppControlRail: View {
    @ObservedObject var model: TestAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            TestAppPanel("Launch") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(model.apps.first(where: { $0.id == model.selectedAppID })?.name ?? "Select an app")
                        .font(.headline)
                    Text(model.apps.first(where: { $0.id == model.selectedAppID })?.id ?? "Fetch the app list to start a session.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        Button("Open Stream") {
                            model.presentStreamWindow()
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Settings") {
                            model.presentSettingsWindow()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            TestAppPanel("Host Tools") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Button("Discover") { model.discoverHosts() }
                            .buttonStyle(.bordered)
                        Button("Refresh") { model.refreshSelectedHost() }
                            .buttonStyle(.bordered)
                            .disabled(model.selectedHost == nil)
                    }

                    HStack(spacing: 10) {
                        TextField("host or host:port", text: $model.manualHostAddress)
                            .textFieldStyle(.plain)
                        Button("Add") { model.addManualHost() }
                            .disabled(model.manualHostAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(TestAppTheme.inlineFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(TestAppTheme.inlineStroke, lineWidth: 0.8)
                    )
                }
            }

            TestAppPanel("Pairing") {
                VStack(alignment: .leading, spacing: 12) {
                    SecureField("PIN", text: $model.pin)
                        .textFieldStyle(.roundedBorder)
                    SecureField("Apollo passphrase (optional)", text: $model.passphrase)
                        .textFieldStyle(.roundedBorder)

                    HStack(spacing: 8) {
                        Button("Pair") { model.pairSelectedHost() }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.selectedHost == nil)
                        Button("Unpair") { model.unpairSelectedHost() }
                            .buttonStyle(.bordered)
                            .disabled(model.selectedHost == nil)
                    }
                }
            }

            TestAppPanel("Profile") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.streamSettings.summary)
                    Text("Mouse: \(model.mouseMode.title) • Local cursor: \(model.showLocalCursor ? "shown" : "hidden")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(model.currentVideoDimensions.map { "Video: \(Int($0.width))×\(Int($0.height))" } ?? "Video: no active stream")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(model.surfaceHasFocus ? "Stream window focused for input" : "Focus the stream window before typing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct TestAppDiagnosticsWorkspacePanel: View {
    @ObservedObject var model: TestAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 18) {
                TestAppPanel("Metrics") {
                    ScrollView {
                        Text(model.latestMetrics)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 220)
                }

                TestAppPanel("Status") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(model.status)
                            .font(.headline)
                        Text(model.currentVideoDimensions.map { "\(Int($0.width))×\(Int($0.height))" } ?? "No active stream")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: 280)
            }

            TestAppPanel("Logs") {
                ScrollView {
                    Text(model.logLines.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 320)
            }
        }
    }
}

#endif
