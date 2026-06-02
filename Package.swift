// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MotionSoundCore",
    platforms: [
        .iOS(.v17),
        .watchOS(.v10),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "MotionSoundCore",
            targets: ["MotionSoundCore"]
        ),
        .executable(
            name: "motion-sound-profile",
            targets: ["MotionSoundProfileTool"]
        ),
    ],
    targets: [
        .target(
            name: "MotionSoundCore"
        ),
        .executableTarget(
            name: "MotionSoundProfileTool",
            dependencies: ["MotionSoundCore"]
        ),
        .testTarget(
            name: "MotionSoundCoreTests",
            dependencies: ["MotionSoundCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
