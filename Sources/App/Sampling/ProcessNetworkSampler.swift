import Foundation
import SystemBridge
import UsageCore

public enum ApplicationSamplingMode: String, CaseIterable, Identifiable, Sendable {
    case balanced
    case precise

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .balanced: "低耗能"
        case .precise: "高精度（5 分钟）"
        }
    }

    public var detail: String {
        switch self {
        case .balanced:
            "节省电量，适合长期运行；非常短暂的联网可能少量遗漏。"
        case .precise:
            "临时提高记录频率，可捕捉更多短暂联网；5 分钟后自动回到低耗能模式。"
        }
    }
}

public enum ApplicationSamplingState: Equatable, Sendable {
    case stopped
    case starting
    case running
    case failed(String)
}

public enum ProcessNetworkSamplerError: LocalizedError, Sendable {
    case nettopUnavailable
    case commandFailed(Int32, String)
    case incompleteOutput

    public var errorDescription: String? {
        switch self {
        case .nettopUnavailable:
            return "应用用量统计在这台 Mac 上不可用。"
        case .commandFailed:
            return "应用用量统计暂时中断，正在自动重试。"
        case .incompleteOutput:
            return "本轮应用用量未能完整记录，正在自动重试。"
        }
    }
}

/// Entitlement-free application Wi-Fi sampler with balanced and precise modes.
public actor ProcessNetworkSampler {
    public typealias DeltaHandler = @Sendable ([ProcessNetworkDelta]) async -> Void
    public typealias StateHandler = @Sendable (ApplicationSamplingState) async -> Void

    private static let executableURL = URL(fileURLWithPath: "/usr/bin/nettop")

    private let mode: ApplicationSamplingMode
    private let pollingInterval: Duration
    private let excludedProcessIdentifier: Int32
    private let deltaHandler: DeltaHandler
    private let stateHandler: StateHandler
    private var tracker = ProcessNetworkDeltaTracker()
    private var samplingTask: Task<Void, Never>?
    private var publishedState: ApplicationSamplingState = .stopped

    public init(
        mode: ApplicationSamplingMode,
        pollingInterval: Duration = .seconds(2),
        excludedProcessIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier,
        deltaHandler: @escaping DeltaHandler,
        stateHandler: @escaping StateHandler
    ) {
        self.mode = mode
        self.pollingInterval = pollingInterval
        self.excludedProcessIdentifier = excludedProcessIdentifier
        self.deltaHandler = deltaHandler
        self.stateHandler = stateHandler
    }

    deinit {
        samplingTask?.cancel()
    }

    public func start() async {
        guard samplingTask == nil else { return }
        tracker.reset()
        await publish(.starting)
        samplingTask = Task { [weak self] in
            await self?.samplingLoop()
        }
    }

    public func stop() async {
        let task = samplingTask
        samplingTask = nil
        task?.cancel()
        await task?.value
        tracker.reset()
        await publish(.stopped)
    }

    private func samplingLoop() async {
        var consecutiveFailures = 0
        while !Task.isCancelled {
            var shouldBackOff = mode == .balanced
            do {
                let deltas = try sample()
                try Task.checkCancellation()
                await publish(.running)
                if !deltas.isEmpty {
                    await deltaHandler(deltas)
                }
                consecutiveFailures = 0
            } catch is CancellationError {
                break
            } catch {
                shouldBackOff = true
                consecutiveFailures += 1
                NSLog("WiFiUsage application sampler failed: %@", String(reflecting: error))
                await publish(.failed(error.localizedDescription))
            }

            guard shouldBackOff else { continue }
            do {
                let delay = consecutiveFailures == 0
                    ? pollingInterval
                    : Self.retryDelay(after: consecutiveFailures)
                try await Task.sleep(for: delay)
            } catch {
                break
            }
        }
    }

    private func sample() throws -> [ProcessNetworkDelta] {
        switch mode {
        case .balanced:
            let output = try Self.capture(arguments: Self.balancedArguments)
            let frames = ProcessNetworkSnapshotParser.parseFrames(output)
            guard frames.count == 1 else {
                throw ProcessNetworkSamplerError.incompleteOutput
            }
            let counters = try Self.validated(frames[0])
                .filter { $0.processIdentifier != excludedProcessIdentifier }
                .map(Self.attachingProcessStartTime)
            return tracker.observe(counters, at: Date())
        case .precise:
            let startedAt = Date()
            let output = try Self.capture(arguments: Self.preciseArguments)
            let endedAt = Date()
            let frames = ProcessNetworkSnapshotParser.parseFrames(output)
            guard frames.count == 2 else {
                throw ProcessNetworkSamplerError.incompleteOutput
            }
            return try Self.validated(frames[1]).compactMap { counter in
                guard counter.processIdentifier != excludedProcessIdentifier,
                      counter.bytes != .zero else {
                    return nil
                }
                return ProcessNetworkDelta(
                    processName: counter.processName,
                    processIdentifier: counter.processIdentifier,
                    startedAt: startedAt,
                    endedAt: endedAt,
                    bytes: counter.bytes
                )
            }
        }
    }

    private nonisolated static func validated(
        _ counters: [ProcessNetworkCounter]
    ) throws -> [ProcessNetworkCounter] {
        struct Key: Hashable {
            let name: String
            let identifier: Int32
        }
        var keys: Set<Key> = []
        for counter in counters {
            guard keys.insert(Key(
                name: counter.processName,
                identifier: counter.processIdentifier
            )).inserted else {
                throw ProcessNetworkSamplerError.incompleteOutput
            }
        }
        return counters
    }

    private nonisolated static func retryDelay(after failureCount: Int) -> Duration {
        switch failureCount {
        case ...1: .seconds(2)
        case 2: .seconds(5)
        case 3: .seconds(10)
        case 4: .seconds(30)
        default: .seconds(60)
        }
    }

    private func publish(_ state: ApplicationSamplingState) async {
        guard state != publishedState else { return }
        publishedState = state
        await stateHandler(state)
    }

    private nonisolated static func attachingProcessStartTime(
        to counter: ProcessNetworkCounter
    ) -> ProcessNetworkCounter {
        var parentIdentifier: Int32 = 0
        var startSeconds: Int64 = 0
        var startMicroseconds: Int32 = 0
        guard WUCopyProcessIdentity(
            counter.processIdentifier,
            &parentIdentifier,
            &startSeconds,
            &startMicroseconds
        ) == 0, startSeconds > 0 else {
            return counter
        }

        return ProcessNetworkCounter(
            processName: counter.processName,
            processIdentifier: counter.processIdentifier,
            processStartedAt: Date(
                timeIntervalSince1970: TimeInterval(startSeconds)
                    + TimeInterval(startMicroseconds) / 1_000_000
            ),
            bytes: counter.bytes
        )
    }

    private nonisolated static let balancedArguments = [
        "-L", "1",
        "-P",
        "-x",
        "-n",
        "-t", "wifi",
        "-J", "bytes_in,bytes_out"
    ]

    private nonisolated static let preciseArguments = [
        "-L", "2",
        "-s", "2",
        "-d",
        "-P",
        "-x",
        "-n",
        "-t", "wifi",
        "-J", "bytes_in,bytes_out"
    ]

    private nonisolated static func capture(arguments: [String]) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw ProcessNetworkSamplerError.nettopUnavailable
        }

        let process = Process()
        let output = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output

        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw ProcessNetworkSamplerError.commandFailed(process.terminationStatus, text)
        }
        return text
    }
}
