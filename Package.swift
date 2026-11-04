// swift-tools-version: 5.9
import PackageDescription

// Focused protocol tests without downloading the macOS application's model dependencies.
let package = Package(
    name: "VoiceInkChatGPTProtocol",
    platforms: [.macOS("15.0")],
    targets: [
        .target(name: "ChatGPTCore", path: "VoiceInk/Infrastructure",
                exclude: ["Audio", "Diagnostics", "ExternalServices", "Licensing", "Persistence", "Privacy",
                          "RemoteConfig", "SystemIntegration", "TextProcessing", "Credentials/APIKeyManager.swift",
                          "Providers/Enhancement", "Providers/Transcription"],
                sources: ["Providers/ChatGPT/ChatGPTProtocol.swift", "Providers/ChatGPT/ChatGPTClient.swift",
                          "Credentials/KeychainService.swift"]),
        .testTarget(name: "ChatGPTCoreTests", dependencies: ["ChatGPTCore"], path: "Tests/ChatGPTCoreTests"),
    ]
)
