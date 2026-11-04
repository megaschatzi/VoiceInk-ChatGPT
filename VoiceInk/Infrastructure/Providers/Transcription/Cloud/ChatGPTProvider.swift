import Foundation

struct ChatGPTProvider: CloudProvider {
    let modelProvider: ModelProvider = .chatGPT
    let providerKey = "ChatGPT"
    let languageCodes: [String]? = nil
    let includesAutoDetect = true

    var models: [CloudModel] {
        [CloudModel(
            name: "chatgpt-dictation", displayName: "ChatGPT Dictation",
            description: "Experimental transcription with your ChatGPT connection. Audio is sent to OpenAI. Availability and usage limits depend on your account.",
            provider: .chatGPT, isMultilingual: true,
            supportedLanguages: LanguageDictionary.forProvider(isMultilingual: true, provider: .whisper)
        )]
    }

    func transcribe(audioData: Data, fileName: String, apiKey: String, model: String, language: String?,
                    customVocabulary: [String], timeout: TimeInterval) async throws -> String {
        try await ChatGPTClient.shared.transcribe(audio: audioData, fileName: fileName, language: language, timeout: timeout)
    }

    @MainActor func makeStreamingProvider(vocabulary: RecordingVocabulary) -> (any StreamingTranscriptionProvider)? { nil }

    func verifyAPIKey(_ key: String) async -> (isValid: Bool, errorMessage: String?) {
        (false, String(localized: "Sign in to ChatGPT in the model catalog first."))
    }
}
