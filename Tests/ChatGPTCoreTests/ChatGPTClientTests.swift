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
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
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

    override func tearDown() { MockChatGPTHTTP.handler = nil; super.tearDown() }

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
