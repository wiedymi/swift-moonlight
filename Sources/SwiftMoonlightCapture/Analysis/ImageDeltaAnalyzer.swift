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

enum ImageDeltaAnalyzer {
    static func measure(referenceFiles: [URL], metalFiles: [URL]) throws -> ImageDeltaSummary? {
        let pairCount = min(referenceFiles.count, metalFiles.count)
        guard pairCount > 0 else {
            return nil
        }

        return try measurePairs((0..<pairCount).map { (referenceFiles[$0], metalFiles[$0]) })
    }

    static func measure(referenceFile: URL, comparisonFile: URL) throws -> ImageDeltaSummary? {
        try measurePairs([(referenceFile, comparisonFile)])
    }

    static func measureRegions(
        referenceFile: URL,
        comparisonFile: URL,
        requests: [ImageDeltaRegionRequest]
    ) throws -> [ImageDeltaRegionSummary] {
        guard !requests.isEmpty else {
            return []
        }

        let reference = try loadBGRA(referenceFile)
        let comparison = try loadBGRA(comparisonFile)
        guard reference.width == comparison.width, reference.height == comparison.height else {
            throw MoonlightError(
                .unsupportedOperation,
                message: "Cannot compare image regions with different dimensions: \(referenceFile.lastPathComponent) and \(comparisonFile.lastPathComponent)"
            )
        }

        return requests.map { request in
            measureRegion(reference: reference, comparison: comparison, request: request)
        }
    }

    static func detectInputVisualTarget(
        file: URL,
        expectedFrame: InputVisualExpectedFrame
    ) throws -> InputVisualTargetPresenceSummary {
        let image = try loadBGRA(file)
        let frameMinX = Int((Double(image.width) * expectedFrame.minX).rounded(.down))
        let frameMinY = Int((Double(image.height) * expectedFrame.minY).rounded(.down))
        let frameWidth = max(1, Int((Double(image.width) * expectedFrame.width).rounded(.down)))
        let frameHeight = max(1, Int((Double(image.height) * expectedFrame.height).rounded(.down)))
        let sentinelWidth = min(frameWidth, 320)
        let sentinelHeight = min(frameHeight, 64)
        let colors: [(r: UInt8, g: UInt8, b: UInt8)] = [
            (255, 0, 255),
            (0, 255, 0),
            (0, 102, 255),
            (255, 255, 255),
        ]
        let segmentWidth = max(1, sentinelWidth / colors.count)
        let ratios = colors.enumerated().map { index, color in
            let minX = frameMinX + index * segmentWidth + 8
            let maxX = min(frameMinX + (index + 1) * segmentWidth - 9, image.width - 1)
            let minY = frameMinY + 8
            let maxY = min(frameMinY + sentinelHeight - 9, image.height - 1)
            guard minX <= maxX, minY <= maxY else {
                return 0.0
            }
            return colorMatchRatio(
                image: image,
                minX: minX,
                maxX: maxX,
                minY: minY,
                maxY: maxY,
                color: color,
                tolerance: 48
            )
        }

        return InputVisualTargetPresenceSummary(
            detected: ratios.count == colors.count && ratios.allSatisfy { $0 >= 0.72 },
            sentinelRatios: ratios
        )
    }

    private static func measurePairs(_ filePairs: [(URL, URL)]) throws -> ImageDeltaSummary? {
        var totalSamples = 0
        var absoluteSum = 0.0
        var squaredSum = 0.0
        var maxDelta: UInt8 = 0
        var changedPixels = 0
        var totalPixels = 0
        var minChangedX = Int.max
        var minChangedY = Int.max
        var maxChangedX = 0
        var maxChangedY = 0

        for (referenceFile, comparisonFile) in filePairs {
            let reference = try loadBGRA(referenceFile)
            let comparison = try loadBGRA(comparisonFile)
            guard reference.width == comparison.width, reference.height == comparison.height else {
                throw MoonlightError(
                    .unsupportedOperation,
                    message: "Cannot compare images with different dimensions: \(referenceFile.lastPathComponent) and \(comparisonFile.lastPathComponent)"
                )
            }

            let sampleCount = min(reference.data.count, comparison.data.count)
            var offset = 0
            var pixelIndex = 0
            while offset + 2 < sampleCount {
                // Compare B, G, and R. Alpha is ignored because both capture paths
                // write opaque diagnostic PNGs.
                var pixelMaxDelta: UInt8 = 0
                for channel in 0..<3 {
                    let delta = UInt8(abs(Int(reference.data[offset + channel]) - Int(comparison.data[offset + channel])))
                    absoluteSum += Double(delta)
                    squaredSum += Double(delta) * Double(delta)
                    maxDelta = max(maxDelta, delta)
                    pixelMaxDelta = max(pixelMaxDelta, delta)
                    totalSamples += 1
                }
                if pixelMaxDelta >= 12 {
                    changedPixels += 1
                    let x = pixelIndex % reference.width
                    let y = pixelIndex / reference.width
                    minChangedX = min(minChangedX, x)
                    minChangedY = min(minChangedY, y)
                    maxChangedX = max(maxChangedX, x)
                    maxChangedY = max(maxChangedY, y)
                }
                totalPixels += 1
                pixelIndex += 1
                offset += 4
            }
        }

        guard totalSamples > 0 else {
            return nil
        }

        return ImageDeltaSummary(
            framePairs: filePairs.count,
            meanRGBDelta: absoluteSum / Double(totalSamples),
            rmsRGBDelta: sqrt(squaredSum / Double(totalSamples)),
            maxRGBDelta: maxDelta,
            changedPixels: changedPixels,
            totalPixels: totalPixels,
            changedPixelRatio: totalPixels == 0 ? 0 : Double(changedPixels) / Double(totalPixels),
            changedBounds: changedPixels == 0 ? nil : ImageDeltaBounds(
                minX: minChangedX,
                minY: minChangedY,
                maxX: maxChangedX,
                maxY: maxChangedY
            )
        )
    }

    private static func measureRegion(
        reference: (width: Int, height: Int, data: Data),
        comparison: (width: Int, height: Int, data: Data),
        request: ImageDeltaRegionRequest
    ) -> ImageDeltaRegionSummary {
        let centerX = Int((Double(reference.width - 1) * request.centerXRatio).rounded())
        let centerY = Int((Double(reference.height - 1) * request.centerYRatio).rounded())
        let minX = max(0, centerX - request.halfExtent)
        let maxX = min(reference.width - 1, centerX + request.halfExtent)
        let minY = max(0, centerY - request.halfExtent)
        let maxY = min(reference.height - 1, centerY + request.halfExtent)
        var changedPixels = 0
        var totalPixels = 0

        for y in minY...maxY {
            for x in minX...maxX {
                let offset = ((y * reference.width) + x) * 4
                guard offset + 2 < reference.data.count, offset + 2 < comparison.data.count else {
                    continue
                }
                var pixelMaxDelta: UInt8 = 0
                for channel in 0..<3 {
                    let delta = UInt8(abs(Int(reference.data[offset + channel]) - Int(comparison.data[offset + channel])))
                    pixelMaxDelta = max(pixelMaxDelta, delta)
                }
                if pixelMaxDelta >= 12 {
                    changedPixels += 1
                }
                totalPixels += 1
            }
        }

        return ImageDeltaRegionSummary(
            name: request.name,
            bounds: ImageDeltaBounds(minX: minX, minY: minY, maxX: maxX, maxY: maxY),
            changedPixels: changedPixels,
            totalPixels: totalPixels,
            changedPixelRatio: totalPixels == 0 ? 0 : Double(changedPixels) / Double(totalPixels)
        )
    }

    private static func colorMatchRatio(
        image: (width: Int, height: Int, data: Data),
        minX: Int,
        maxX: Int,
        minY: Int,
        maxY: Int,
        color: (r: UInt8, g: UInt8, b: UInt8),
        tolerance: UInt8
    ) -> Double {
        var matchedPixels = 0
        var totalPixels = 0

        for y in minY...maxY {
            for x in minX...maxX {
                let offset = ((y * image.width) + x) * 4
                guard offset + 2 < image.data.count else {
                    continue
                }
                let b = image.data[offset]
                let g = image.data[offset + 1]
                let r = image.data[offset + 2]
                if abs(Int(r) - Int(color.r)) <= Int(tolerance),
                   abs(Int(g) - Int(color.g)) <= Int(tolerance),
                   abs(Int(b) - Int(color.b)) <= Int(tolerance) {
                    matchedPixels += 1
                }
                totalPixels += 1
            }
        }

        return totalPixels == 0 ? 0 : Double(matchedPixels) / Double(totalPixels)
    }

    private static func loadBGRA(_ url: URL) throws -> (width: Int, height: Int, data: Data) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw MoonlightError(.unsupportedOperation, message: "Failed to load image for comparison: \(url.path)")
        }

        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var data = Data(repeating: 0, count: bytesPerRow * height)
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(.init(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))
        try data.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: bitmapInfo.rawValue
                  )
            else {
                throw MoonlightError(.unsupportedOperation, message: "Failed to create image comparison context")
            }

            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        return (width, height, data)
    }
}

#endif
