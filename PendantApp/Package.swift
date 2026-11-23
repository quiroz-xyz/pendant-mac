// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PendantApp",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.1.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.18.0"),
    ],
    targets: [
        .executableTarget(name: "PendantApp", path: "Sources/PendantApp"),
        // Separate command-line tool so transcription runs in its own
        // low-priority process and frees its memory when it finishes.
        .executableTarget(
            name: "PendantTranscribe",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/PendantTranscribe"
        ),
    ]
)
