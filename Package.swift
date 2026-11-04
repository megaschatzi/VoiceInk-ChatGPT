// swift-tools-version: 5.9
import PackageDescription

// Focused protocol tests without downloading the macOS application's model dependencies.
let package = Package(
    name: "VoiceInkChatGPTProtocol",
    platforms: [.macOS("15.0")],
    targets: [
        .target(name: "ChatGPTCore", path: "VoiceInk/Infrastructure/Providers/ChatGPT",
                exclude: ["ChatGPTClient.swift"], sources: ["ChatGPTProtocol.swift"]),
        .testTarget(name: "ChatGPTCoreTests", dependencies: ["ChatGPTCore"], path: "Tests/ChatGPTCoreTests"),
    ]
)
