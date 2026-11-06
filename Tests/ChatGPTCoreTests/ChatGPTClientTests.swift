import Foundation
import XCTest
@testable import ChatGPTCore

private final class MemoryCredentials: ChatGPTCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var value: ChatGPTCredentials?
    init(_ value: ChatGPTCredentials) { self.value = value }
    func load() throws -> ChatGPTCredentials {
        try lock.withLock {
            guard let value else { throw ChatGPTError.signedOut }
            return value
        }
    }
    func save(_ credentials: ChatGPTCredentials) { lock.withLock { value = credentials } }
    func delete() { lock.withLock { value = nil } }
}

private final class MockChatGPTHTTP: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    static var contentType: String? = "application/json"
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: Self.contentType.map { ["Content-Type": $0] })!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class ChatGPTClientTests: XCTestCase {
    private func makeClient(expired: Bool = false) -> (ChatGPTClient, MemoryCredentials) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockChatGPTHTTP.self]
        let storage = MemoryCredentials(ChatGPTCredentials(
            accessToken: "test-token", refreshToken: "test-refresh", accountID: "test-account",
            expiresAt: Date().addingTimeInterval(expired ? -60 : 3600), email: nil))
        return (ChatGPTClient(session: URLSession(configuration: configuration), storage: storage), storage)
    }

    override func tearDown() {
        MockChatGPTHTTP.handler = nil
        MockChatGPTHTTP.contentType = "application/json"
        super.tearDown()
    }

    private func requestBody(_ request: URLRequest) throws -> [String: Any] {
        if let data = request.httpBody {
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count == 0 { break }
            guard count > 0 else { throw ChatGPTError.invalidResponse }
            data.append(contentsOf: buffer.prefix(count))
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testSelectedReasoningLevelsReachTheHTTPRequest() async throws {
        let (client, _) = makeClient()
        for effort in ChatGPTModelCatalog.supportedEfforts(for: "gpt-6.1-sol") {
            MockChatGPTHTTP.handler = { request in
                let body = try self.requestBody(request)
                XCTAssertEqual((body["reasoning"] as? [String: String])?["effort"], effort.rawValue)
                XCTAssertEqual(body["model"] as? String, "gpt-6.1-sol")
                XCTAssertEqual(body["store"] as? Bool, false)
                return (200, Data(#"data: {"type":"response.completed","response":{"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"OK"}]}]}}"#.utf8))
            }
            let text = try await client.enhance(input: [["role": "user", "content": "Test"]],
                instructions: "Test", model: "gpt-6.1-sol", timeout: 10, reasoningEffort: effort)
            XCTAssertEqual(text, "OK")
        }
    }

    func testExistingCallersStillSendLowReasoning() async throws {
        let (client, _) = makeClient()
        MockChatGPTHTTP.handler = { request in
            let body = try self.requestBody(request)
            XCTAssertEqual((body["reasoning"] as? [String: String])?["effort"], "low")
            return (200, Data(#"data: {"type":"response.completed","response":{"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"OK"}]}]}}"#.utf8))
        }
        _ = try await client.enhance(input: [], instructions: "Test", model: "gpt-6-luna", timeout: 10)
    }

    func testUnsupportedReasoningDoesNotSendARequest() async throws {
        let (client, _) = makeClient()
        MockChatGPTHTTP.handler = { _ in
            XCTFail("An unsupported model/effort combination must not be sent")
            return (500, Data())
        }
        do {
            _ = try await client.enhance(input: [], instructions: "Test", model: "gpt-6.1-sol", timeout: 10,
                                         reasoningEffort: .none)
            XCTFail("Expected an unsupported reasoning error")
        } catch ChatGPTError.unsupportedReasoningEffort {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testEnhancementDecodesMultipleSSEEvents() async throws {
        let (client, _) = makeClient()
        MockChatGPTHTTP.contentType = "text/event-stream"
        let events = [
            #"{"type":"response.created","response":{"status":"in_progress"}}"#,
            #"{"type":"response.output_text.delta","delta":"Grüße 👋"}"#,
            #"{"type":"response.completed","response":{"status":"completed","output":[]}}"#,
        ]
        let stream = events.map { "data: " + $0 + "\n\n" }.joined() + "data: [DONE]\n\n"
        MockChatGPTHTTP.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://chatgpt.com/backend-api/codex/responses")
            return (200, Data(stream.utf8))
        }
        let text = try await client.enhance(input: [["role": "user", "content": "Test"]],
                                            instructions: "Correct the text.", model: "gpt-6-luna", timeout: 10)
        XCTAssertEqual(text, "Grüße 👋")
    }

    func testEnhancementAcceptsLiveCodexSequenceWithoutContentType() async throws {
        let (client, _) = makeClient()
        MockChatGPTHTTP.contentType = nil
        // Same HTTP 200 / missing Content-Type and event ordering reported by
        // the user's live diagnostic. No credentials or real output are recorded.
        let events = [
            #"{"type":"response.created","response":{"status":"in_progress"}}"#,
            #"{"type":"response.in_progress"}"#,
            #"{"type":"response.output_item.added"}"#,
            #"{"type":"response.content_part.added"}"#,
            #"{"type":"response.output_text.delta","delta":"OK"}"#,
            #"{"type":"response.metadata","headers":{}}"#,
            #"{"type":"response.output_text.done","text":"OK"}"#,
            #"{"type":"response.content_part.done"}"#,
            #"{"type":"response.output_item.done"}"#,
            #"{"type":"response.completed","response":{"status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"OK"}]}]}}"#,
        ]
        let stream = events.map { "data: " + $0 + "\r\n\r\n" }.joined()
        MockChatGPTHTTP.handler = { _ in (200, Data(stream.utf8)) }
        let text = try await client.enhance(input: [["role": "user", "content": "Reply with exactly: OK"]],
                                            instructions: "Follow the user's instruction.", model: "gpt-6-luna", timeout: 10)
        XCTAssertEqual(text, "OK")
    }

    func testEnhancementValidatesSSEBodyDespiteIncorrectMIMELabel() async throws {
        let (client, _) = makeClient()
        MockChatGPTHTTP.contentType = "application/octet-stream"
        let event = #"{"type":"response.completed","response":{"status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"OK"}]}]}}"#
        MockChatGPTHTTP.handler = { _ in (200, Data(("data: " + event + "\n\n").utf8)) }
        let text = try await client.enhance(input: [["role": "user", "content": "Test"]],
                                            instructions: "Correct the text.", model: "gpt-6-luna", timeout: 10)
        XCTAssertEqual(text, "OK")
    }

    func testHeaderlessCodexCompletionAtEOFWithNoStatus() async throws {
        let (client, _) = makeClient()
        MockChatGPTHTTP.contentType = nil
        let stream = #"data: {"type":"response.output_text.delta","delta":"OK"}"#
            + "\n\n" + #"data: {"type":"response.completed","response":{"id":"resp_test"}}"#
        MockChatGPTHTTP.handler = { _ in (200, Data(stream.utf8)) }
        let text = try await client.enhance(input: [["role": "user", "content": "Test"]],
                                            instructions: "Correct the text.", model: "gpt-6-luna", timeout: 10)
        XCTAssertEqual(text, "OK")
    }

    func testMalformedHeaderlessSSEReportsSafeDiagnostic() async throws {
        let (client, _) = makeClient()
        MockChatGPTHTTP.contentType = nil
        MockChatGPTHTTP.handler = { _ in (200, Data("data: PRIVATE_SERVER_BODY\n\n".utf8)) }
        do {
            _ = try await client.enhance(input: [["role": "user", "content": "PRIVATE_TRANSCRIPT"]],
                                         instructions: "Correct the text.", model: "gpt-6-luna", timeout: 10)
            XCTFail("Malformed events must not become model output")
        } catch ChatGPTError.textResponse(let details) {
            XCTAssertTrue(details.contains("LLM-event-json"))
            XCTAssertTrue(details.contains("HTTP=200"))
            XCTAssertTrue(details.contains("MIME=none"))
            XCTAssertTrue(details.contains("events=1"))
            for secret in ["PRIVATE_SERVER_BODY", "PRIVATE_TRANSCRIPT", "test-token", "test-account"] {
                XCTAssertFalse(details.contains(secret))
            }
        }
    }

    func testEnhancementDecodesCRLFEventsAndMultilineJSON() async throws {
        let (client, _) = makeClient()
        MockChatGPTHTTP.contentType = "text/event-stream; charset=utf-8"
        let stream = ": heartbeat\r\n\r\nevent: response.completed\r\ndata: {\"type\":\"response.completed\",\r\n"
            + "data: \"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"Korrigierter Text.\"}]}]}}\r\n\r\n"
        MockChatGPTHTTP.handler = { _ in (200, Data(stream.utf8)) }
        let text = try await client.enhance(input: [["role": "user", "content": "Test"]],
                                            instructions: "Correct the text.", model: "gpt-6-luna", timeout: 10)
        XCTAssertEqual(text, "Korrigierter Text.")
    }

    func testEnhancementRejectsIncompleteStream() async throws {
        let (client, _) = makeClient()
        MockChatGPTHTTP.contentType = "text/event-stream"
        let stream = #"data: {"type":"response.output_text.delta","delta":"partial"}"# + "\n\n"
        MockChatGPTHTTP.handler = { _ in (200, Data(stream.utf8)) }
        do {
            _ = try await client.enhance(input: [["role": "user", "content": "Test"]],
                                         instructions: "Correct the text.", model: "gpt-6-luna", timeout: 10)
            XCTFail("Partial text must not be delivered")
        } catch ChatGPTError.textResponse(let details) {
            XCTAssertTrue(details.contains("LLM-missing-completion"))
        }
    }

    func testEnhancementRejectsUnexpectedResponseType() async throws {
        let (client, _) = makeClient()
        MockChatGPTHTTP.contentType = "text/html"
        MockChatGPTHTTP.handler = { _ in (200, Data("<html>Service unavailable</html>".utf8)) }
        do {
            _ = try await client.enhance(input: [["role": "user", "content": "Test"]],
                                         instructions: "Correct the text.", model: "gpt-6-luna", timeout: 10)
            XCTFail("HTML must not be treated as a model response")
        } catch ChatGPTError.textResponse(let details) {
            XCTAssertTrue(details.contains("MIME=text/html"))
            XCTAssertTrue(details.contains("events=0"))
            XCTAssertFalse(details.contains("Service unavailable"))
        }
    }

    func testAudioUsesSubscriptionCredentialAtFixedEndpoint() async throws {
        let (client, _) = makeClient()
        MockChatGPTHTTP.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://chatgpt.com/backend-api/transcribe")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "test-account")
            return (200, Data(#"{"text":"Hallo Welt"}"#.utf8))
        }
        let text = try await client.transcribe(audio: Data([1, 2]), fileName: "a.wav", language: nil, timeout: 10)
        XCTAssertEqual(text, "Hallo Welt")
    }

    func testForbiddenAndUsageLimitAreNotRetried() async throws {
        for status in [403, 429] {
            let (client, _) = makeClient()
            var calls = 0
            MockChatGPTHTTP.handler = { _ in calls += 1; return (status, Data()) }
            do {
                _ = try await client.transcribe(audio: Data([1]), fileName: "a.wav", language: nil, timeout: 10)
                XCTFail("Expected rejection")
            } catch ChatGPTError.rejected(let actual) { XCTAssertEqual(actual, status) }
            XCTAssertEqual(calls, 1)
        }
    }

    func testUnauthorizedRefreshesOnceAndPersistsRotation() async throws {
        let (client, storage) = makeClient()
        var calls = 0
        MockChatGPTHTTP.handler = { request in
            calls += 1
            switch calls {
            case 1: return (401, Data())
            case 2:
                XCTAssertEqual(request.url?.absoluteString, "https://auth.openai.com/oauth/token")
                return (200, Data(#"{"access_token":"renewed","refresh_token":"rotated","expires_in":3600}"#.utf8))
            default:
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer renewed")
                return (200, Data(#"{"text":"OK"}"#.utf8))
            }
        }
        let text = try await client.transcribe(audio: Data([1]), fileName: "a.wav", language: nil, timeout: 10)
        XCTAssertEqual(text, "OK")
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(try storage.load().refreshToken, "rotated")
    }

    func testSecondUnauthorizedDoesNotLoop() async throws {
        let (client, _) = makeClient()
        var calls = 0
        MockChatGPTHTTP.handler = { request in
            calls += 1
            if request.url?.host == "auth.openai.com" {
                return (200, Data(#"{"access_token":"renewed","expires_in":3600}"#.utf8))
            }
            return (401, Data())
        }
        do {
            _ = try await client.transcribe(audio: Data([1]), fileName: "a.wav", language: nil, timeout: 10)
            XCTFail("Expected rejection")
        } catch ChatGPTError.rejected(let status) { XCTAssertEqual(status, 401) }
        XCTAssertEqual(calls, 3)
    }

    func testSignOutPreventsRequestsAndRemovesCredentials() async throws {
        let (client, storage) = makeClient()
        MockChatGPTHTTP.handler = { _ in XCTFail("Signed-out client must not send audio"); return (500, Data()) }
        try await client.signOut()
        XCTAssertThrowsError(try storage.load())
        do {
            _ = try await client.transcribe(audio: Data([1]), fileName: "a.wav", language: nil, timeout: 10)
            XCTFail("Expected signed-out error")
        } catch ChatGPTError.signedOut {}
    }

    func testNativeDeviceLoginExchangesCodeAndSavesConnection() async throws {
        let (client, storage) = makeClient()
        var paths: [String] = []
        let claims: [String: Any] = ["exp": Date().addingTimeInterval(3600).timeIntervalSince1970,
                                    "https://api.openai.com/auth": ["chatgpt_account_id": "new-account"]]
        let payload = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let tokens = try JSONSerialization.data(withJSONObject: ["access_token": "h." + payload + ".s", "refresh_token": "new-refresh"])
        MockChatGPTHTTP.handler = { request in
            XCTAssertEqual(request.url?.host, "auth.openai.com")
            paths.append(request.url!.path)
            switch request.url!.path {
            case "/api/accounts/deviceauth/usercode":
                return (200, Data(#"{"device_auth_id":"attempt","user_code":"ABCD-EFGH","interval":"5"}"#.utf8))
            case "/api/accounts/deviceauth/token":
                return (200, Data(#"{"authorization_code":"code","code_verifier":"verifier","code_challenge":"challenge"}"#.utf8))
            default: return (200, tokens)
            }
        }
        let challenge = try await client.requestDeviceCode()
        try await client.completeSignIn(challenge)
        XCTAssertEqual(paths, ["/api/accounts/deviceauth/usercode", "/api/accounts/deviceauth/token", "/oauth/token"])
        XCTAssertEqual(try storage.load().accountID, "new-account")
        XCTAssertEqual(try storage.load().refreshToken, "new-refresh")
    }
}
