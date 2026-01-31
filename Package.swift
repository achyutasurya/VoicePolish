// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoicePolish",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", exact: "1.15.0"),
    ],
    targets: [
        .executableTarget(
            name: "VoicePolish",
            dependencies: ["KeyboardShortcuts"],
            path: "VoicePolish",
            resources: [
                .process("Assets.xcassets"),
                .copy("AppIcon.icns"),
            ]
        ),
    ]
)
