// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Duckproof",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "DuckproofAudio",
            path: "Sources/DuckproofAudio",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
            ]
        ),
        .executableTarget(
            name: "Duckproof",
            dependencies: ["DuckproofAudio"],
            path: "Sources/Duckproof"
        ),
    ]
)
