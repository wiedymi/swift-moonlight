import CoreGraphics
import Foundation

public struct RemoteInputSecrets: Equatable, Sendable {
    public var key: Data
    public var keyID: UInt32

    public init(key: Data, keyID: UInt32) {
        self.key = key
        self.keyID = keyID
    }
}

public struct SessionEncryptionFeatures: OptionSet, Sendable, Equatable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let controlV2 = SessionEncryptionFeatures(rawValue: 0x01)
    public static let video = SessionEncryptionFeatures(rawValue: 0x02)
    public static let audio = SessionEncryptionFeatures(rawValue: 0x04)
}

public struct NegotiatedSession: Equatable, Sendable {
    public var hostID: HostID
    public var appID: RemoteApp.ID
    public var rtspSessionURL: String
    public var videoFormat: VideoFormat?
    public var audioFormat: AudioFormat?
    public var remoteInputSecrets: RemoteInputSecrets?
    public var encryptionFeatures: SessionEncryptionFeatures
    public var isInputOnly: Bool
    public var channels: [EstablishedChannel]

    public init(
        hostID: HostID,
        appID: RemoteApp.ID,
        rtspSessionURL: String,
        videoFormat: VideoFormat? = nil,
        audioFormat: AudioFormat? = nil,
        remoteInputSecrets: RemoteInputSecrets? = nil,
        encryptionFeatures: SessionEncryptionFeatures = [],
        isInputOnly: Bool = false,
        channels: [EstablishedChannel] = []
    ) {
        self.hostID = hostID
        self.appID = appID
        self.rtspSessionURL = rtspSessionURL
        self.videoFormat = videoFormat
        self.audioFormat = audioFormat
        self.remoteInputSecrets = remoteInputSecrets
        self.encryptionFeatures = encryptionFeatures
        self.isInputOnly = isInputOnly
        self.channels = channels
    }
}

public enum ChannelKind: String, Sendable, Equatable, CaseIterable {
    case control
    case input
    case video
    case audio
}

public struct ChannelDescriptor: Sendable, Equatable {
    public var kind: ChannelKind
    public var port: UInt16
    public var metadata: [String: String]

    public init(kind: ChannelKind, port: UInt16, metadata: [String: String] = [:]) {
        self.kind = kind
        self.port = port
        self.metadata = metadata
    }
}

public struct EstablishedChannel: Sendable, Equatable {
    public var descriptor: ChannelDescriptor
    public var isConnected: Bool

    public init(descriptor: ChannelDescriptor, isConnected: Bool = true) {
        self.descriptor = descriptor
        self.isConnected = isConnected
    }
}
