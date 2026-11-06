import Foundation
import XCTest
@testable import ChatGPTCore

final class ChatGPTProtocolTests: XCTestCase {
    func testModelCatalogAndSupportedReasoning() {
        XCTAssertEqual(Set(ChatGPTModelCatalog.all).count, 8)
        XCTAssertTrue(ChatGPTModelCatalog.current.contains("gpt-6.1-terra"))
        XCTAssertTrue(ChatGPTModelCatalog.earlier.contains("gpt-5.6-sol"))
        XCTAssertFalse(ChatGPTModelCatalog.supportedEfforts(for: "gpt-6.1-sol").contains(.none))
        XCTAssertFalse(ChatGPTModelCatalog.supportedEfforts(for: "gpt-6-astra").contains(.none))
        XCTAssertTrue(ChatGPTModelCatalog.supportedEfforts(for: "gpt-6-luna").contains(.none))
        XCTAssertEqual(ChatGPTModelCatalog.resolvedEffort(.none, for: "gpt-6.1-sol"), .low)
        XCTAssertEqual(ChatGPTModelCatalog.resolvedEffort(.medium, for: "gpt-6.1-sol"), .medium)
        XCTAssertEqual(ChatGPTModelCatalog.supportedEfforts(for: "future-model"), [.low, .medium, .high])
    }

    private func jwt(_ claims: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: claims)
        return "header." + data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") + ".signature"
    }

    func testTokenRotationKeepsRefreshTokenWhenOmitted() throws {
        let now = Date(timeIntervalSince1970: 1000)
        let old = ChatGPTCredentials(accessToken: "old", refreshToken: "refresh", accountID: "account",
                                    expiresAt: now, email: "test@example.invalid")
        let token = try jwt(["exp": 4000, "https://api.openai.com/auth": ["chatgpt_account_id": "account"]])
        let data = try JSONSerialization.data(withJSONObject: ["access_token": token])
        let credentials = try ChatGPTCredentials.decodeTokenResponse(data, previous: old, now: now)
        XCTAssertEqual(credentials.refreshToken, "refresh")
        XCTAssertEqual(credentials.accountID, "account")
        XCTAssertEqual(credentials.email, "test@example.invalid")
        XCTAssertEqual(credentials.expiresAt, Date(timeIntervalSince1970: 4000))
    }

    func testInitialLoginRejectsMissingAccountOrExpiration() throws {
        let cases: [[String: Any]] = [["exp": 4000], ["https://api.openai.com/auth": ["chatgpt_account_id": "account"]]]
        for claims in cases {
            let token = try jwt(claims)
            let data = try JSONSerialization.data(withJSONObject: ["access_token": token, "refresh_token": "refresh"])
            XCTAssertThrowsError(try ChatGPTCredentials.decodeTokenResponse(data, now: Date(timeIntervalSince1970: 1000)))
        }
    }

    func testDeviceCodeHandlesStringIntervalsAndLegacySpelling() throws {
        let data = Data(#"{"device_auth_id":"id","usercode":"ABCD-EFGH","interval":"5"}"#.utf8)
        let code = try ChatGPTDeviceCode(data: data, now: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(code.interval, 5)
        XCTAssertEqual(code.code, "ABCD-EFGH")
        XCTAssertEqual(code.expiresAt, Date(timeIntervalSince1970: 1900))
        XCTAssertThrowsError(try ChatGPTDeviceCode(data: Data(#"{"device_auth_id":"id"}"#.utf8)))
    }

    func testFormEncodingPreservesOAuthSpecialCharacters() {
        let data = ChatGPTProtocol.form(["code": "a+b&c=d /?"])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "code=a%2Bb%26c%3Dd%20%2F%3F")
    }

    func testMultipartPreservesAudioAndDoesNotTrustFilename() throws {
        let audio = Data([0, 1, 2, 255])
        let body = try ChatGPTProtocol.multipart(audio: audio, fileName: "secret\r\nname.wav", language: "de", boundary: "boundary")
        XCTAssertNotNil(body.range(of: audio))
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("filename=\"dictation.wav\""))
        XCTAssertTrue(text.contains("name=\"language\"\r\n\r\nde\r\n"))
        XCTAssertTrue(text.hasSuffix("--boundary--\r\n"))
        XCTAssertFalse(text.contains("secret"))
        XCTAssertThrowsError(try ChatGPTProtocol.multipart(audio: Data(), fileName: "a.wav", language: nil, boundary: "b"))
    }

    func testIncompleteStreamNeverReturnsPartialText() throws {
        var accumulator = ChatGPTResponseAccumulator()
        try accumulator.consume(Data(#"{"type":"response.output_text.delta","delta":"partial"}"#.utf8))
        XCTAssertThrowsError(try accumulator.result())
        XCTAssertThrowsError(try accumulator.consume(Data(#"{"type":"response.incomplete"}"#.utf8)))
    }

    func testCompletionUsesOnlyFinalAssistantOutput() throws {
        var accumulator = ChatGPTResponseAccumulator()
        try accumulator.consume(Data(#"{"type":"response.output_text.delta","delta":"draft"}"#.utf8))
        let event = #"{"type":"response.completed","response":{"status":"completed","output":[{"type":"reasoning","content":[{"type":"output_text","text":"hidden"}]},{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Corrected text."}]}]}}"#
        try accumulator.consume(Data(event.utf8))
        XCTAssertEqual(try accumulator.result(), "Corrected text.")
    }

    func testSSEFramingPreservesEventsWithEveryLineEnding() throws {
        for separator in ["\n", "\r\n", "\r"] {
            var decoder = ChatGPTEventStreamDecoder()
            let stream = "\u{FEFF}: keepalive" + separator + separator
                + "event: response.output_text.delta" + separator
                + #"data: {"type":"response.output_text.delta","delta":"Grüße 👋"}"# + separator + separator
                + "id: 2" + separator + "data: [DONE]" + separator + separator
            var events: [Data] = []
            // Individual bytes also split UTF-8 characters and CRLF pairs.
            for byte in stream.utf8 {
                if let event = try decoder.append(byte) { events.append(event) }
            }
            XCTAssertEqual(events.count, 2)
            var accumulator = ChatGPTResponseAccumulator()
            try accumulator.consume(events[0])
            XCTAssertEqual(accumulator.text, "Grüße 👋")
            XCTAssertEqual(events[1], Data("[DONE]".utf8))
        }
    }

    func testSSEMultilineDataAndComments() throws {
        var decoder = ChatGPTEventStreamDecoder()
        let stream = "data: {\"type\":\"response.output_text.delta\",\n: heartbeat\ndata: \"delta\":\"OK\"}\n\n"
        var events: [Data] = []
        for byte in stream.utf8 {
            if let event = try decoder.append(byte) { events.append(event) }
        }
        XCTAssertEqual(events.count, 1)
        var accumulator = ChatGPTResponseAccumulator()
        try accumulator.consume(events[0])
        XCTAssertEqual(accumulator.text, "OK")
    }

    func testUnterminatedSSEEventIsNotDispatched() throws {
        var decoder = ChatGPTEventStreamDecoder()
        let stream = #"data: {"type":"response.completed","response":{"status":"completed"}}"# + "\n"
        for byte in stream.utf8 { XCTAssertNil(try decoder.append(byte)) }
    }

    func testMalformedEventHasActionableProtocolError() {
        var accumulator = ChatGPTResponseAccumulator()
        XCTAssertThrowsError(try accumulator.consume(Data("not JSON".utf8))) { error in
            guard case ChatGPTError.invalidResponse = error else { return XCTFail("Expected protocol error, got \(error)") }
        }
    }

    func testCodexTerminalEventCanOmitRedundantStatus() throws {
        for type in ["response.completed", "response.done"] {
            var accumulator = ChatGPTResponseAccumulator()
            try accumulator.consume(Data(#"{"type":"response.output_text.delta","delta":"OK"}"#.utf8))
            let event = try JSONSerialization.data(withJSONObject: ["type": type, "response": ["id": "resp_test"]])
            try accumulator.consume(event)
            XCTAssertEqual(try accumulator.result(), "OK")
        }
    }

    func testCompletedEventWithExplicitFailureIsNeverAccepted() throws {
        let responses: [[String: Any]] = [
            ["status": "failed"], ["status": "incomplete"], ["status": "cancelled"],
            ["status": "in_progress"], ["error": ["code": "server_error"]],
        ]
        for response in responses {
            var accumulator = ChatGPTResponseAccumulator()
            try accumulator.consume(Data(#"{"type":"response.output_text.delta","delta":"partial"}"#.utf8))
            let event = try JSONSerialization.data(withJSONObject: ["type": "response.completed", "response": response])
            XCTAssertThrowsError(try accumulator.consume(event))
            XCTAssertThrowsError(try accumulator.result())
        }
    }
}
