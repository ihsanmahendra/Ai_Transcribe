// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AITranscriber",
    platforms: [.macOS("15.0")],
    products: [
        .executable(name: "AITranscriber", targets: ["AITranscriber"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.1.0")
    ],
    targets: [
        .executableTarget(
            name: "AITranscriber",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit")
            ],
            path: "Sources/AITranscriber"
        )
    ]
)
