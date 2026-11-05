import Foundation

enum ChatGPTError: Error, LocalizedError {
    case signedOut, keychainUnavailable, invalidResponse, loginExpired, deviceLoginUnavailable
    case rejected(Int), incompleteResponse, audioTooLarge, unsupportedAudio
    case textResponse(String)

    var errorDescription: String? {
        switch self {
        case .signedOut: return String(localized: "Sign in to ChatGPT in the model catalog first.")
        case .keychainUnavailable: return String(localized: "The ChatGPT connection could not be accessed in Keychain. Please unlock your login keychain and try again.")
        case .invalidResponse: return String(localized: "ChatGPT returned an unexpected response. This experimental connection may have changed.")
        case .loginExpired: return String(localized: "The ChatGPT sign-in expired. Please start sign-in again.")
        case .deviceLoginUnavailable: return String(localized: "Device code sign-in is unavailable. Enable device code authentication in your ChatGPT security settings, then try again.")
        case .audioTooLarge: return String(localized: "This experimental ChatGPT connection accepts recordings smaller than 20 MB. Please use a shorter recording.")
        case .unsupportedAudio: return String(localized: "Please choose a WAV, M4A, MP3, MP4, WebM, OGG or FLAC audio file.")
        case .incompleteResponse: return String(localized: "ChatGPT did not finish the response. The incomplete text was not used.")
        case .textResponse(let details):
            return String(format: String(localized: "ChatGPT text request failed. Diagnostic: %@"), details)
        case .rejected(let status):
            switch status {
            case 401: return String(localized: "ChatGPT did not accept this connection. Please sign out and sign in again.")
            case 403: return String(localized: "ChatGPT denied access. Your account, workspace policy, or service protection may restrict this experimental connection.")
            case 429: return String(localized: "ChatGPT reported a usage or rate limit. Check your ChatGPT usage and try again later.")
            default: return String(format: String(localized: "ChatGPT request failed (HTTP %lld)."), Int64(status))
            }
        }
    }
}

struct ChatGPTCredentials: Codable, Sendable {
    let accessToken: String
    let refreshToken: String
    let accountID: String
    let expiresAt: Date
    let email: String?

    static func decodeTokenResponse(_ data: Data, previous: ChatGPTCredentials? = nil, now: Date = Date()) throws -> Self {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let access = object["access_token"] as? String, !access.isEmpty,
            let refresh = object["refresh_token"] as? String ?? previous?.refreshToken, !refresh.isEmpty
        else { throw ChatGPTError.invalidResponse }
        let claims = jwtClaims(access)
        let identity = jwtClaims(object["id_token"] as? String ?? "")
        let account = (claims["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_account_id"] as? String
            ?? (identity["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_account_id"] as? String
            ?? previous?.accountID
        guard let account, !account.isEmpty else { throw ChatGPTError.invalidResponse }
        let expiration = (claims["exp"] as? Double).map { Date(timeIntervalSince1970: $0) }
            ?? (object["expires_in"] as? Double).map { now.addingTimeInterval($0) }
        guard let expiration, expiration > now else { throw ChatGPTError.invalidResponse }
        // These claims are metadata from the TLS-protected token response, not an
        // independent identity/authorization decision. The server validates the bearer.
        return Self(accessToken: access, refreshToken: refresh, accountID: account, expiresAt: expiration,
                    email: identity["email"] as? String ?? previous?.email)
    }

    private static func jwtClaims(_ jwt: String) -> [String: Any] {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return [:] }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
            let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return claims
    }
}

struct ChatGPTDeviceCode: Sendable {
    let id: String
    let code: String
    let interval: TimeInterval
    let expiresAt: Date

    init(data: Data, now: Date = Date()) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let id = object["device_auth_id"] as? String, !id.isEmpty,
            let code = object["user_code"] as? String ?? object["usercode"] as? String, !code.isEmpty
        else { throw ChatGPTError.invalidResponse }
        self.id = id
        self.code = code
        let seconds = object["interval"] as? Double ?? (object["interval"] as? String).flatMap(Double.init) ?? 5
        interval = min(30, max(1, seconds))
        expiresAt = now.addingTimeInterval(15 * 60)
    }
}

enum ChatGPTProtocol {
    // OpenAI's public native Codex OAuth client, also used by external Codex clients.
    // This is not a secret. The narrower general SIWC flow does not grant audio access.
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let deviceVerificationURL = URL(string: "https://auth.openai.com/codex/device")!

    static func form(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return fields.sorted { $0.key < $1.key }.map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&").data(using: .utf8)!
    }

    static func multipart(audio: Data, fileName: String, language: String?, boundary: String) throws -> Data {
        guard !audio.isEmpty, audio.count < 20_000_000 else { throw ChatGPTError.audioTooLarge }
        let ext = (fileName as NSString).pathExtension.lowercased()
        let types = ["wav": "audio/wav", "m4a": "audio/mp4", "mp4": "audio/mp4", "mp3": "audio/mpeg",
                     "webm": "audio/webm", "ogg": "audio/ogg", "flac": "audio/flac"]
        guard let mime = types[ext] else { throw ChatGPTError.unsupportedAudio }
        var data = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"dictation.\(ext)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8)
        data.append(audio)
        data.append(Data("\r\n".utf8))
        if let language, !language.isEmpty, language != "auto" {
            let safeLanguage = language.filter { $0.isLetter || $0 == "-" }
            data.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"language\"\r\n\r\n\(safeLanguage)\r\n".utf8))
        }
        data.append(Data("--\(boundary)--\r\n".utf8))
        return data
    }
}

/// Frame SSE from raw UTF-8 bytes. AsyncBytes.lines coalesces consecutive line
/// endings on Apple platforms, losing the empty lines that delimit SSE events.
/// It must not be used to decide where one JSON event ends and the next begins.
struct ChatGPTEventStreamDecoder {
    private var line: [UInt8] = []
    private var dataLines: [String] = []
    private var eventSize = 0
    private var skipLF = false
    private var isFirstLine = true
    private let maximumEventBytes = 8 * 1024 * 1024

    mutating func append(_ byte: UInt8) throws -> Data? {
        if skipLF {
            skipLF = false
            if byte == 10 { return nil }
        }
        if byte == 13 || byte == 10 {
            skipLF = byte == 13
            return try finishLine()
        }
        guard line.count < maximumEventBytes else { throw ChatGPTError.invalidResponse }
        line.append(byte)
        return nil
    }

    mutating func finish() throws -> Data? {
        // Codex-compatible servers can end the final SSE frame at EOF instead
        // of sending another blank line. Completion is still checked separately.
        if !line.isEmpty { _ = try finishLine() }
        guard !dataLines.isEmpty else { return nil }
        defer { dataLines.removeAll(); eventSize = 0 }
        return Data(dataLines.joined(separator: "\n").utf8)
    }

    private mutating func finishLine() throws -> Data? {
        defer { line.removeAll(keepingCapacity: true) }
        if isFirstLine {
            isFirstLine = false
            if line.starts(with: [0xEF, 0xBB, 0xBF]) { line.removeFirst(3) }
        }
        guard let text = String(bytes: line, encoding: .utf8) else { throw ChatGPTError.invalidResponse }
        if text.isEmpty {
            defer { dataLines.removeAll(keepingCapacity: true); eventSize = 0 }
            guard !dataLines.isEmpty else { return nil }
            return Data(dataLines.joined(separator: "\n").utf8)
        }
        // Ignore comments, event names, IDs and retry hints. JSON's own type
        // field is authoritative for the Responses accumulator.
        let fieldEnd = text.firstIndex(of: ":") ?? text.endIndex
        guard text[..<fieldEnd] == "data" else { return nil }
        var value = fieldEnd == text.endIndex ? "" : String(text[text.index(after: fieldEnd)...])
        if value.first == " " { value.removeFirst() }
        eventSize += value.utf8.count + 1
        guard eventSize <= maximumEventBytes else { throw ChatGPTError.invalidResponse }
        dataLines.append(value)
        return nil
    }
}

/// Safe transport metadata only. Never retain a prompt, response text, token,
/// account ID or complete server body in a diagnostic message.
struct ChatGPTTextDiagnostics {
    let status: Int
    let contentType: String?
    let requestID: String?
    let model: String
    var events = 0
    var lastEventType: String?

    private static func label(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "none" }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-/;= ")
        return String(value.filter { allowed.contains($0) }.prefix(100))
    }

    func summary(stage: String) -> String {
        "LLM-\(Self.label(stage)); HTTP=\(status); MIME=\(Self.label(contentType)); "
            + "events=\(events); last=\(Self.label(lastEventType)); "
            + "model=\(Self.label(model)); request=\(Self.label(requestID))"
    }
}

/// Accept only assistant output, and only after a completed Responses event.
struct ChatGPTResponseAccumulator {
    private(set) var text = ""
    private(set) var isComplete = false

    mutating func consume(_ data: Data) throws {
        guard let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let type = event["type"] as? String else { throw ChatGPTError.invalidResponse }
        switch type {
        case "response.output_text.delta":
            text += event["delta"] as? String ?? ""
        case "response.completed", "response.done":
            // The Codex terminal event is authoritative; its response envelope
            // can omit status (as in Codex's own response-completion fixtures).
            // An explicit non-success status or error must still fail closed.
            guard let response = event["response"] as? [String: Any] else {
                throw ChatGPTError.incompleteResponse
            }
            if let status = response["status"], !(status is NSNull), status as? String != "completed" {
                throw ChatGPTError.incompleteResponse
            }
            if let error = response["error"], !(error is NSNull) { throw ChatGPTError.incompleteResponse }
            let messages = (response["output"] as? [[String: Any]] ?? []).filter {
                $0["type"] as? String == "message" && $0["role"] as? String == "assistant"
            }
            let final = messages.flatMap { $0["content"] as? [[String: Any]] ?? [] }
                .filter { $0["type"] as? String == "output_text" }.compactMap { $0["text"] as? String }.joined()
            if !final.isEmpty { text = final }
            isComplete = true
        case "response.failed", "response.incomplete", "error": throw ChatGPTError.incompleteResponse
        default: break
        }
    }

    func result() throws -> String {
        guard isComplete, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ChatGPTError.incompleteResponse
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
