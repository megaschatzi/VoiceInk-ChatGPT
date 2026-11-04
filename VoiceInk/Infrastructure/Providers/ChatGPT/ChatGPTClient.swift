import Foundation

enum ChatGPTCredentialStore {
    private static let key = "ChatGPTNativeOAuth.v1"

    static var isConnected: Bool { (try? load()) != nil }

    static func load() throws -> ChatGPTCredentials {
        switch KeychainService.shared.readData(forKey: key, syncable: false) {
        case .value(let data):
            guard let credentials = try? JSONDecoder().decode(ChatGPTCredentials.self, from: data) else {
                throw ChatGPTError.keychainUnavailable
            }
            return credentials
        case .notFound: throw ChatGPTError.signedOut
        case .unavailable: throw ChatGPTError.keychainUnavailable
        }
    }

    static func save(_ credentials: ChatGPTCredentials) throws {
        guard KeychainService.shared.save(data: try JSONEncoder().encode(credentials), forKey: key,
                                         syncable: false, accessibility: .afterFirstUnlockThisDeviceOnly) else {
            throw ChatGPTError.keychainUnavailable
        }
    }

    static func delete() throws {
        guard KeychainService.shared.delete(forKey: key, syncable: false) else { throw ChatGPTError.keychainUnavailable }
    }
}

protocol ChatGPTCredentialStorage: Sendable {
    func load() throws -> ChatGPTCredentials
    func save(_ credentials: ChatGPTCredentials) throws
    func delete() throws
}

private struct ChatGPTKeychainStorage: ChatGPTCredentialStorage {
    func load() throws -> ChatGPTCredentials { try ChatGPTCredentialStore.load() }
    func save(_ credentials: ChatGPTCredentials) throws { try ChatGPTCredentialStore.save(credentials) }
    func delete() throws { try ChatGPTCredentialStore.delete() }
}

/// Never forward bearer tokens or uploaded recordings to a redirect destination.
private final class ChatGPTSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

actor ChatGPTClient {
    static let shared = ChatGPTClient()
    private let session: URLSession
    private let storage: any ChatGPTCredentialStorage
    private var generation = UUID()
    private var refreshOperation: (id: UUID, task: Task<ChatGPTCredentials, Error>)?

    init(session: URLSession? = nil, storage: (any ChatGPTCredentialStorage)? = nil) {
        self.storage = storage ?? ChatGPTKeychainStorage()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForResource = 180
        self.session = session ?? URLSession(configuration: configuration, delegate: ChatGPTSessionDelegate(), delegateQueue: nil)
    }

    func requestDeviceCode() async throws -> ChatGPTDeviceCode {
        var request = URLRequest(url: URL(string: "https://auth.openai.com/api/accounts/deviceauth/usercode")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["client_id": ChatGPTProtocol.clientID])
        let (data, response) = try await session.data(for: request)
        let status = try statusCode(response)
        guard (200..<300).contains(status) else {
            if status == 404 { throw ChatGPTError.deviceLoginUnavailable }
            throw ChatGPTError.rejected(status)
        }
        return try ChatGPTDeviceCode(data: data)
    }

    func completeSignIn(_ device: ChatGPTDeviceCode) async throws {
        let attemptGeneration = generation
        while Date() < device.expiresAt {
            try Task.checkCancellation()
            var request = URLRequest(url: URL(string: "https://auth.openai.com/api/accounts/deviceauth/token")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 30
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["device_auth_id": device.id, "user_code": device.code])
            let (data, response) = try await session.data(for: request)
            let status = try statusCode(response)
            if status == 403 || status == 404 {
                try await Task.sleep(nanoseconds: UInt64(device.interval * 1_000_000_000))
                continue
            }
            guard (200..<300).contains(status) else { throw ChatGPTError.rejected(status) }
            guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let code = result["authorization_code"] as? String,
                let verifier = result["code_verifier"] as? String else { throw ChatGPTError.invalidResponse }
            let credentials = try await exchangeToken([
                "grant_type": "authorization_code", "client_id": ChatGPTProtocol.clientID,
                "code": code, "code_verifier": verifier,
                "redirect_uri": "https://auth.openai.com/deviceauth/callback",
            ])
            try Task.checkCancellation()
            guard attemptGeneration == generation else { throw CancellationError() }
            try storage.save(credentials)
            return
        }
        throw ChatGPTError.loginExpired
    }

    func signOut() throws {
        generation = UUID()
        refreshOperation?.task.cancel()
        refreshOperation = nil
        try storage.delete()
    }

    private func exchangeToken(_ fields: [String: String], previous: ChatGPTCredentials? = nil) async throws -> ChatGPTCredentials {
        var request = URLRequest(url: URL(string: "https://auth.openai.com/oauth/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = ChatGPTProtocol.form(fields)
        let (data, response) = try await session.data(for: request)
        let status = try statusCode(response)
        guard (200..<300).contains(status) else { throw ChatGPTError.rejected(status) }
        return try ChatGPTCredentials.decodeTokenResponse(data, previous: previous)
    }

    private func credentials(rejectedToken: String? = nil) async throws -> ChatGPTCredentials {
        let stored = try storage.load()
        // A concurrent request may already have refreshed the rejected token.
        if let rejectedToken, stored.accessToken != rejectedToken { return stored }
        if rejectedToken == nil, stored.expiresAt > Date().addingTimeInterval(60) { return stored }
        let refreshGeneration = generation
        let operation: (id: UUID, task: Task<ChatGPTCredentials, Error>)
        if let existing = refreshOperation { operation = existing }
        else {
            let task = Task { try await self.exchangeToken([
                "grant_type": "refresh_token", "client_id": ChatGPTProtocol.clientID,
                "refresh_token": stored.refreshToken,
            ], previous: stored) }
            operation = (UUID(), task)
            refreshOperation = operation
        }
        defer { if refreshOperation?.id == operation.id { refreshOperation = nil } }
        let renewed = try await operation.task.value
        guard generation == refreshGeneration else { throw CancellationError() }
        // Another waiter can have saved this refresh, or even completed a later
        // refresh. Never replace a newer rotated refresh token with an older one.
        let current = try storage.load()
        if current.accessToken != stored.accessToken { return current }
        try storage.save(renewed)
        try Task.checkCancellation()
        return renewed
    }

    func transcribe(audio: Data, fileName: String, language: String?, timeout: TimeInterval) async throws -> String {
        let requestGeneration = generation
        let boundary = "VoiceInk" + UUID().uuidString
        let body = try ChatGPTProtocol.multipart(audio: audio, fileName: fileName, language: language, boundary: boundary)
        var credential = try await credentials()
        for attempt in 0...1 {
            try Task.checkCancellation()
            var request = authorizedRequest(path: "transcribe", credential: credential, timeout: timeout)
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            let (data, response) = try await session.data(for: request)
            guard requestGeneration == generation else { throw CancellationError() }
            let status = try statusCode(response)
            if status == 401, attempt == 0 {
                credential = try await credentials(rejectedToken: credential.accessToken)
                continue
            }
            guard (200..<300).contains(status) else { throw ChatGPTError.rejected(status) }
            guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let text = result["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw ChatGPTError.invalidResponse }
            return text
        }
        throw ChatGPTError.rejected(401)
    }

    func enhance(input: [[String: String]], instructions: String, model: String, timeout: TimeInterval) async throws -> String {
        let requestGeneration = generation
        let messages: [[String: Any]] = input.map { message in
            let role = message["role"] == "assistant" ? "assistant" : "user"
            return ["role": role, "content": [["type": role == "assistant" ? "output_text" : "input_text",
                                                "text": message["content"] ?? ""]]]
        }
        let body = try JSONSerialization.data(withJSONObject: [
            "model": model, "instructions": instructions, "input": messages, "store": false, "stream": true,
            "reasoning": ["effort": "low"], "tools": [],
        ])
        var credential = try await credentials()
        for attempt in 0...1 {
            try Task.checkCancellation()
            var request = authorizedRequest(path: "codex/responses", credential: credential, timeout: timeout)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.httpBody = body
            let (bytes, response) = try await session.bytes(for: request)
            guard requestGeneration == generation else {
                bytes.task.cancel()
                throw CancellationError()
            }
            let status = try statusCode(response)
            if status == 401, attempt == 0 {
                bytes.task.cancel()
                credential = try await credentials(rejectedToken: credential.accessToken)
                continue
            }
            guard (200..<300).contains(status) else {
                bytes.task.cancel()
                throw ChatGPTError.rejected(status)
            }
            var accumulator = ChatGPTResponseAccumulator()
            var eventLines: [String] = []
            do {
                for try await line in bytes.lines {
                    try Task.checkCancellation()
                    if line.isEmpty {
                        if !eventLines.isEmpty {
                            try accumulator.consume(Data(eventLines.joined(separator: "\n").utf8))
                            eventLines.removeAll(keepingCapacity: true)
                            if accumulator.isComplete { break }
                        }
                    } else if line.hasPrefix("data:") {
                        let value = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if value != "[DONE]" { eventLines.append(value) }
                    }
                }
                if !eventLines.isEmpty { try accumulator.consume(Data(eventLines.joined(separator: "\n").utf8)) }
                bytes.task.cancel()
                guard requestGeneration == generation else { throw CancellationError() }
                return try accumulator.result()
            } catch {
                bytes.task.cancel()
                throw error
            }
        }
        throw ChatGPTError.rejected(401)
    }

    private func authorizedRequest(path: String, credential: ChatGPTCredentials, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/" + path)!)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credential.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("VoiceInk-ChatGPT/0.1", forHTTPHeaderField: "User-Agent")
        request.setValue("voiceink_chatgpt", forHTTPHeaderField: "originator")
        return request
    }

    private func statusCode(_ response: URLResponse) throws -> Int {
        guard let http = response as? HTTPURLResponse else { throw ChatGPTError.invalidResponse }
        return http.statusCode
    }
}
