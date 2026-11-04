import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ChatGPTConnectionView: View {
    @State private var isConnected = ChatGPTCredentialStore.isConnected
    @State private var deviceCode: String?
    @State private var work: Task<Void, Never>?
    @State private var isWorking = false
    @State private var message: String?
    @State private var succeeded = false
    @State private var isChoosingAudio = false

    var body: some View {
        ProviderConfigurationGroup(title: "Connection") {
            VStack(alignment: .leading, spacing: 12) {
                Label(isConnected ? String(localized: "Connected") : String(localized: "Not connected"),
                      systemImage: isConnected ? "checkmark.circle.fill" : "person.crop.circle")
                    .foregroundStyle(isConnected ? Color.green : Color.secondary)

                Text("Connect ChatGPT for transcription and text enhancement. No API key or installed CLI is required. Audio and text are sent to OpenAI.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Experimental connection: account access and usage limits apply. Included transcription allowance and continued availability are not guaranteed.")
                    .font(.caption).foregroundStyle(.secondary)

                if let deviceCode {
                    Text("Enter this one-time code on the OpenAI sign-in page:").font(.caption)
                    Text(deviceCode).font(.system(.title3, design: .monospaced)).textSelection(.enabled)
                    Link("Open ChatGPT sign-in", destination: ChatGPTProtocol.deviceVerificationURL)
                    Text("Complete sign-in in your browser. This window will update automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                HStack {
                    if isWorking {
                        ProgressView().controlSize(.small)
                        Button("Cancel") { cancel() }
                    } else if isConnected {
                        Button("Sign out") {
                            run {
                                try await ChatGPTClient.shared.signOut()
                                connectionChanged()
                            }
                        }
                    } else {
                        Button("Sign in with ChatGPT") { signIn() }.buttonStyle(.borderedProminent)
                    }
                }

                if isConnected {
                    HStack {
                        Button("Test text connection") {
                            run {
                                let text = try await ChatGPTClient.shared.enhance(
                                    input: [["role": "user", "content": "Reply with exactly: Connection successful."]],
                                    instructions: "Follow the user's instruction.", model: "gpt-6-luna", timeout: 45)
                                message = text
                            }
                        }
                        Button("Test audio file…") { isChoosingAudio = true }
                    }
                    .disabled(isWorking)
                    Text("A test sends the selected audio file or a short text request to OpenAI and uses your account allowance.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Use ChatGPT for dictation") {
                        NotificationCenter.default.post(name: .chatGPTSelectDictation, object: nil)
                    }.disabled(isWorking)
                }

                if let message {
                    Text(message).font(.caption).textSelection(.enabled)
                        .foregroundStyle(succeeded ? Color.primary : Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Link("Manage ChatGPT usage", destination: URL(string: "https://chatgpt.com/codex/settings/usage")!)
                    .font(.caption)
                SettingsImportView()
            }
        }
        .fileImporter(isPresented: $isChoosingAudio, allowedContentTypes: [.audio]) { result in
            switch result {
            case .success(let url):
                run {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                    guard let size = attributes[.size] as? NSNumber, size.intValue > 0, size.intValue < 20_000_000 else {
                        throw ChatGPTError.audioTooLarge
                    }
                    let audio = try Data(contentsOf: url)
                    message = try await ChatGPTClient.shared.transcribe(audio: audio, fileName: url.lastPathComponent,
                                                                       language: nil, timeout: 110)
                }
            case .failure(let error): message = error.localizedDescription; succeeded = false
            }
        }
        .onDisappear { cancel() }
    }

    private func signIn() {
        run {
            let device = try await ChatGPTClient.shared.requestDeviceCode()
            try Task.checkCancellation()
            deviceCode = device.code
            NSWorkspace.shared.open(ChatGPTProtocol.deviceVerificationURL)
            try await ChatGPTClient.shared.completeSignIn(device)
            deviceCode = nil
            connectionChanged()
            message = String(localized: "ChatGPT sign-in saved. Test the text or audio connection to check access.")
        }
    }

    private func connectionChanged() {
        isConnected = ChatGPTCredentialStore.isConnected
        NotificationCenter.default.post(name: .aiProviderKeyChanged, object: nil)
        NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !isWorking else { return }
        isWorking = true
        message = nil
        succeeded = false
        work = Task { @MainActor in
            defer { isWorking = false; deviceCode = nil; work = nil }
            do {
                try await operation()
                try Task.checkCancellation()
                succeeded = true
            } catch is CancellationError {
                // Cancellation is not an authentication or network failure.
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func cancel() { work?.cancel() }
}

extension Notification.Name {
    static let chatGPTSelectDictation = Notification.Name("chatGPTSelectDictation")
}
