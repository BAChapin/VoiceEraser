// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VoiceEraserKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "VoiceEraserKit", targets: ["VoiceEraserKit"]),
    ],
    targets: [
        .target(name: "VoiceEraserKit"),
        .testTarget(
            name: "VoiceEraserKitTests",
            dependencies: ["VoiceEraserKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
