#!/usr/bin/env swift

import AppKit

struct IconSpec {
    let filename: String
    let pixelSize: Int
}

let rootDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let outputDirectory: URL

if let argument = CommandLine.arguments.dropFirst().first {
    outputDirectory = URL(fileURLWithPath: argument, isDirectory: true)
} else {
    outputDirectory = rootDirectory.appending(path: "AppResources/SwiftMoonlightTestApp/Assets.xcassets/AppIcon.appiconset", directoryHint: .isDirectory)
}

let specs = [
    IconSpec(filename: "icon_16x16.png", pixelSize: 16),
    IconSpec(filename: "icon_16x16@2x.png", pixelSize: 32),
    IconSpec(filename: "icon_32x32.png", pixelSize: 32),
    IconSpec(filename: "icon_32x32@2x.png", pixelSize: 64),
    IconSpec(filename: "icon_128x128.png", pixelSize: 128),
    IconSpec(filename: "icon_128x128@2x.png", pixelSize: 256),
    IconSpec(filename: "icon_256x256.png", pixelSize: 256),
    IconSpec(filename: "icon_256x256@2x.png", pixelSize: 512),
    IconSpec(filename: "icon_512x512.png", pixelSize: 512),
    IconSpec(filename: "icon_512x512@2x.png", pixelSize: 1024),
]

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

for spec in specs {
    let destination = outputDirectory.appending(path: spec.filename)
    try pngData(pixelSize: spec.pixelSize).write(to: destination, options: .atomic)
    print("Wrote \(destination.path)")
}

func pngData(pixelSize: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "GenerateTestAppIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate bitmap context"])
    }

    bitmap.size = NSSize(width: pixelSize, height: pixelSize)

    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "GenerateTestAppIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create graphics context"])
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high

    drawIcon(pixelSize: pixelSize)

    NSGraphicsContext.restoreGraphicsState()

    guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "GenerateTestAppIcon", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG"])
    }

    return pngData
}

func drawIcon(pixelSize: Int) {
    let size = NSSize(width: pixelSize, height: pixelSize)
    let canvas = CGRect(origin: .zero, size: size)
    let inset = CGFloat(pixelSize) * 0.06
    let roundedRect = canvas.insetBy(dx: inset, dy: inset)
    let cornerRadius = CGFloat(pixelSize) * 0.22
    let shellPath = NSBezierPath(roundedRect: roundedRect, xRadius: cornerRadius, yRadius: cornerRadius)

    NSGraphicsContext.saveGraphicsState()
    let shellShadow = NSShadow()
    shellShadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.22)
    shellShadow.shadowBlurRadius = CGFloat(pixelSize) * 0.05
    shellShadow.shadowOffset = NSSize(width: 0, height: -CGFloat(pixelSize) * 0.02)
    shellShadow.set()
    let shellGradient = NSGradient(
        colorsAndLocations:
            (NSColor(calibratedRed: 0.06, green: 0.10, blue: 0.20, alpha: 1), 0.0),
            (NSColor(calibratedRed: 0.08, green: 0.17, blue: 0.36, alpha: 1), 0.55),
            (NSColor(calibratedRed: 0.05, green: 0.28, blue: 0.44, alpha: 1), 1.0)
    )!
    shellGradient.draw(in: shellPath, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    NSColor(calibratedWhite: 1, alpha: 0.08).setStroke()
    shellPath.lineWidth = max(2, CGFloat(pixelSize) * 0.015)
    shellPath.stroke()

    let moonOuterRect = CGRect(
        x: CGFloat(pixelSize) * 0.18,
        y: CGFloat(pixelSize) * 0.42,
        width: CGFloat(pixelSize) * 0.42,
        height: CGFloat(pixelSize) * 0.42
    )
    let moonCutoutRect = moonOuterRect.offsetBy(dx: CGFloat(pixelSize) * 0.12, dy: CGFloat(pixelSize) * 0.02)
    let moonPath = NSBezierPath()
    moonPath.appendOval(in: moonOuterRect)
    moonPath.appendOval(in: moonCutoutRect)
    moonPath.windingRule = .evenOdd

    NSGraphicsContext.saveGraphicsState()
    let moonShadow = NSShadow()
    moonShadow.shadowColor = NSColor(calibratedRed: 0.57, green: 0.83, blue: 1.0, alpha: 0.28)
    moonShadow.shadowBlurRadius = CGFloat(pixelSize) * 0.05
    moonShadow.shadowOffset = .zero
    moonShadow.set()
    let moonGradient = NSGradient(
        colorsAndLocations:
            (NSColor(calibratedRed: 0.90, green: 0.97, blue: 1.0, alpha: 1), 0.0),
            (NSColor(calibratedRed: 0.54, green: 0.84, blue: 0.99, alpha: 1), 1.0)
    )!
    moonGradient.draw(in: moonPath, angle: 90)
    NSGraphicsContext.restoreGraphicsState()

    let screenRect = CGRect(
        x: CGFloat(pixelSize) * 0.25,
        y: CGFloat(pixelSize) * 0.18,
        width: CGFloat(pixelSize) * 0.50,
        height: CGFloat(pixelSize) * 0.28
    )
    let screenPath = NSBezierPath(roundedRect: screenRect, xRadius: CGFloat(pixelSize) * 0.05, yRadius: CGFloat(pixelSize) * 0.05)
    let screenGradient = NSGradient(
        colorsAndLocations:
            (NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.18, alpha: 0.94), 0.0),
            (NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.14, alpha: 0.98), 1.0)
    )!
    screenGradient.draw(in: screenPath, angle: -90)
    NSColor(calibratedRed: 0.60, green: 0.87, blue: 1.0, alpha: 0.32).setStroke()
    screenPath.lineWidth = max(1.5, CGFloat(pixelSize) * 0.012)
    screenPath.stroke()

    let glowRect = screenRect.insetBy(dx: CGFloat(pixelSize) * 0.03, dy: CGFloat(pixelSize) * 0.03)
    let glowPath = NSBezierPath(roundedRect: glowRect, xRadius: CGFloat(pixelSize) * 0.03, yRadius: CGFloat(pixelSize) * 0.03)
    let glowGradient = NSGradient(
        colorsAndLocations:
            (NSColor(calibratedRed: 0.23, green: 0.67, blue: 0.93, alpha: 0.50), 0.0),
            (NSColor(calibratedRed: 0.08, green: 0.18, blue: 0.32, alpha: 0.12), 1.0)
    )!
    glowGradient.draw(in: glowPath, relativeCenterPosition: NSPoint(x: -0.45, y: 0.85))

    let standWidth = CGFloat(pixelSize) * 0.12
    let standHeight = CGFloat(pixelSize) * 0.08
    let standRect = CGRect(
        x: (CGFloat(pixelSize) - standWidth) / 2,
        y: CGFloat(pixelSize) * 0.12,
        width: standWidth,
        height: standHeight
    )
    let standPath = NSBezierPath(roundedRect: standRect, xRadius: CGFloat(pixelSize) * 0.02, yRadius: CGFloat(pixelSize) * 0.02)
    NSColor(calibratedRed: 0.70, green: 0.84, blue: 0.96, alpha: 0.88).setFill()
    standPath.fill()

    let baseRect = CGRect(
        x: CGFloat(pixelSize) * 0.34,
        y: CGFloat(pixelSize) * 0.09,
        width: CGFloat(pixelSize) * 0.32,
        height: CGFloat(pixelSize) * 0.04
    )
    let basePath = NSBezierPath(roundedRect: baseRect, xRadius: CGFloat(pixelSize) * 0.02, yRadius: CGFloat(pixelSize) * 0.02)
    NSColor(calibratedRed: 0.84, green: 0.93, blue: 1.0, alpha: 0.76).setFill()
    basePath.fill()

    drawStar(center: CGPoint(x: CGFloat(pixelSize) * 0.76, y: CGFloat(pixelSize) * 0.72), radius: CGFloat(pixelSize) * 0.045)
    drawStar(center: CGPoint(x: CGFloat(pixelSize) * 0.66, y: CGFloat(pixelSize) * 0.82), radius: CGFloat(pixelSize) * 0.022)
}

func drawStar(center: CGPoint, radius: CGFloat) {
    let path = NSBezierPath()
    let innerRadius = radius * 0.42
    for index in 0..<(10) {
        let angle = (CGFloat(index) * .pi / 5) - (.pi / 2)
        let currentRadius = index.isMultiple(of: 2) ? radius : innerRadius
        let point = CGPoint(
            x: center.x + cos(angle) * currentRadius,
            y: center.y + sin(angle) * currentRadius
        )
        if index == 0 {
            path.move(to: point)
        } else {
            path.line(to: point)
        }
    }
    path.close()
    NSColor(calibratedRed: 0.98, green: 0.96, blue: 0.78, alpha: 0.96).setFill()
    path.fill()
}
