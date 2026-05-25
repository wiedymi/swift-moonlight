// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "swift-moonlight",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .tvOS(.v17),
    ],
    products: [
        .library(
            name: "SwiftMoonlight",
            targets: ["SwiftMoonlight"]
        ),
        .library(
            name: "SwiftMoonlightTestAppSupport",
            targets: ["SwiftMoonlightTestAppSupport"]
        ),
        .executable(
            name: "swift-moonlight-test-app",
            targets: ["SwiftMoonlightTestApp"]
        ),
        .executable(
            name: "swift-moonlight-smoke",
            targets: ["SwiftMoonlightSmoke"]
        ),
        .executable(
            name: "swift-moonlight-capture",
            targets: ["SwiftMoonlightCapture"]
        ),
    ],
    targets: [
        .binaryTarget(
            name: "COpus",
            path: "Vendor/COpus.xcframework"
        ),
        .target(
            name: "CENet",
            path: "Vendor/ENet",
            publicHeadersPath: "include"
        ),
        .target(
            name: "SwiftMoonlight",
            dependencies: ["COpus", "CENet"]
        ),
        .target(
            name: "SwiftMoonlightTestAppSupport",
            dependencies: ["SwiftMoonlight"]
        ),
        .executableTarget(
            name: "SwiftMoonlightTestApp",
            dependencies: ["SwiftMoonlight", "SwiftMoonlightTestAppSupport"]
        ),
        .executableTarget(
            name: "SwiftMoonlightSmoke",
            dependencies: ["SwiftMoonlight"]
        ),
        .executableTarget(
            name: "SwiftMoonlightCapture",
            dependencies: ["SwiftMoonlight"]
        ),
        .testTarget(
            name: "SwiftMoonlightTests",
            dependencies: ["SwiftMoonlight", "SwiftMoonlightTestAppSupport"],
            resources: [
                .process("Fixtures")
            ]
        ),
    ]
)
