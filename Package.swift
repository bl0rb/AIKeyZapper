// swift-tools-version:6.0
import PackageDescription

let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "ProjectAISwitch",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ProjectAISwitch", targets: ["ProjectAISwitchApp"]),
        .executable(name: "aiswitch-key-helper", targets: ["aiswitch-key-helper"]),
    ],
    targets: [
        .target(name: "AISwitchCore", swiftSettings: v5),
        .executableTarget(name: "aiswitch-key-helper", dependencies: ["AISwitchCore"], path: "Sources/KeyHelper", swiftSettings: v5),
        .executableTarget(name: "ProjectAISwitchApp", dependencies: ["AISwitchCore"], swiftSettings: v5),
        .testTarget(name: "AISwitchCoreTests", dependencies: ["AISwitchCore"], swiftSettings: v5),
    ]
)
