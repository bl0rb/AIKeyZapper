// swift-tools-version:6.0
import PackageDescription

let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "KeyZapper",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "KeyZapper", targets: ["KeyZapperApp"]),
        .executable(name: "keyzapper-helper", targets: ["keyzapper-helper"]),
    ],
    targets: [
        .target(name: "KeyZapperCore", swiftSettings: v5),
        .executableTarget(name: "keyzapper-helper", dependencies: ["KeyZapperCore"], path: "Sources/KeyHelper", swiftSettings: v5),
        .executableTarget(name: "KeyZapperApp", dependencies: ["KeyZapperCore"], swiftSettings: v5),
        .testTarget(name: "KeyZapperCoreTests", dependencies: ["KeyZapperCore"], swiftSettings: v5),
    ]
)
