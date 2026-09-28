import Foundation
import SwiftMoonlight
#if canImport(CoreImage) && canImport(CoreVideo) && canImport(ImageIO) && canImport(UniformTypeIdentifiers)
import CoreGraphics
import CoreImage
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
#if canImport(Metal)
import Metal
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

actor InspectingVideoDecoder: VideoDecoder {
    private let wrapped: any VideoDecoder
    private let maxLoggedFrames = 5
    private var loggedFrames = 0

    init(wrapped: any VideoDecoder) {
        self.wrapped = wrapped
    }

    func configure(format: VideoFormat) async throws {
        fputs(
            "swift-moonlight-capture decode trace: configured codec=\(codecName(format.codec)) " +
            "dimensions=\(Int(format.dimensions.width))x\(Int(format.dimensions.height))\n",
            stderr
        )
        try await wrapped.configure(format: format)
    }

    func decode(_ frame: EncodedVideoFrame) async throws -> [DecodedVideoFrame] {
        let shouldLogThisFrame = loggedFrames < maxLoggedFrames
        if loggedFrames < maxLoggedFrames {
            loggedFrames += 1
            let parameterSets = frame.parameterSets.isEmpty
                ? AnnexBBitstream.codecParameterSets(from: frame.payload, codec: frame.codec)
                : frame.parameterSets
            let nalUnits = AnnexBBitstream.splitNALUnits(in: frame.payload)
            let nalTypes = nalUnits.prefix(8).map { nalTypeName(for: $0, codec: frame.codec) }.joined(separator: ",")
            let parameterSetSizes = parameterSets.map(\.count).map(String.init).joined(separator: ",")
            let prefixHex = hexString(Data(frame.payload.prefix(32)))
            fputs(
                "swift-moonlight-capture decode trace: " +
                "frame=\(loggedFrames) ts=\(frame.timestamp) key=\(frame.isKeyFrame) " +
                "codec=\(codecName(frame.codec)) payloadBytes=\(frame.payload.count) " +
                "nalUnits=\(nalUnits.count) nalTypes=[\(nalTypes)] " +
                "parameterSets=\(parameterSets.count) parameterSetSizes=[\(parameterSetSizes)] " +
                "prefix=\(prefixHex)\n",
                stderr
            )
        }

        let decoded = try await wrapped.decode(frame)
        if shouldLogThisFrame {
            fputs(
                "swift-moonlight-capture decode trace: " +
                "frame=\(loggedFrames) decodedOutputs=\(decoded.count)\n",
                stderr
            )
        }
        return decoded
    }

    func flush() async throws -> [DecodedVideoFrame] {
        try await wrapped.flush()
    }

    private func codecName(_ codec: VideoCodec) -> String {
        switch codec {
        case .hevc:
            return "hevc"
        case .h264:
            return "h264"
        case .av1:
            return "av1"
        }
    }

    private func nalTypeName(for unit: Data, codec: VideoCodec) -> String {
        guard let first = unit.first else {
            return "empty"
        }

        switch codec {
        case .hevc:
            let type = Int((first & 0x7E) >> 1)
            return "hevc:\(type)"
        case .h264:
            return "h264:\(Int(first & 0x1F))"
        case .av1:
            return "av1"
        }
    }

    private func hexString(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined()
    }
}

actor WAVCaptureAudioSink: AudioSink {
    private let fileURL: URL
    private var preparedFormat: AudioFormat?
    private var pcmData = Data()

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func prepare(format: AudioFormat) async throws {
        preparedFormat = format
    }

    func play(_ buffer: PCMBuffer) async {
        if preparedFormat == nil {
            preparedFormat = AudioFormat(sampleRate: buffer.sampleRate, channelCount: buffer.channelCount)
        }
        pcmData.append(buffer.data)
    }

    func teardown() async {
        guard let preparedFormat, !pcmData.isEmpty else {
            return
        }

        do {
            try WAVFileWriter.writePCM16LE(
                fileURL: fileURL,
                format: preparedFormat,
                pcmData: pcmData
            )
        } catch {
            fputs("swift-moonlight-capture audio warning: \(error)\n", stderr)
        }
    }

    func snapshot() -> (fileURL: URL?, bytes: Int) {
        let fileURL = pcmData.isEmpty ? nil : fileURL
        return (fileURL, pcmData.count)
    }
}

enum WAVFileWriter {
    static func writePCM16LE(fileURL: URL, format: AudioFormat, pcmData: Data) throws {
        let bitsPerSample = 16
        let blockAlign = UInt16(format.channelCount * bitsPerSample / 8)
        let byteRate = UInt32(format.sampleRate) * UInt32(blockAlign)
        let dataSize = UInt32(pcmData.count)
        let riffSize = 36 + dataSize

        var fileData = Data()
        fileData.append("RIFF".data(using: .ascii)!)
        fileData.appendLE(riffSize)
        fileData.append("WAVE".data(using: .ascii)!)
        fileData.append("fmt ".data(using: .ascii)!)
        fileData.appendLE(UInt32(16))
        fileData.appendLE(UInt16(1))
        fileData.appendLE(UInt16(format.channelCount))
        fileData.appendLE(UInt32(format.sampleRate))
        fileData.appendLE(byteRate)
        fileData.appendLE(blockAlign)
        fileData.appendLE(UInt16(bitsPerSample))
        fileData.append("data".data(using: .ascii)!)
        fileData.appendLE(dataSize)
        fileData.append(pcmData)
        try fileData.write(to: fileURL, options: .atomic)
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value >> 0))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func appendLE(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 0))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }
}

actor InspectingAudioDecoder: AudioDecoder {
    private let wrapped: any AudioDecoder
    private let maxLoggedPackets = 12
    private var loggedPackets = 0
    private var baselineTOC: UInt8?

    init(wrapped: any AudioDecoder) {
        self.wrapped = wrapped
    }

    func configure(format: AudioFormat) async throws {
        fputs(
            "swift-moonlight-capture audio trace: configured sampleRate=\(format.sampleRate) " +
            "channels=\(format.channelCount)\n",
            stderr
        )
        try await wrapped.configure(format: format)
    }

    func decode(_ packet: EncodedAudioPacket) async throws -> PCMBuffer {
        let packetIndex: Int?
        if loggedPackets < maxLoggedPackets {
            loggedPackets += 1
            packetIndex = loggedPackets
            let prefix = hexString(Data(packet.payload.prefix(16)))
            let tocString: String
            if let toc = packet.payload.first {
                if let baselineTOC, baselineTOC != toc {
                    fputs(
                        "swift-moonlight-capture audio trace: toc changed baseline=\(String(format: "%02X", baselineTOC)) " +
                        "current=\(String(format: "%02X", toc)) packet=\(packetIndex!)\n",
                        stderr
                    )
                } else if baselineTOC == nil {
                    baselineTOC = toc
                }
                tocString = String(format: "%02X", toc)
            } else {
                tocString = ""
            }
            fputs(
                "swift-moonlight-capture audio trace: " +
                "packet=\(packetIndex!) ts=\(packet.timestamp) concealment=\(packet.isConcealment) " +
                "payloadBytes=\(packet.payload.count) toc=\(tocString) prefix=\(prefix)\n",
                stderr
            )
        } else {
            packetIndex = nil
        }

        let buffer = try await wrapped.decode(packet)
        if let packetIndex {
            fputs(
                "swift-moonlight-capture audio trace: " +
                "packet=\(packetIndex) decodedFrames=\(buffer.frameCount) pcmBytes=\(buffer.data.count)\n",
                stderr
            )
        }
        return buffer
    }

    private func hexString(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined()
    }
}

#endif
