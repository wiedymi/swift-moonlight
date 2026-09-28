#if os(macOS)
import AppKit
import Metal
import QuartzCore
import SwiftMoonlight
import SwiftUI
struct TestAppSectionLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(1.1)
            .foregroundStyle(.secondary)
    }
}

struct TestAppHostRow: View {
    let host: MoonlightHost
    let isSelected: Bool
    let isStreaming: Bool

    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "display.2")
                .foregroundStyle(isSelected ? selectedForegroundColor : .secondary)
                .imageScale(.medium)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(host.name)
                    .font(.body)
                    .foregroundStyle(isSelected ? selectedForegroundColor : .primary)
                    .lineLimit(1)

                Text("\(host.endpoint.address):\(host.endpoint.port) • \(hostKindTitle(host.kind)) • \(pairingTitle(host.pairingState))")
                    .font(.caption2)
                    .foregroundStyle(.secondary.opacity(0.75))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if isStreaming {
                HStack(spacing: 4) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text("LIVE")
                        .font(.caption)
                        .fontWeight(.semibold)
                }
                .foregroundStyle(sessionIndicatorColor)
            } else {
                Image(systemName: host.pairingState.isPaired ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(host.pairingState.isPaired ? .green : .secondary)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
        .background(selectionBackground)
    }

    private var selectedForegroundColor: Color {
        controlActiveState == .key ? .accentColor : .accentColor.opacity(0.78)
    }

    private var selectionFillColor: Color {
        let base = NSColor.unemphasizedSelectedContentBackgroundColor
        let alpha: Double = controlActiveState == .key ? 0.26 : 0.18
        return Color(nsColor: base).opacity(alpha)
    }

    private var sessionIndicatorColor: Color {
        isSelected ? selectedForegroundColor.opacity(0.9) : .secondary
    }

    @ViewBuilder
    private var selectionBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selectionFillColor)
        }
    }
}

struct TestAppAppRow: View {
    let app: RemoteApp
    let isSelected: Bool

    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "square.stack.3d.up")
                .foregroundStyle(isSelected ? selectedForegroundColor : .secondary)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.body)
                    .foregroundStyle(isSelected ? selectedForegroundColor : .primary)
                Text(app.id)
                    .font(.caption2)
                    .foregroundStyle(.secondary.opacity(0.75))
            }

            Spacer(minLength: 8)
        }
        .padding(.leading, 8)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
        .background(selectionBackground)
    }

    private var selectedForegroundColor: Color {
        controlActiveState == .key ? .accentColor : .accentColor.opacity(0.78)
    }

    private var selectionFillColor: Color {
        let base = NSColor.unemphasizedSelectedContentBackgroundColor
        let alpha: Double = controlActiveState == .key ? 0.26 : 0.18
        return Color(nsColor: base).opacity(alpha)
    }

    @ViewBuilder
    private var selectionBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selectionFillColor)
        }
    }
}

struct TestAppInlineIconButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(TestAppTheme.inlineFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(TestAppTheme.inlineStroke, lineWidth: 0.8)
                )
        }
        .buttonStyle(.plain)
        .help(title)
    }
}

struct TestAppCountPill: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(TestAppTheme.inlineFill, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(TestAppTheme.inlineStroke, lineWidth: 0.8)
            )
    }
}

struct TestAppPanel<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TestAppSectionLabel(title)
            content
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(TestAppTheme.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(TestAppTheme.panelBorder, lineWidth: 0.8)
                )
        )
    }
}

struct TestAppPillBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.18), in: Capsule())
            .foregroundStyle(tint)
    }
}

struct TestAppSurfaceBadge: View {
    let headline: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(headline)
                .font(.caption.weight(.semibold))
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

func hostKindTitle(_ kind: HostKind) -> String {
    switch kind {
    case .sunshine:
        return "Sunshine"
    case .apollo:
        return "Apollo"
    case .unknown:
        return "Unknown"
    }
}

func pairingTitle(_ state: PairingState) -> String {
    switch state {
    case .paired:
        return "Paired"
    case .unpaired:
        return "Unpaired"
    case .unknown:
        return "Unknown"
    }
}

#endif
