import Foundation

public enum FeedbackType: String, CaseIterable, Identifiable, Sendable {
    case appWillNotOpen = "无法打开应用"
    case wifiNotRecognized = "无法识别 Wi-Fi"
    case inaccurateUsage = "用量显示不准确"
    case billing = "套餐或计费问题"
    case download = "网页或下载问题"
    case suggestion = "功能建议"
    case other = "其他问题"

    public var id: String { rawValue }
}

public struct FeedbackDiagnosticAttachment: Equatable, Sendable {
    public static let format = "wifiusage-log-v1"

    public let generatedAt: Date
    public let content: String

    public init(generatedAt: Date, content: String) {
        self.generatedAt = generatedAt
        self.content = content
    }
}

public struct FeedbackSubmission: Sendable {
    public let reportID: UUID
    public let type: FeedbackType
    public let message: String
    public let wantsReply: Bool
    public let contact: String
    public let system: String
    public let device: String
    public let appVersion: String
    public let appBuild: String
    public let diagnostics: FeedbackDiagnosticAttachment?

    public init(
        reportID: UUID,
        type: FeedbackType,
        message: String,
        wantsReply: Bool,
        contact: String,
        system: String,
        device: String,
        appVersion: String,
        appBuild: String,
        diagnostics: FeedbackDiagnosticAttachment?
    ) {
        self.reportID = reportID
        self.type = type
        self.message = message
        self.wantsReply = wantsReply
        self.contact = contact
        self.system = system
        self.device = device
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.diagnostics = diagnostics
    }
}

public struct FeedbackReceipt: Equatable, Sendable {
    public let feedbackID: String?
}

public struct FeedbackSystemProfile: Equatable, Sendable {
    public let system: String
    public let device: String
    public let appVersion: String
    public let appBuild: String

    public static func current(
        bundle: Bundle = .main,
        processInfo: ProcessInfo = .processInfo
    ) -> FeedbackSystemProfile {
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif

        let version = processInfo.operatingSystemVersion
        return FeedbackSystemProfile(
            system: "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            device: architecture,
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                ?? "unknown",
            appBuild: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
                ?? "unknown"
        )
    }
}

public enum FeedbackSubmissionError: LocalizedError, Equatable, Sendable {
    case invalidRequest(String)
    case requestTooLarge
    case noConnection
    case timedOut
    case rejected(statusCode: Int, code: String?, message: String?)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let message):
            message
        case .requestTooLarge:
            "诊断信息过大，请关闭日志附件后重试。"
        case .noConnection:
            "当前无法连接网络，请检查网络后重试。"
        case .timedOut:
            "发送超时，请稍后重试。"
        case .rejected(let statusCode, _, let message):
            if let message, !message.isEmpty {
                message
            } else if statusCode == 429 {
                "发送得有点频繁，请稍后再试。"
            } else {
                "反馈暂时没有发送成功，请稍后再试。"
            }
        case .invalidResponse:
            "反馈服务返回了无法识别的结果，请稍后再试。"
        }
    }
}

public struct FeedbackHTTPResponse: Sendable {
    public let statusCode: Int
    public let data: Data

    public init(statusCode: Int, data: Data) {
        self.statusCode = statusCode
        self.data = data
    }
}

public protocol FeedbackHTTPTransporting: Sendable {
    func send(_ request: URLRequest) async throws -> FeedbackHTTPResponse
}

public final class URLSessionFeedbackTransport: NSObject, FeedbackHTTPTransporting,
    URLSessionTaskDelegate, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private lazy var session = URLSession(
        configuration: configuration,
        delegate: self,
        delegateQueue: nil
    )

    public override init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        self.configuration = configuration
        super.init()
    }

    public func send(_ request: URLRequest) async throws -> FeedbackHTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw FeedbackSubmissionError.invalidResponse
        }
        return FeedbackHTTPResponse(statusCode: response.statusCode, data: data)
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

public struct AppFeedbackClient: Sendable {
    public static let endpoint = URL(string: "https://xjp.one/api/wifiusage/feedback")!
    public static let maximumDiagnosticsBytes = 32 * 1_024
    public static let maximumRequestBytes = 48 * 1_024

    private let endpointURL: URL
    private let transport: any FeedbackHTTPTransporting

    public init(
        endpointURL: URL = Self.endpoint,
        transport: any FeedbackHTTPTransporting = URLSessionFeedbackTransport()
    ) {
        self.endpointURL = endpointURL
        self.transport = transport
    }

    public func submit(_ submission: FeedbackSubmission) async throws -> FeedbackReceipt {
        let message = submission.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            throw FeedbackSubmissionError.invalidRequest("请填写问题描述。")
        }
        guard message.count <= 2_000 else {
            throw FeedbackSubmissionError.invalidRequest("问题描述不能超过 2000 个字。")
        }
        let contact = submission.contact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !submission.wantsReply || contact.count >= 3 else {
            throw FeedbackSubmissionError.invalidRequest("希望收到回复时，请留下有效联系方式。")
        }
        guard !submission.wantsReply || contact.count <= 160 else {
            throw FeedbackSubmissionError.invalidRequest("联系方式不能超过 160 个字。")
        }
        if let diagnostics = submission.diagnostics,
           diagnostics.content.utf8.count > Self.maximumDiagnosticsBytes {
            throw FeedbackSubmissionError.requestTooLarge
        }
        guard endpointURL == Self.endpoint else {
            throw FeedbackSubmissionError.invalidRequest("反馈地址无效。")
        }

        let payload = Payload(
            reportID: submission.reportID.uuidString.lowercased(),
            type: submission.type.rawValue,
            message: message,
            wantsReply: submission.wantsReply,
            contact: submission.wantsReply ? contact : nil,
            system: submission.system,
            device: submission.device,
            appVersion: submission.appVersion,
            appBuild: submission.appBuild,
            diagnostics: submission.diagnostics.map {
                Payload.Diagnostics(
                    generatedAt: ISO8601DateFormatter().string(from: $0.generatedAt),
                    format: FeedbackDiagnosticAttachment.format,
                    content: $0.content
                )
            }
        )

        let body = try JSONEncoder().encode(payload)
        guard body.count <= Self.maximumRequestBytes else {
            throw FeedbackSubmissionError.requestTooLarge
        }

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let response: FeedbackHTTPResponse
        do {
            response = try await transport.send(request)
        } catch let error as FeedbackSubmissionError {
            throw error
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
                 .cannotFindHost, .dnsLookupFailed:
                throw FeedbackSubmissionError.noConnection
            case .timedOut:
                throw FeedbackSubmissionError.timedOut
            default:
                throw FeedbackSubmissionError.invalidResponse
            }
        } catch {
            throw FeedbackSubmissionError.invalidResponse
        }

        let serverResult = try? JSONDecoder().decode(ServerResult.self, from: response.data)
        guard (200..<300).contains(response.statusCode) else {
            throw FeedbackSubmissionError.rejected(
                statusCode: response.statusCode,
                code: serverResult?.code,
                message: serverResult?.message
            )
        }
        guard let serverResult, serverResult.success else {
            throw FeedbackSubmissionError.invalidResponse
        }
        return FeedbackReceipt(feedbackID: serverResult.feedbackID)
    }

    private struct Payload: Encodable {
        let schemaVersion = 1
        let source = "mac-app"
        let reportID: String
        let type: String
        let message: String
        let wantsReply: Bool
        let contact: String?
        let system: String
        let device: String
        let appVersion: String
        let appBuild: String
        let includeDiagnostics: Bool
        let diagnostics: Diagnostics?

        init(
            reportID: String,
            type: String,
            message: String,
            wantsReply: Bool,
            contact: String?,
            system: String,
            device: String,
            appVersion: String,
            appBuild: String,
            diagnostics: Diagnostics?
        ) {
            self.reportID = reportID
            self.type = type
            self.message = message
            self.wantsReply = wantsReply
            self.contact = contact
            self.system = system
            self.device = device
            self.appVersion = appVersion
            self.appBuild = appBuild
            includeDiagnostics = diagnostics != nil
            self.diagnostics = diagnostics
        }

        struct Diagnostics: Encodable {
            let generatedAt: String
            let format: String
            let content: String
        }
    }

    private struct ServerResult: Decodable {
        let success: Bool
        let feedbackID: String?
        let code: String?
        let message: String?
    }
}
