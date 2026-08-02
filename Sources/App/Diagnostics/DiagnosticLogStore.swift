import Foundation

public enum DiagnosticLogLevel: String, Codable, Sendable {
    case info
    case warning
    case error
}

public enum DiagnosticEventCode: String, Codable, Sendable {
    case appLaunch = "app.launch"
    case databaseOpenSucceeded = "database.open.succeeded"
    case databaseOpenFailed = "database.open.failed"
    case dataRefreshFailed = "database.refresh.failed"
    case databaseWriteFailed = "database.write.failed"
    case wifiResolutionChanged = "wifi.resolve.changed"
    case physicalSamplerStarted = "wifi.sampler.started"
    case physicalSamplerFailed = "wifi.sampler.failed"
    case applicationSamplerStarted = "application_sampler.started"
    case applicationSamplerRunning = "application_sampler.running"
    case applicationSamplerStopped = "application_sampler.stopped"
    case applicationSamplerFailed = "application_sampler.failed"
    case applicationUsageSaveFailed = "application_sampler.save.failed"
    case planAssignmentFailed = "plan.assignment.failed"
    case planSaveFailed = "plan.save.failed"
    case loginItemUpdateFailed = "login_item.update.failed"
    case legacyImportFailed = "database.legacy_import.failed"
    case feedbackSendStarted = "feedback.send.started"
    case feedbackSendSucceeded = "feedback.send.succeeded"
    case feedbackSendFailed = "feedback.send.failed"
    case logsCleared = "diagnostics.logs.cleared"
}

public enum DiagnosticErrorDomain: String, Codable, Sendable {
    case sqlite
    case interfaceCounters = "interface_counters"
    case processSampler = "process_sampler"
    case launchAtLogin = "launch_at_login"
    case feedbackNetwork = "feedback_network"
    case filesystem
    case unknown
}

public enum DiagnosticWiFiResolutionSource: String, Codable, Sendable {
    case none
    case coreWLAN = "corewlan"
    case ipconfig
}

public enum DiagnosticApplicationFailureKind: String, Codable, Sendable {
    case unavailable
    case commandFailed = "command_failed"
    case incompleteOutput = "incomplete_output"
    case unknown
}

public struct DiagnosticEventMetadata: Codable, Equatable, Sendable {
    public var errorDomain: DiagnosticErrorDomain?
    public var numericCode: Int64?
    public var retryCount: Int?
    public var connected: Bool?
    public var wifiNameIdentified: Bool?
    public var wifiResolutionSource: DiagnosticWiFiResolutionSource?
    public var applicationFailureKind: DiagnosticApplicationFailureKind?
    public var preciseMode: Bool?
    public var diagnosticsIncluded: Bool?
    public var httpStatusClass: Int?

    public init(
        errorDomain: DiagnosticErrorDomain? = nil,
        numericCode: Int64? = nil,
        retryCount: Int? = nil,
        connected: Bool? = nil,
        wifiNameIdentified: Bool? = nil,
        wifiResolutionSource: DiagnosticWiFiResolutionSource? = nil,
        applicationFailureKind: DiagnosticApplicationFailureKind? = nil,
        preciseMode: Bool? = nil,
        diagnosticsIncluded: Bool? = nil,
        httpStatusClass: Int? = nil
    ) {
        self.errorDomain = errorDomain
        self.numericCode = numericCode
        self.retryCount = retryCount
        self.connected = connected
        self.wifiNameIdentified = wifiNameIdentified
        self.wifiResolutionSource = wifiResolutionSource
        self.applicationFailureKind = applicationFailureKind
        self.preciseMode = preciseMode
        self.diagnosticsIncluded = diagnosticsIncluded
        self.httpStatusClass = httpStatusClass
    }
}

public enum DiagnosticWiFiState: String, Sendable {
    case disconnected
    case connectedWithoutName = "connected_without_name"
    case identified
}

public struct DiagnosticReportContext: Equatable, Sendable {
    public let appVersion: String
    public let appBuild: String
    public let distribution: String
    public let operatingSystemVersion: String
    public let architecture: String
    public let repositoryReady: Bool
    public let wifiState: DiagnosticWiFiState
    public let physicalSamplingActive: Bool
    public let applicationSamplingState: String

    public init(
        appVersion: String,
        appBuild: String,
        distribution: String,
        operatingSystemVersion: String,
        architecture: String,
        repositoryReady: Bool,
        wifiState: DiagnosticWiFiState,
        physicalSamplingActive: Bool,
        applicationSamplingState: String
    ) {
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.distribution = distribution
        self.operatingSystemVersion = operatingSystemVersion
        self.architecture = architecture
        self.repositoryReady = repositoryReady
        self.wifiState = wifiState
        self.physicalSamplingActive = physicalSamplingActive
        self.applicationSamplingState = applicationSamplingState
    }
}

public actor DiagnosticLogStore {
    public static let maximumFileBytes = 1 * 1_024 * 1_024
    public static let maximumFileCount = 5
    public static let maximumExportBytes = 32 * 1_024
    public static let retentionInterval: TimeInterval = 7 * 24 * 60 * 60
    public static let exportInterval: TimeInterval = 24 * 60 * 60

    public nonisolated let directoryURL: URL

    private let currentLogURL: URL
    private let maximumFileBytes: Int
    private let maximumFileCount: Int
    private let retentionInterval: TimeInterval
    private let duplicateWindow: TimeInterval
    private var recentEvents: [String: RecentEvent] = [:]
    private var lastPrunedAt: Date?

    public init(
        directoryURL: URL,
        maximumFileBytes: Int = DiagnosticLogStore.maximumFileBytes,
        maximumFileCount: Int = DiagnosticLogStore.maximumFileCount,
        retentionInterval: TimeInterval = DiagnosticLogStore.retentionInterval,
        duplicateWindow: TimeInterval = 30
    ) {
        self.directoryURL = directoryURL
        currentLogURL = directoryURL.appendingPathComponent("wifiusage.log", isDirectory: false)
        self.maximumFileBytes = max(512, maximumFileBytes)
        self.maximumFileCount = max(1, min(maximumFileCount, 20))
        self.retentionInterval = max(60, retentionInterval)
        self.duplicateWindow = max(1, duplicateWindow)
    }

    public static func defaultDirectory(applicationSupportDirectoryName: String) -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent(applicationSupportDirectoryName, isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
    }

    public func ensureDirectory() {
        do {
            try prepareDirectory()
        } catch {
            NSLog("WiFiUsage diagnostics.directory.failed")
        }
    }

    public func record(
        _ event: DiagnosticEventCode,
        level: DiagnosticLogLevel = .info,
        metadata: DiagnosticEventMetadata = DiagnosticEventMetadata(),
        at date: Date = Date()
    ) {
        let fingerprint = Self.fingerprint(event: event, level: level, metadata: metadata)
        if var recent = recentEvents[fingerprint],
           date.timeIntervalSince(recent.lastSeenAt) < duplicateWindow {
            recent.lastSeenAt = date
            recent.suppressedCount += 1
            recentEvents[fingerprint] = recent
            return
        }

        var repeatCount = 1
        if let recent = recentEvents[fingerprint] {
            repeatCount += recent.suppressedCount
        }
        recentEvents[fingerprint] = RecentEvent(lastSeenAt: date, suppressedCount: 0)
        trimRecentEventsIfNeeded()

        append(LogEntry(
            timestamp: date,
            level: level,
            event: event,
            metadata: metadata,
            repeatCount: repeatCount
        ))
    }

    public func clear() {
        recentEvents.removeAll()
        lastPrunedAt = nil
        do {
            if FileManager.default.fileExists(atPath: directoryURL.path) {
                for url in try FileManager.default.contentsOfDirectory(
                    at: directoryURL,
                    includingPropertiesForKeys: nil,
                    options: []
                ) where Self.isManagedLog(url) || Self.isManagedTemporaryFile(url) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        } catch {
            NSLog("WiFiUsage diagnostics.clear.failed")
        }
    }

    public func export(
        context: DiagnosticReportContext,
        generatedAt: Date = Date(),
        maximumBytes: Int = DiagnosticLogStore.maximumExportBytes
    ) -> String {
        flushSuppressedEvents(at: generatedAt)
        pruneExpiredLogs(now: Date(), force: true)

        let limit = max(2_048, min(maximumBytes, Self.maximumExportBytes))
        let cutoff = generatedAt.addingTimeInterval(-Self.exportInterval)
        let entries = loadEntries()
            .filter { $0.timestamp >= cutoff && $0.timestamp <= generatedAt.addingTimeInterval(60) }
            .sorted { $0.timestamp < $1.timestamp }
            .suffix(1_000)
        let header = reportHeader(context: context, generatedAt: generatedAt)
        let encoder = Self.makeEncoder()
        var selected: [String] = []
        var usedBytes = header.utf8.count + "\nevents:\n".utf8.count
        var truncated = false

        for entry in entries.reversed() {
            guard let data = try? encoder.encode(entry),
                  var line = String(data: data, encoding: .utf8) else {
                continue
            }
            line = Self.redact(line)
            let lineBytes = line.utf8.count + 1
            if usedBytes + lineBytes > limit - 64 {
                truncated = true
                continue
            }
            selected.append(line)
            usedBytes += lineBytes
        }

        if selected.count < entries.count { truncated = true }
        let body = selected.reversed().joined(separator: "\n")
        let truncationLine = "\ntruncated=\(truncated ? "true" : "false")"
        var report = header + "\nevents:\n" + (body.isEmpty ? "none" : body) + truncationLine + "\n"
        while report.utf8.count > limit, !selected.isEmpty {
            selected.removeLast()
            let reducedBody = selected.reversed().joined(separator: "\n")
            report = header + "\nevents:\n" + (reducedBody.isEmpty ? "none" : reducedBody)
                + "\ntruncated=true\n"
        }
        return Self.redact(report)
    }

    private func append(_ entry: LogEntry) {
        do {
            try prepareDirectory()
            pruneExpiredLogs(now: Date())
            let encoder = Self.makeEncoder()
            var data = try encoder.encode(entry)
            data.append(0x0A)
            try rotateIfNeeded(addingBytes: data.count)
            if !FileManager.default.fileExists(atPath: currentLogURL.path) {
                guard FileManager.default.createFile(
                    atPath: currentLogURL.path,
                    contents: nil,
                    attributes: [.posixPermissions: 0o600]
                ) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: currentLogURL.path
            )
            let handle = try FileHandle(forWritingTo: currentLogURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            NSLog("WiFiUsage diagnostics.write.failed")
        }
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directoryURL
        try? mutableDirectory.setResourceValues(values)
        removeManagedTemporaryFiles()
    }

    private func rotateIfNeeded(addingBytes: Int) throws {
        let attributes = try? FileManager.default.attributesOfItem(atPath: currentLogURL.path)
        let currentSize = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard currentSize + addingBytes > maximumFileBytes else { return }

        if maximumFileCount == 1 {
            try? FileManager.default.removeItem(at: currentLogURL)
            return
        }

        let oldest = archiveURL(index: maximumFileCount - 1)
        try? FileManager.default.removeItem(at: oldest)
        if maximumFileCount > 2 {
            for index in stride(from: maximumFileCount - 2, through: 1, by: -1) {
                let source = archiveURL(index: index)
                let destination = archiveURL(index: index + 1)
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: source, to: destination)
            }
        }
        if FileManager.default.fileExists(atPath: currentLogURL.path) {
            let firstArchive = archiveURL(index: 1)
            try? FileManager.default.removeItem(at: firstArchive)
            try FileManager.default.moveItem(at: currentLogURL, to: firstArchive)
        }
    }

    private func pruneExpiredLogs(now: Date, force: Bool = false) {
        if let lastPrunedAt {
            let elapsed = now.timeIntervalSince(lastPrunedAt)
            if !force, elapsed >= 0, elapsed < 60 * 60 { return }
        }
        lastPrunedAt = now
        guard FileManager.default.fileExists(atPath: directoryURL.path) else { return }
        let cutoff = now.addingTimeInterval(-retentionInterval)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return }
        for url in urls where Self.isManagedTemporaryFile(url) {
            try? FileManager.default.removeItem(at: url)
        }
        for url in urls where Self.isManagedLog(url) {
            guard let source = try? Data(contentsOf: url) else { continue }
            let lines = source.split(separator: 0x0A)
            let decoder = Self.makeDecoder()
            let retained = lines.compactMap { line -> Data? in
                let data = Data(line)
                guard let entry = try? decoder.decode(LogEntry.self, from: data),
                      entry.timestamp >= cutoff else {
                    return nil
                }
                return data
            }
            if retained.isEmpty {
                try? FileManager.default.removeItem(at: url)
            } else if retained.count != lines.count {
                var compacted = Data()
                for line in retained {
                    compacted.append(line)
                    compacted.append(0x0A)
                }
                try? replaceManagedLog(at: url, with: compacted)
            }
        }
    }

    private func replaceManagedLog(at url: URL, with data: Data) throws {
        let temporaryURL = directoryURL.appendingPathComponent(
            ".wifiusage-prune-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        guard FileManager.default.createFile(
            atPath: temporaryURL.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporaryURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private func removeManagedTemporaryFiles() {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return }
        for url in urls where Self.isManagedTemporaryFile(url) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func loadEntries() -> [LogEntry] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let decoder = Self.makeDecoder()
        var entries: [LogEntry] = []
        for url in urls.filter(Self.isManagedLog) {
            guard let data = try? Data(contentsOf: url) else { continue }
            for line in data.split(separator: 0x0A) {
                guard let entry = try? decoder.decode(LogEntry.self, from: Data(line)) else { continue }
                entries.append(entry)
            }
        }
        return entries
    }

    private func flushSuppressedEvents(at date: Date) {
        for (fingerprint, recent) in recentEvents where recent.suppressedCount > 0 {
            guard let decoded = Self.decodeFingerprint(fingerprint) else { continue }
            append(LogEntry(
                timestamp: min(date, recent.lastSeenAt),
                level: decoded.level,
                event: decoded.event,
                metadata: decoded.metadata,
                repeatCount: recent.suppressedCount
            ))
            recentEvents[fingerprint] = RecentEvent(lastSeenAt: recent.lastSeenAt, suppressedCount: 0)
        }
    }

    private func trimRecentEventsIfNeeded() {
        guard recentEvents.count > 128,
              let oldest = recentEvents.min(by: { $0.value.lastSeenAt < $1.value.lastSeenAt }) else {
            return
        }
        recentEvents.removeValue(forKey: oldest.key)
    }

    private func reportHeader(context: DiagnosticReportContext, generatedAt: Date) -> String {
        let formatter = ISO8601DateFormatter()
        let pairs = [
            "format=wifiusage-log-v1",
            "generated_at=\(formatter.string(from: generatedAt))",
            "app_version=\(Self.redact(context.appVersion))",
            "app_build=\(Self.redact(context.appBuild))",
            "distribution=\(Self.redact(context.distribution))",
            "os_version=\(Self.redact(context.operatingSystemVersion))",
            "architecture=\(Self.redact(context.architecture))",
            "repository_ready=\(context.repositoryReady)",
            "wifi_state=\(context.wifiState.rawValue)",
            "physical_sampling=\(context.physicalSamplingActive)",
            "application_sampling=\(Self.redact(context.applicationSamplingState))",
            "privacy=sensitive_names,paths,traffic,plans,contact_not_collected",
        ]
        return pairs.joined(separator: "\n")
    }

    private func archiveURL(index: Int) -> URL {
        directoryURL.appendingPathComponent("wifiusage.\(index).log", isDirectory: false)
    }

    private static func isManagedLog(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if name == "wifiusage.log" { return true }
        guard name.hasPrefix("wifiusage."), name.hasSuffix(".log") else { return false }
        let start = name.index(name.startIndex, offsetBy: "wifiusage.".count)
        let end = name.index(name.endIndex, offsetBy: -".log".count)
        return Int(name[start..<end]) != nil
    }

    private static func isManagedTemporaryFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        let prefix = ".wifiusage-prune-"
        let suffix = ".tmp"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return false }
        let start = name.index(name.startIndex, offsetBy: prefix.count)
        let end = name.index(name.endIndex, offsetBy: -suffix.count)
        return UUID(uuidString: String(name[start..<end])) != nil
    }

    private static func fingerprint(
        event: DiagnosticEventCode,
        level: DiagnosticLogLevel,
        metadata: DiagnosticEventMetadata
    ) -> String {
        let encoder = makeEncoder()
        let metadataData = (try? encoder.encode(metadata)) ?? Data()
        return [level.rawValue, event.rawValue, metadataData.base64EncodedString()].joined(separator: "|")
    }

    private static func decodeFingerprint(
        _ fingerprint: String
    ) -> (level: DiagnosticLogLevel, event: DiagnosticEventCode, metadata: DiagnosticEventMetadata)? {
        let parts = fingerprint.split(separator: "|", maxSplits: 2).map(String.init)
        guard parts.count == 3,
              let level = DiagnosticLogLevel(rawValue: parts[0]),
              let event = DiagnosticEventCode(rawValue: parts[1]),
              let data = Data(base64Encoded: parts[2]),
              let metadata = try? makeDecoder().decode(DiagnosticEventMetadata.self, from: data) else {
            return nil
        }
        return (level, event, metadata)
    }

    private static func redact(_ value: String) -> String {
        let patterns: [(String, String)] = [
            (#"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#, "<redacted-email>"),
            (#"/(?:Users|home)/[^/\s]+"#, "~"),
            (#"(?i)\bhttps?://[^\s<>\"']+"#, "<redacted-url>"),
            (#"(?i)\b(?:SSID|BSSID)\s*[:=]\s*[^\r\n,}]+"#, "SSID=<redacted>"),
            (#"(?i)\b(?:DEVELOPMENT_TEAM|TeamIdentifier|Authority)\s*[:=]\s*[^\r\n,}]+"#, "signing=<redacted>"),
            (#"\b(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}\b"#, "<redacted-mac>"),
            (#"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b"#, "<redacted-uuid>"),
            (#"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, "<redacted-ip>"),
        ]
        var result = value
        for (pattern, replacement) in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            result = expression.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: replacement
            )
        }
        return result
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private struct RecentEvent {
        var lastSeenAt: Date
        var suppressedCount: Int
    }

    private struct LogEntry: Codable {
        let timestamp: Date
        let level: DiagnosticLogLevel
        let event: DiagnosticEventCode
        let metadata: DiagnosticEventMetadata
        let repeatCount: Int
    }
}
