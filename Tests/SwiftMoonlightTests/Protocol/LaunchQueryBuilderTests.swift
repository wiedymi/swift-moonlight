import Foundation
import Testing
@testable import SwiftMoonlight

@Test
func buildsSunshineLaunchQuery() {
    let builder = LaunchQueryBuilder()
    let host = MoonlightHost(
        id: HostID(),
        name: "Sunshine Host",
        endpoint: .init(address: "192.168.1.10", port: 47989),
        kind: .sunshine,
        pairingState: .paired,
        capabilities: .default
    )
    let identity = ClientIdentity(
        identifier: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        displayName: "Test Client"
    )
    let query = builder.buildLaunchQuery(
        host: host,
        appID: "desktop",
        configuration: .default1080p60,
        identity: identity,
        options: .init(remoteInputKeyHex: "00112233445566778899AABBCCDDEEFF", remoteInputKeyID: 42)
    )

    #expect(query.contains(.init(name: "uniqueid", value: "11111111-2222-3333-4444-555555555555")))
    #expect(query.contains(.init(name: "appid", value: "desktop")))
    #expect(query.contains(.init(name: "mode", value: "1920x1080x60")))
    #expect(query.contains(.init(name: "additionalStates", value: "1")))
    #expect(query.contains(.init(name: "rikey", value: "00112233445566778899aabbccddeeff")))
    #expect(query.contains(.init(name: "rikeyid", value: "42")))
    #expect(query.contains(.init(name: "localAudioPlayMode", value: "0")))
    #expect(query.contains(.init(name: "surroundAudioInfo", value: "196610")))
    #expect(query.contains(.init(name: "remoteControllersBitmap", value: "0")))
    #expect(query.contains(.init(name: "gcmap", value: "0")))
    #expect(query.contains(.init(name: "gcpersist", value: "0")))
    #expect(query.contains(.init(name: "hdrMode", value: "0")))
    #expect(!query.contains(where: { $0.name == "clientHdrCapVersion" }))
    #expect(query.contains(.init(name: "corever", value: "1")))
}

@Test
func buildsApolloLaunchQueryWithApolloExtensions() {
    let builder = LaunchQueryBuilder()
    let host = MoonlightHost(
        id: HostID(),
        name: "Apollo Host",
        endpoint: .init(address: "192.168.1.11", port: 47989),
        kind: .apollo,
        pairingState: .paired,
        capabilities: .default
    )
    let identity = ClientIdentity(
        identifier: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
        displayName: "Test Client"
    )
    let configuration = StreamConfiguration(
        resolution: CGSize(width: 2560, height: 1440),
        frameRate: 120,
        bitrateKbps: 35_000,
        dynamicRange: .hdr,
        videoCodecPreference: [.av1, .hevc, .h264],
        audioMode: .surround51,
        preferredDecodeMode: .hardwareFirst
    )
    let query = builder.buildLaunchQuery(
        host: host,
        appID: "steam",
        configuration: configuration,
        identity: identity,
        options: .init(
            remoteInputKeyHex: "AABBCCDDEEFF00112233445566778899",
            remoteInputKeyID: 7,
            localAudioPlayMode: true,
            coreVersion: 1,
            enableSops: true,
            gameControllerMapping: 1,
            remoteControllersBitmap: 1,
            persistGamepadsAfterDisconnect: true,
            continuousAudio: true,
            virtualDisplay: true,
            scaleFactor: 125
        )
    )

    #expect(query.contains(.init(name: "mode", value: "2560x1440x120")))
    #expect(query.contains(.init(name: "hdrMode", value: "1")))
    #expect(query.contains(.init(name: "clientHdrCapVersion", value: "0")))
    #expect(query.contains(.init(name: "clientHdrCapSupportedFlagsInUint32", value: "0")))
    #expect(query.contains(.init(name: "clientHdrCapMetaDataId", value: "NV_STATIC_METADATA_TYPE_1")))
    #expect(query.contains(.init(name: "clientHdrCapDisplayData", value: "0x0x0x0x0x0x0x0x0x0x0")))
    #expect(query.contains(.init(name: "localAudioPlayMode", value: "1")))
    #expect(query.contains(.init(name: "surroundAudioInfo", value: "4128774")))
    #expect(query.contains(.init(name: "remoteControllersBitmap", value: "1")))
    #expect(query.contains(.init(name: "gcmap", value: "1")))
    #expect(query.contains(.init(name: "gcpersist", value: "1")))
    #expect(query.contains(.init(name: "continuousAudio", value: "1")))
    #expect(query.contains(.init(name: "scaleFactor", value: "125")))
    #expect(query.contains(.init(name: "virtualDisplay", value: "1")))
}

@Test
func launchQueryUsesReferenceSurroundAudioInfoEncoding() {
    let builder = LaunchQueryBuilder()
    let host = MoonlightHost(
        id: HostID(),
        name: "Sunshine Host",
        endpoint: .init(address: "192.168.1.10", port: 47989),
        kind: .sunshine,
        pairingState: .paired,
        capabilities: .default
    )
    let identity = ClientIdentity(
        identifier: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        displayName: "Test Client"
    )

    let cases: [(AudioMode, String)] = [
        (.stereo, "196610"),
        (.surround51, "4128774"),
        (.surround71, "104792072"),
    ]

    for (audioMode, expectedValue) in cases {
        let configuration = StreamConfiguration(
            resolution: CGSize(width: 1920, height: 1080),
            frameRate: 60,
            bitrateKbps: 20_000,
            dynamicRange: .sdr,
            videoCodecPreference: [.hevc, .h264],
            audioMode: audioMode,
            preferredDecodeMode: .hardwareFirst
        )
        let query = builder.buildLaunchQuery(
            host: host,
            appID: "desktop",
            configuration: configuration,
            identity: identity,
            options: .init(remoteInputKeyHex: "00112233445566778899AABBCCDDEEFF", remoteInputKeyID: 42)
        )

        #expect(query.contains(.init(name: "surroundAudioInfo", value: expectedValue)))
    }
}

@Test
func hdrLaunchCapabilityFieldsAreConfigurable() {
    let builder = LaunchQueryBuilder()
    let host = MoonlightHost(
        id: HostID(),
        name: "Sunshine Host",
        endpoint: .init(address: "192.168.1.10", port: 47989),
        kind: .sunshine,
        pairingState: .paired,
        capabilities: .default
    )
    let identity = ClientIdentity(
        identifier: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        displayName: "Test Client"
    )
    let configuration = StreamConfiguration(
        resolution: CGSize(width: 1920, height: 1080),
        frameRate: 60,
        bitrateKbps: 20_000,
        dynamicRange: .hdr,
        videoCodecPreference: [.hevc],
        audioMode: .stereo,
        preferredDecodeMode: .hardwareFirst
    )

    let query = builder.buildLaunchQuery(
        host: host,
        appID: "desktop",
        configuration: configuration,
        identity: identity,
        options: .init(
            remoteInputKeyHex: "00112233445566778899AABBCCDDEEFF",
            remoteInputKeyID: 42,
            hdrCapabilities: .init(
                version: 1,
                supportedFlags: 7,
                metadataID: "CUSTOM_METADATA",
                displayData: "1x2x3"
            )
        )
    )

    #expect(query.contains(.init(name: "hdrMode", value: "1")))
    #expect(query.contains(.init(name: "clientHdrCapVersion", value: "1")))
    #expect(query.contains(.init(name: "clientHdrCapSupportedFlagsInUint32", value: "7")))
    #expect(query.contains(.init(name: "clientHdrCapMetaDataId", value: "CUSTOM_METADATA")))
    #expect(query.contains(.init(name: "clientHdrCapDisplayData", value: "1x2x3")))
}
