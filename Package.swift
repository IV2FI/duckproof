// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Unduck",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "UnduckAudio",
            path: "Sources/UnduckAudio",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
            ]
        ),
        .executableTarget(
            name: "Unduck",
            dependencies: ["UnduckAudio"],
            path: "Sources/Unduck"
        ),
    ]
)
