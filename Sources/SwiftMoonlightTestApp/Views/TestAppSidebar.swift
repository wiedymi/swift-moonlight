#if os(macOS)
import AppKit
import Metal
import QuartzCore
import SwiftMoonlight
import SwiftUI
struct TestAppSidebarShell: View {
    @ObservedObject var model: TestAppModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("HOSTS")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    Spacer(minLength: 8)

                    TestAppCountPill(count: model.hosts.count)
                }
                .padding(.horizontal, 12)

                HStack(spacing: 8) {
                    TestAppInlineIconButton(title: "Discover", systemImage: "dot.radiowaves.left.and.right") {
                        model.discoverHosts()
                    }
                    TestAppInlineIconButton(title: "Refresh", systemImage: "arrow.clockwise") {
                        model.refreshSelectedHost()
                    }
                    .disabled(model.selectedHost == nil)

                    Spacer(minLength: 8)

                    TestAppInlineIconButton(title: "Settings", systemImage: "gearshape") {
                        model.presentSettingsWindow()
                    }
                }
                .padding(.horizontal, 12)
            }
            .padding(.top, 12)
            .padding(.bottom, 6)

            if model.hosts.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No hosts")
                        .font(.body)
                    Text("Discover Sunshine or Apollo hosts, or add one manually in the detail pane.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(model.hosts) { host in
                            Button {
                                model.selectHost(host.id)
                            } label: {
                                TestAppHostRow(
                                    host: host,
                                    isSelected: model.selectedHostID == host.id,
                                    isStreaming: model.hasActiveSession && model.selectedHostID == host.id
                                )
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                    .padding(.bottom, 2)
                }
            }

            Spacer(minLength: 0)

            VStack(spacing: 8) {
                Button {
                    model.presentStreamWindow()
                } label: {
                    Label("Open Stream", systemImage: "display")
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)

                HStack(spacing: 8) {
                    Button("Fetch Apps") {
                        model.fetchApps()
                    }
                    .disabled(model.selectedHost == nil)

                    Button("Settings") {
                        model.presentSettingsWindow()
                    }
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(TestAppTheme.sidebar.ignoresSafeArea())
    }
}

#endif
