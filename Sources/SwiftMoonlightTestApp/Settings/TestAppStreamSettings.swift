#if os(macOS)
import AppKit
import Metal
import QuartzCore
import SwiftMoonlight
import SwiftUI

/// Safety invariant:
/// - The test app owns the CAMetalLayer used for rendering.
/// - Once a session starts, the layer is only handed to the SwiftMoonlight rendering path.
struct UnsafeSendableMetalLayerReference: @unchecked Sendable {
    let layer: CAMetalLayer
}

struct AutoStartConfiguration {
    let enabled: Bool
    let hostOverride: HostEndpoint?
    let appIDOverride: RemoteApp.ID?

    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AutoStartConfiguration {
        let enabled = environment["SWIFT_MOONLIGHT_TEST_APP_AUTOSTART"] == "1"
        let hostOverride: HostEndpoint?
        if let rawValue = environment["SWIFT_MOONLIGHT_TEST_HOST"], !rawValue.isEmpty {
            if let url = URL(string: rawValue), let host = url.host {
                hostOverride = HostEndpoint(address: host, port: url.port ?? 47_989)
            } else if let separator = rawValue.lastIndex(of: ":"), separator != rawValue.startIndex,
                      let port = Int(rawValue[rawValue.index(after: separator)...]) {
                hostOverride = HostEndpoint(address: String(rawValue[..<separator]), port: port)
            } else {
                hostOverride = HostEndpoint(address: rawValue, port: 47_989)
            }
        } else {
            hostOverride = nil
        }
        let appIDOverride = environment["SWIFT_MOONLIGHT_TEST_APP_ID"].flatMap {
            $0.isEmpty ? nil : $0
        }
        return AutoStartConfiguration(
            enabled: enabled,
            hostOverride: hostOverride,
            appIDOverride: appIDOverride
        )
    }
}

enum TestAppMouseMode: String, CaseIterable, Identifiable {
    case direct
    case captured

    var id: Self { self }

    var title: String {
        switch self {
        case .direct:
            return "Direct"
        case .captured:
            return "Captured"
        }
    }

    var detail: String {
        switch self {
        case .direct:
            return "Absolute pointer positioning for touch-like desktop tests."
        case .captured:
            return "Relative mouse capture for physical mouse input."
        }
    }
}

enum TestAppResolutionPreset: String, CaseIterable, Identifiable, Codable {
    case streamWindow
    case hd720
    case fullHD1080
    case qhd1440
    case uhd4k

    var id: Self { self }

    var title: String {
        switch self {
        case .streamWindow:
            return "Window"
        case .hd720:
            return "1280×720"
        case .fullHD1080:
            return "1920×1080"
        case .qhd1440:
            return "2560×1440"
        case .uhd4k:
            return "3840×2160"
        }
    }

    var dimensions: CGSize {
        resolvedDimensions(fitting: nil)
    }

    func resolvedDimensions(fitting surfaceSize: CGSize?) -> CGSize {
        switch self {
        case .streamWindow:
            return Self.sanitizedWindowDimensions(surfaceSize ?? CGSize(width: 1920, height: 1080))
        case .hd720:
            return CGSize(width: 1280, height: 720)
        case .fullHD1080:
            return CGSize(width: 1920, height: 1080)
        case .qhd1440:
            return CGSize(width: 2560, height: 1440)
        case .uhd4k:
            return CGSize(width: 3840, height: 2160)
        }
    }

    private static func sanitizedWindowDimensions(_ size: CGSize) -> CGSize {
        let width = sanitizedEvenDimension(size.width, minimum: 640, maximum: 7680)
        let height = sanitizedEvenDimension(size.height, minimum: 360, maximum: 4320)
        return CGSize(width: width, height: height)
    }

    private static func sanitizedEvenDimension(_ value: CGFloat, minimum: Int, maximum: Int) -> Int {
        let rounded = Int(value.rounded(.toNearestOrAwayFromZero))
        let clamped = min(max(rounded, minimum), maximum)
        return clamped.isMultiple(of: 2) ? clamped : clamped - 1
    }
}

enum TestAppFrameRatePreset: Int, CaseIterable, Identifiable, Codable {
    case fps30 = 30
    case fps60 = 60
    case fps90 = 90
    case fps120 = 120

    var id: Int { rawValue }

    var title: String {
        "\(rawValue) FPS"
    }
}

enum TestAppVideoCodecPreference: String, CaseIterable, Identifiable, Codable {
    case auto
    case hevc
    case h264
    case av1

    var id: Self { self }

    var title: String {
        switch self {
        case .auto:
            return "Auto"
        case .hevc:
            return "HEVC"
        case .h264:
            return "H.264"
        case .av1:
            return "AV1"
        }
    }

    var streamPreference: [VideoCodec] {
        switch self {
        case .auto:
            return [.hevc, .h264]
        case .hevc:
            return [.hevc, .h264]
        case .h264:
            return [.h264]
        case .av1:
            return [.av1, .hevc, .h264]
        }
    }
}

enum TestAppAudioModePreset: String, CaseIterable, Identifiable, Codable {
    case stereo
    case surround51
    case surround71

    var id: Self { self }

    var title: String {
        switch self {
        case .stereo:
            return "Stereo"
        case .surround51:
            return "5.1"
        case .surround71:
            return "7.1"
        }
    }

    var audioMode: AudioMode {
        switch self {
        case .stereo:
            return .stereo
        case .surround51:
            return .surround51
        case .surround71:
            return .surround71
        }
    }
}

enum TestAppDynamicRangePreset: String, CaseIterable, Identifiable, Codable {
    case sdr
    case hdr

    var id: Self { self }

    var title: String {
        switch self {
        case .sdr:
            return "SDR"
        case .hdr:
            return "HDR"
        }
    }

    var dynamicRange: DynamicRangePreference {
        switch self {
        case .sdr:
            return .sdr
        case .hdr:
            return .hdr
        }
    }
}

enum TestAppDecodeModePreset: String, CaseIterable, Identifiable, Codable {
    case hardwareFirst
    case hardwareOnly
    case softwareFallback

    var id: Self { self }

    var title: String {
        switch self {
        case .hardwareFirst:
            return "Hardware First"
        case .hardwareOnly:
            return "Hardware Only"
        case .softwareFallback:
            return "Software Fallback"
        }
    }

    var decodeMode: DecodeModePreference {
        switch self {
        case .hardwareFirst:
            return .hardwareFirst
        case .hardwareOnly:
            return .hardwareOnly
        case .softwareFallback:
            return .softwareFallback
        }
    }
}

struct TestAppStreamSettings: Codable, Equatable {
    var resolution: TestAppResolutionPreset
    var frameRate: TestAppFrameRatePreset
    var bitrateKbps: Int
    var videoCodec: TestAppVideoCodecPreference
    var audioMode: TestAppAudioModePreset
    var dynamicRange: TestAppDynamicRangePreset
    var decodeMode: TestAppDecodeModePreset
    var openFullscreenOnStart: Bool

    static let `default` = TestAppStreamSettings(
        resolution: .streamWindow,
        frameRate: .fps60,
        bitrateKbps: 20_000,
        videoCodec: .auto,
        audioMode: .stereo,
        dynamicRange: .sdr,
        decodeMode: .hardwareFirst,
        openFullscreenOnStart: true
    )

    var sanitized: TestAppStreamSettings {
        var copy = self
        copy.bitrateKbps = min(max(copy.bitrateKbps, 1_000), 150_000)
        return copy
    }

    var streamConfiguration: StreamConfiguration {
        streamConfiguration(surfaceSize: nil)
    }

    func streamConfiguration(surfaceSize: CGSize?) -> StreamConfiguration {
        StreamConfiguration(
            resolution: resolution.resolvedDimensions(fitting: surfaceSize),
            frameRate: frameRate.rawValue,
            bitrateKbps: bitrateKbps,
            dynamicRange: dynamicRange.dynamicRange,
            videoCodecPreference: videoCodec.streamPreference,
            audioMode: audioMode.audioMode,
            preferredDecodeMode: decodeMode.decodeMode,
            enableControlEncryption: true,
            enableVideoEncryption: true,
            enableAudioEncryption: true
        )
    }

    var summary: String {
        "\(resolution.title) • \(frameRate.title) • \(bitrateKbps) Kbps • \(videoCodec.title) • \(audioMode.title)"
    }
}

enum TestAppStreamSettingsStore {
    private static let defaultsKey = "swiftMoonlightTestApp.streamSettings"

    static func load() -> TestAppStreamSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(TestAppStreamSettings.self, from: data)
        else {
            return .default
        }
        return settings.sanitized
    }

    static func save(_ settings: TestAppStreamSettings) {
        guard let data = try? JSONEncoder().encode(settings) else {
            return
        }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

#endif
