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
    dependencies: [.package(url: "https://github.com/wiedymi/swift-enet.git", revision: "6bb6c4d8fffd5e4ca250319424cac89109f9920d")],
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
