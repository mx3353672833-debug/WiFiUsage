import Darwin
import Foundation
import UsageCore

public struct IPConfigWiFiSummary: Equatable, Sendable {
    public let ssid: String?
    public let isWiFi: Bool
    public let isLinkActive: Bool

    public init(ssid: String?, isWiFi: Bool, isLinkActive: Bool) {
        self.ssid = WiFiNetworkName.normalize(ssid)
        self.isWiFi = isWiFi
        self.isLinkActive = isLinkActive
    }
}

public protocol IPConfigSSIDProviding: Sendable {
    func summary(for interfaceName: String) async -> IPConfigWiFiSummary?
}

public protocol IPConfigProcessRunning: Sendable {
    func run(interfaceName: String) async -> Data?
}

public enum IPConfigSummaryParser {
    public static func parse(_ data: Data) -> IPConfigWiFiSummary? {
        guard let output = String(data: data, encoding: .utf8) else { return nil }

        var depth = 0
        var sawRootDictionary = false
        var ssid: String?
        var interfaceType: String?
        var linkStatusActive: String?

        for rawLine in output.split(whereSeparator: { $0.isNewline }) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)

            if isContainerOpening(line) {
                depth += 1
                if depth == 1, line == "<dictionary> {" {
                    sawRootDictionary = true
                }
                continue
            }
            if line == "}" || line == "};" {
                depth = max(0, depth - 1)
                continue
            }
            guard sawRootDictionary, depth == 1,
                  let separator = line.firstIndex(of: ":") else {
                continue
            }

            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            let valueStart = line.index(after: separator)
            let value = line[valueStart...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "SSID":
                ssid = WiFiNetworkName.normalize(value)
            case "InterfaceType":
                interfaceType = value
            case "LinkStatusActive":
                linkStatusActive = value
            default:
                break
            }
        }

        guard sawRootDictionary else { return nil }
        return IPConfigWiFiSummary(
            ssid: ssid,
            isWiFi: interfaceType?.caseInsensitiveCompare("WiFi") == .orderedSame,
            isLinkActive: linkStatusActive?.caseInsensitiveCompare("TRUE") == .orderedSame
        )
    }

    private static func isContainerOpening(_ line: String) -> Bool {
        guard line.hasSuffix(" {") else { return false }
        let prefix = line.dropLast(2).trimmingCharacters(in: .whitespaces)
        return prefix == "<dictionary>"
            || prefix == "<array>"
            || prefix.hasSuffix(" : <dictionary>")
            || prefix.hasSuffix(" : <array>")
    }
}

public actor IPConfigSSIDProvider: IPConfigSSIDProviding {
    private struct CachedSummary: Sendable {
        let summary: IPConfigWiFiSummary?
        let resolvedAt: ContinuousClock.Instant
    }

    private static let cacheLifetime: Duration = .milliseconds(400)

    private let runner: any IPConfigProcessRunning
    private let clock = ContinuousClock()
    private var lookups: [String: Task<IPConfigWiFiSummary?, Never>] = [:]
    private var cachedSummaries: [String: CachedSummary] = [:]

    public init(runner: any IPConfigProcessRunning = IPConfigProcessRunner()) {
        self.runner = runner
    }

    public func summary(for interfaceName: String) async -> IPConfigWiFiSummary? {
        guard Self.isValidSystemInterface(interfaceName) else { return nil }
        let now = clock.now
        if let cached = cachedSummaries[interfaceName],
           cached.resolvedAt.duration(to: now) < Self.cacheLifetime {
            return cached.summary
        }
        if let existing = lookups[interfaceName] {
            return await existing.value
        }

        let runner = self.runner
        let lookup = Task<IPConfigWiFiSummary?, Never> {
            guard let data = await runner.run(interfaceName: interfaceName) else {
                return nil
            }
            return IPConfigSummaryParser.parse(data)
        }
        lookups[interfaceName] = lookup
        let result = await withTaskCancellationHandler {
            await lookup.value
        } onCancel: {
            lookup.cancel()
        }
        lookups[interfaceName] = nil
        if result?.ssid == nil {
            cachedSummaries[interfaceName] = CachedSummary(
                summary: result,
                resolvedAt: clock.now
            )
        } else {
            // Never retain an identified SSID after its lookup completes. A network
            // can switch on the same interface without an observable interface change.
            cachedSummaries[interfaceName] = nil
        }
        return result
    }

    private static func isValidSystemInterface(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count < Int(IFNAMSIZ) else { return false }
        return name.withCString { if_nametoindex($0) } != 0
    }
}

public struct IPConfigProcessRunner: IPConfigProcessRunning {
    public static let executableURL = URL(fileURLWithPath: "/usr/sbin/ipconfig")
    public static let maximumOutputBytes = 64 * 1_024
    public static let timeout: Duration = .seconds(1)

    public init() {}

    public static func arguments(for interfaceName: String) -> [String] {
        ["getsummary", interfaceName]
    }

    public func run(interfaceName: String) async -> Data? {
        guard Self.isValidInterfaceName(interfaceName) else { return nil }
        let execution = ProcessExecution(
            executableURL: Self.executableURL,
            arguments: Self.arguments(for: interfaceName),
            maximumOutputBytes: Self.maximumOutputBytes
        )
        return await withTaskCancellationHandler {
            await withTaskGroup(of: Data?.self) { group in
                group.addTask { await execution.run() }
                group.addTask {
                    do {
                        try await Task.sleep(for: Self.timeout)
                    } catch {
                        return nil
                    }
                    execution.cancel()
                    return nil
                }
                let result = await group.next() ?? nil
                group.cancelAll()
                execution.cancel()
                return result
            }
        } onCancel: {
            execution.cancel()
        }
    }

    private static func isValidInterfaceName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count < Int(IFNAMSIZ) else { return false }
        return name.withCString { if_nametoindex($0) } != 0
    }
}

private final class ProcessExecution: @unchecked Sendable {
    private let executableURL: URL
    private let arguments: [String]
    private let maximumOutputBytes: Int
    private let lock = NSLock()
    private var process: Process?
    private var continuation: CheckedContinuation<Data?, Never>?
    private var output = Data()
    private var didFinish = false
    private var exceededLimit = false
    private var reachedStandardOutputEOF = false
    private var terminationStatus: Int32?

    init(executableURL: URL, arguments: [String], maximumOutputBytes: Int) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.maximumOutputBytes = maximumOutputBytes
    }

    func run() async -> Data? {
        await withCheckedContinuation { continuation in
            let process = Process()
            let stdout = Pipe()
            process.executableURL = executableURL
            process.arguments = arguments
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice

            lock.lock()
            guard !didFinish else {
                lock.unlock()
                continuation.resume(returning: nil)
                return
            }
            self.process = process
            self.continuation = continuation
            lock.unlock()

            stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    self?.markStandardOutputEOF()
                } else {
                    self?.append(data)
                }
            }
            process.terminationHandler = { [weak self] process in
                self?.markTerminated(status: process.terminationStatus)
            }

            lock.lock()
            guard !didFinish else {
                lock.unlock()
                stdout.fileHandleForReading.readabilityHandler = nil
                return
            }
            do {
                try process.run()
                stdout.fileHandleForWriting.closeFile()
                lock.unlock()
            } catch {
                lock.unlock()
                stdout.fileHandleForReading.readabilityHandler = nil
                stdout.fileHandleForWriting.closeFile()
                fail()
            }
        }
    }

    func cancel() {
        lock.lock()
        let process = self.process
        let continuation = takeContinuationLocked()
        lock.unlock()
        if process?.isRunning == true { process?.terminate() }
        continuation?.resume(returning: nil)
    }

    private func append(_ data: Data) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        if data.count > maximumOutputBytes || output.count > maximumOutputBytes - data.count {
            exceededLimit = true
            let process = self.process
            let continuation = takeContinuationLocked()
            lock.unlock()
            if process?.isRunning == true { process?.terminate() }
            continuation?.resume(returning: nil)
            return
        }
        output.append(data)
        lock.unlock()
    }

    private func markStandardOutputEOF() {
        lock.lock()
        reachedStandardOutputEOF = true
        let completion = completionIfReadyLocked()
        lock.unlock()
        if let completion {
            completion.continuation.resume(returning: completion.result)
        }
    }

    private func markTerminated(status: Int32) {
        lock.lock()
        terminationStatus = status
        let completion = completionIfReadyLocked()
        lock.unlock()
        if let completion {
            completion.continuation.resume(returning: completion.result)
        }
    }

    private func fail() {
        lock.lock()
        let continuation = takeContinuationLocked()
        lock.unlock()
        continuation?.resume(returning: nil)
    }

    private func completionIfReadyLocked() -> (
        continuation: CheckedContinuation<Data?, Never>,
        result: Data?
    )? {
        guard reachedStandardOutputEOF, let terminationStatus else { return nil }
        let result = terminationStatus == 0 && !exceededLimit ? output : nil
        guard let continuation = takeContinuationLocked() else { return nil }
        return (continuation, result)
    }

    private func takeContinuationLocked() -> CheckedContinuation<Data?, Never>? {
        guard !didFinish else { return nil }
        didFinish = true
        let continuation = self.continuation
        self.continuation = nil
        process = nil
        return continuation
    }
}
