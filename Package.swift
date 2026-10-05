// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "swift-moonlight",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .tvOS(.v17),
        .visionOS(.v1),
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
    dependencies: [.package(url: "https://github.com/wiedymi/swift-enet.git", revision: "4ce4ba7b67b5b0cdfb2c62a4d1048141520d3664")],
    targets: [
        .target(name: "SwiftMoonlight", dependencies: [.product(name: "SwiftENet", package: "swift-enet")]),
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
    ],
    swiftLanguageModes: [.v6]
)
