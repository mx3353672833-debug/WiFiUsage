import Foundation
import XCTest
@testable import WiFiUsage

final class AppFeedbackClientTests: XCTestCase {
    func testSubmissionOmitsContactAndDiagnosticsWithoutConsent() async throws {
        let transport = FeedbackTransportSpy(
            response: FeedbackHTTPResponse(
                statusCode: 202,
                data: Data(#"{"success":true,"feedbackID":"feedback-1"}"#.utf8)
            )
        )
        let client = AppFeedbackClient(transport: transport)

        let receipt = try await client.submit(makeSubmission(
            wantsReply: false,
            contact: "private@example.com",
            diagnostics: nil
        ))

        XCTAssertEqual(receipt.feedbackID, "feedback-1")
        let capturedRequest = await transport.lastRequest()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.url, AppFeedbackClient.endpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let payload = try jsonObject(request)
        XCTAssertEqual(payload["source"] as? String, "mac-app")
        XCTAssertEqual(payload["includeDiagnostics"] as? Bool, false)
        XCTAssertNil(payload["diagnostics"])
        XCTAssertNil(payload["contact"])
        XCTAssertNil(request.value(forHTTPHeaderField: "Origin"))
    }

    func testSubmissionIncludesExactlyPreparedDiagnostics() async throws {
        let transport = FeedbackTransportSpy(
            response: FeedbackHTTPResponse(statusCode: 202, data: Data(#"{"success":true}"#.utf8))
        )
        let client = AppFeedbackClient(transport: transport)
        let content = "format=wifiusage-log-v1\nevent=wifi.resolve.failed\n"
        let generatedAt = Date(timeIntervalSince1970: 1_800_000_000)

        _ = try await client.submit(makeSubmission(
            wantsReply: true,
            contact: "reply@example.com",
            diagnostics: FeedbackDiagnosticAttachment(generatedAt: generatedAt, content: content)
        ))

        let capturedRequest = await transport.lastRequest()
        let request = try XCTUnwrap(capturedRequest)
        let payload = try jsonObject(request)
        XCTAssertEqual(payload["includeDiagnostics"] as? Bool, true)
        XCTAssertEqual(payload["contact"] as? String, "reply@example.com")
        let diagnostics = try XCTUnwrap(payload["diagnostics"] as? [String: Any])
        XCTAssertEqual(diagnostics["format"] as? String, FeedbackDiagnosticAttachment.format)
        XCTAssertEqual(diagnostics["content"] as? String, content)
        XCTAssertNotNil(diagnostics["generatedAt"] as? String)
    }

    func testServerErrorUsesSafeMessage() async {
        let transport = FeedbackTransportSpy(
            response: FeedbackHTTPResponse(
                statusCode: 429,
                data: Data(#"{"success":false,"code":"rate_limited","message":"发送得有点频繁，请稍后再试。"}"#.utf8)
            )
        )
        let client = AppFeedbackClient(transport: transport)

        do {
            _ = try await client.submit(makeSubmission())
            XCTFail("Expected rejection")
        } catch let error as FeedbackSubmissionError {
            XCTAssertEqual(
                error,
                .rejected(
                    statusCode: 429,
                    code: "rate_limited",
                    message: "发送得有点频繁，请稍后再试。"
                )
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testOversizedRequestIsRejectedBeforeTransport() async {
        let transport = FeedbackTransportSpy(
            response: FeedbackHTTPResponse(statusCode: 202, data: Data(#"{"success":true}"#.utf8))
        )
        let client = AppFeedbackClient(transport: transport)
        let oversized = FeedbackDiagnosticAttachment(
            generatedAt: Date(),
            content: String(repeating: "诊", count: 20_000)
        )

        do {
            _ = try await client.submit(makeSubmission(diagnostics: oversized))
            XCTFail("Expected size rejection")
        } catch let error as FeedbackSubmissionError {
            XCTAssertEqual(error, .requestTooLarge)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let capturedRequest = await transport.lastRequest()
        XCTAssertNil(capturedRequest)
    }

    func testEmptyMessageAndMissingReplyContactAreRejectedLocally() async {
        let transport = FeedbackTransportSpy(
            response: FeedbackHTTPResponse(statusCode: 202, data: Data(#"{"success":true}"#.utf8))
        )
        let client = AppFeedbackClient(transport: transport)

        do {
            _ = try await client.submit(makeSubmission(message: "  \n"))
            XCTFail("Expected validation error")
        } catch let error as FeedbackSubmissionError {
            XCTAssertEqual(error, .invalidRequest("请填写问题描述。"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        do {
            _ = try await client.submit(makeSubmission(wantsReply: true, contact: ""))
            XCTFail("Expected contact validation error")
        } catch let error as FeedbackSubmissionError {
            XCTAssertEqual(error, .invalidRequest("希望收到回复时，请留下有效联系方式。"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeSubmission(
        message: String = "切换 Wi-Fi 后没有自动识别",
        wantsReply: Bool = false,
        contact: String = "",
        diagnostics: FeedbackDiagnosticAttachment? = nil
    ) -> FeedbackSubmission {
        FeedbackSubmission(
            reportID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            type: .wifiNotRecognized,
            message: message,
            wantsReply: wantsReply,
            contact: contact,
            system: "macOS 26.5.2",
            device: "arm64",
            appVersion: "1.1.0",
            appBuild: "2",
            diagnostics: diagnostics
        )
    }

    private func jsonObject(_ request: URLRequest) throws -> [String: Any] {
        let body = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
    }
}

private actor FeedbackTransportSpy: FeedbackHTTPTransporting {
    private let response: FeedbackHTTPResponse
    private var requests: [URLRequest] = []

    init(response: FeedbackHTTPResponse) {
        self.response = response
    }

    func send(_ request: URLRequest) async throws -> FeedbackHTTPResponse {
        requests.append(request)
        return response
    }

    func lastRequest() -> URLRequest? {
        requests.last
    }
}
