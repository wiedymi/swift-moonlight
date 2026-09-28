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

actor MetricsRecorder {
    private var latest = SessionMetricsSnapshot()

    func update(_ snapshot: SessionMetricsSnapshot) {
        latest = snapshot
    }

    func snapshot() -> SessionMetricsSnapshot {
        latest
    }
}

actor WarningRecorder {
    private var warnings: [String] = []

    func append(_ warning: String) {
        warnings.append(warning)
    }

    func snapshot() -> [String] {
        warnings
    }
}

actor HDRModeRecorder {
    private var latest: HDRModeCaptureState?

    func update(_ update: HDRModeUpdate) {
        latest = HDRModeCaptureState(update: update)
    }

    func snapshot() -> HDRModeCaptureState? {
        latest
    }
}

actor FrameCaptureRenderer: FrameRenderer {
    private let outputDirectory: URL
    private let frameLimit: Int
    private let context = CIContext()
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private var preparedFormat: VideoFormat?
    private var capturedFiles: [URL] = []
    private var metadataRecords: [CapturedFrameMetadata] = []
    private var loggedPixelBufferFormat = false

    init(outputDirectory: URL, frameLimit: Int) {
        self.outputDirectory = outputDirectory
        self.frameLimit = frameLimit
    }

    func prepare(format: VideoFormat) async throws {
        preparedFormat = format
    }

    func render(_ frame: DecodedVideoFrame) async {
        guard capturedFiles.count < frameLimit else {
            return
        }
        guard let pixelBuffer = frame.pixelBuffer?.pixelBuffer else {
            return
        }

        if !loggedPixelBufferFormat {
            loggedPixelBufferFormat = true
            let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
            let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
            fputs(
                "swift-moonlight-capture frame trace: pixelFormat=\(fourCCString(format)) planeCount=\(planeCount)\n",
                stderr
            )
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let rect = CGRect(x: 0, y: 0, width: width, height: height)

        do {
            guard let cgImage = context.createCGImage(image, from: rect) else {
                throw MoonlightError(.unsupportedOperation, message: "Failed to create CGImage from decoded frame")
            }

            let fileURL = outputDirectory.appending(path: fileName(for: frame, index: capturedFiles.count + 1))
            guard let destination = CGImageDestinationCreateWithURL(fileURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                throw MoonlightError(.unsupportedOperation, message: "Failed to create image destination")
            }
            CGImageDestinationAddImage(destination, cgImage, [
                kCGImageDestinationLossyCompressionQuality: 1.0
            ] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                throw MoonlightError(.unsupportedOperation, message: "Failed to finalize image destination")
            }

            capturedFiles.append(fileURL)
            metadataRecords.append(makeMetadata(for: pixelBuffer, frame: frame, fileURL: fileURL))
        } catch {
            fputs("swift-moonlight-capture renderer warning: \(error)\n", stderr)
        }
    }

    func teardown() async {}

    func waitForCapture(timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if capturedFiles.count >= frameLimit {
                return true
            }
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return capturedFiles.count >= frameLimit
            }
        }
        return capturedFiles.count >= frameLimit
    }

    func snapshotFiles() -> [URL] {
        capturedFiles
    }

    func writeMetadataFile() -> URL? {
        guard !metadataRecords.isEmpty else {
            return nil
        }

        let fileURL = outputDirectory.appending(path: "frame-metadata.json")
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(metadataRecords)
            try data.write(to: fileURL, options: .atomic)
            return fileURL
        } catch {
            fputs("swift-moonlight-capture metadata warning: \(error)\n", stderr)
            return nil
        }
    }

    func snapshotMetadataRecords() -> [CapturedFrameMetadata] {
        metadataRecords
    }

    private func fileName(for frame: DecodedVideoFrame, index: Int) -> String {
        let formatSuffix: String
        if let preparedFormat {
            switch preparedFormat.codec {
            case .hevc:
                formatSuffix = "hevc"
            case .h264:
                formatSuffix = "h264"
            case .av1:
                formatSuffix = "av1"
            }
        } else {
            formatSuffix = "unknown"
        }
        let width = Int(frame.dimensions.width.rounded())
        let height = Int(frame.dimensions.height.rounded())
        return String(format: "frame-%04d-%@-%dx%d-ts-%llu.png", index, formatSuffix, width, height, frame.timestamp)
    }

    private func makeMetadata(
        for pixelBuffer: CVPixelBuffer,
        frame: DecodedVideoFrame,
        fileURL: URL
    ) -> CapturedFrameMetadata {
        let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
        let planes: [CapturedFramePlaneMetadata]
        if planeCount == 0 {
            planes = [
                CapturedFramePlaneMetadata(
                    index: 0,
                    width: CVPixelBufferGetWidth(pixelBuffer),
                    height: CVPixelBufferGetHeight(pixelBuffer),
                    bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer)
                )
            ]
        } else {
            planes = (0..<planeCount).map { index in
                CapturedFramePlaneMetadata(
                    index: index,
                    width: CVPixelBufferGetWidthOfPlane(pixelBuffer, index),
                    height: CVPixelBufferGetHeightOfPlane(pixelBuffer, index),
                    bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, index)
                )
            }
        }
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        return CapturedFrameMetadata(
            fileName: fileURL.lastPathComponent,
            timestamp: frame.timestamp,
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer),
            pixelFormat: UInt32(pixelFormat),
            pixelFormatName: fourCCString(pixelFormat),
            planeCount: planeCount,
            planes: planes,
            attachments: colorAttachments(from: pixelBuffer)
        )
    }

    private func colorAttachments(from pixelBuffer: CVPixelBuffer) -> [String: String] {
        [
            "colorPrimaries": attachmentDescription(kCVImageBufferColorPrimariesKey, from: pixelBuffer),
            "transferFunction": attachmentDescription(kCVImageBufferTransferFunctionKey, from: pixelBuffer),
            "ycbcrMatrix": attachmentDescription(kCVImageBufferYCbCrMatrixKey, from: pixelBuffer),
            "chromaLocationTop": attachmentDescription(kCVImageBufferChromaLocationTopFieldKey, from: pixelBuffer),
            "chromaLocationBottom": attachmentDescription(kCVImageBufferChromaLocationBottomFieldKey, from: pixelBuffer),
            "masteringDisplayColorVolume": attachmentDescription(kCVImageBufferMasteringDisplayColorVolumeKey, from: pixelBuffer),
            "contentLightLevelInfo": attachmentDescription(kCVImageBufferContentLightLevelInfoKey, from: pixelBuffer),
        ].compactMapValues { $0 }
    }

    private func attachmentDescription(_ key: CFString, from pixelBuffer: CVPixelBuffer) -> String? {
        CVBufferCopyAttachment(pixelBuffer, key, nil).map { String(describing: $0) }
    }

    private func fourCCString(_ value: OSType) -> String {
        let scalars: [UnicodeScalar] = [
            UnicodeScalar((value >> 24) & 0xFF),
            UnicodeScalar((value >> 16) & 0xFF),
            UnicodeScalar((value >> 8) & 0xFF),
            UnicodeScalar(value & 0xFF),
        ].compactMap { $0 }
        let text = String(String.UnicodeScalarView(scalars))
        if text.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 0x20 && $0.value < 0x7F }) {
            return text
        }
        return String(format: "0x%08X", value)
    }
}

actor FanoutRenderer: FrameRenderer {
    private let renderers: [any FrameRenderer]

    init(renderers: [any FrameRenderer]) {
        self.renderers = renderers
    }

    func prepare(format: VideoFormat) async throws {
        for renderer in renderers {
            try await renderer.prepare(format: format)
        }
    }

    func render(_ frame: DecodedVideoFrame) async {
        for renderer in renderers {
            await renderer.render(frame)
        }
    }

    func teardown() async {
        for renderer in renderers {
            await renderer.teardown()
        }
    }
}

#endif
