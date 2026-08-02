import Foundation
import XCTest
@testable import WiFiUsage

final class DiagnosticLogStoreTests: XCTestCase {
    func testWritesStructuredLogWithPrivatePermissions() async throws {
        let directory = temporaryDirectory("permissions")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DiagnosticLogStore(directoryURL: directory)

        await store.record(
            .databaseOpenFailed,
            level: .error,
            metadata: DiagnosticEventMetadata(errorDomain: .sqlite, numericCode: 14),
            at: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let log = directory.appendingPathComponent("wifiusage.log")
        let data = try Data(contentsOf: log)
        let lines = data.split(separator: 0x0A)
        XCTAssertEqual(lines.count, 1)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(lines[0])) as? [String: Any]
        )
        XCTAssertEqual(object["event"] as? String, "database.open.failed")
        XCTAssertEqual(object["level"] as? String, "error")

        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: log.path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(
            try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup,
            true
        )
    }

    func testExportRedactsSensitiveContextAndNeverContainsBusinessData() async {
        let directory = temporaryDirectory("redaction")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DiagnosticLogStore(directoryURL: directory)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        await store.record(.wifiResolutionChanged, metadata: DiagnosticEventMetadata(
            connected: true,
            wifiNameIdentified: false,
            wifiResolutionSource: .ipconfig
        ), at: now)

        let report = await store.export(
            context: DiagnosticReportContext(
                appVersion: "1.1 alice@example.com",
                appBuild: "2 TeamIdentifier=ABCDEFGHIJ",
                distribution: "PublicRelease",
                operatingSystemVersion: "macOS /Users/alice https://private.test 192.168.1.8",
                architecture: "arm64",
                repositoryReady: true,
                wifiState: .connectedWithoutName,
                physicalSamplingActive: true,
                applicationSamplingState: "running"
            ),
            generatedAt: now
        )

        for secret in [
            "alice@example.com", "/Users/alice", "https://private.test",
            "192.168.1.8", "ABCDEFGHIJ", "家庭网络📶", "Safari", "com.apple.Safari",
            "ssid:v1:414243"
        ] {
            XCTAssertFalse(report.contains(secret), "Report leaked \(secret)")
        }
        XCTAssertTrue(report.contains("<redacted-email>"))
        XCTAssertTrue(report.contains("wifi.resolve.changed"))
        XCTAssertTrue(report.contains(
            "privacy=sensitive_names,paths,traffic,plans,contact_not_collected"
        ))
        XCTAssertLessThanOrEqual(report.utf8.count, DiagnosticLogStore.maximumExportBytes)
    }

    func testRepeatedEventsAreRateLimitedAndSummarized() async {
        let directory = temporaryDirectory("dedupe")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DiagnosticLogStore(
            directoryURL: directory,
            duplicateWindow: 30
        )
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for offset in 0..<5 {
            await store.record(
                .physicalSamplerFailed,
                level: .error,
                metadata: DiagnosticEventMetadata(errorDomain: .interfaceCounters, numericCode: 5),
                at: start.addingTimeInterval(TimeInterval(offset))
            )
        }

        let report = await store.export(
            context: context(now: start),
            generatedAt: start.addingTimeInterval(10)
        )
        XCTAssertEqual(report.components(separatedBy: "wifi.sampler.failed").count - 1, 2)
        XCTAssertTrue(report.contains(#""repeatCount":4"#))
    }

    func testRotatesAndKeepsConfiguredFileCount() async throws {
        let directory = temporaryDirectory("rotation")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DiagnosticLogStore(
            directoryURL: directory,
            maximumFileBytes: 512,
            maximumFileCount: 3,
            duplicateWindow: 1
        )
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<40 {
            await store.record(
                .databaseWriteFailed,
                level: .error,
                metadata: DiagnosticEventMetadata(errorDomain: .sqlite, numericCode: Int64(index)),
                at: start.addingTimeInterval(TimeInterval(index * 2))
            )
        }

        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("wifiusage") }
        XCTAssertGreaterThan(files.count, 1)
        XCTAssertLessThanOrEqual(files.count, 3)
        XCTAssertTrue(files.contains { $0.lastPathComponent == "wifiusage.log" })
    }

    func testPrunesExpiredFilesAndClearRemovesOnlyManagedLogs() async throws {
        let directory = temporaryDirectory("retention")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let expired = directory.appendingPathComponent("wifiusage.4.log")
        let unrelated = directory.appendingPathComponent("keep.txt")
        try Data("old\n".utf8).write(to: expired)
        try Data("keep\n".utf8).write(to: unrelated)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
            ofItemAtPath: expired.path
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = DiagnosticLogStore(directoryURL: directory)

        await store.record(.appLaunch, at: now)
        XCTAssertFalse(FileManager.default.fileExists(atPath: expired.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))

        await store.clear()
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("wifiusage.log").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testPrunesExpiredEntriesInsideAnActivelyWrittenLog() async throws {
        let directory = temporaryDirectory("mixed-retention")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DiagnosticLogStore(
            directoryURL: directory,
            duplicateWindow: 1
        )
        let now = Date()
        await store.record(
            .databaseOpenFailed,
            level: .error,
            at: now.addingTimeInterval(-(8 * 24 * 60 * 60))
        )
        await store.record(
            .databaseOpenSucceeded,
            at: now
        )

        let report = await store.export(context: context(now: now), generatedAt: now)
        let stored = try String(
            contentsOf: directory.appendingPathComponent("wifiusage.log"),
            encoding: .utf8
        )

        XCTAssertFalse(report.contains("database.open.failed"))
        XCTAssertTrue(report.contains("database.open.succeeded"))
        XCTAssertFalse(stored.contains("database.open.failed"))
        XCTAssertTrue(stored.contains("database.open.succeeded"))
    }

    func testRemovesOnlyManagedPruneTemporaryFiles() async throws {
        let directory = temporaryDirectory("stale-prune-temp")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stale = directory.appendingPathComponent(
            ".wifiusage-prune-\(UUID().uuidString).tmp"
        )
        let unrelated = directory.appendingPathComponent(".keep.tmp")
        try Data("stale\n".utf8).write(to: stale)
        try Data("keep\n".utf8).write(to: unrelated)
        let store = DiagnosticLogStore(directoryURL: directory)

        await store.ensureDirectory()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))

        let secondStale = directory.appendingPathComponent(
            ".wifiusage-prune-\(UUID().uuidString).tmp"
        )
        try Data("stale-again\n".utf8).write(to: secondStale)
        await store.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondStale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testExportHonorsByteLimitAndMarksTruncation() async {
        let directory = temporaryDirectory("limit")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DiagnosticLogStore(
            directoryURL: directory,
            maximumFileBytes: 64 * 1_024,
            maximumFileCount: 2,
            duplicateWindow: 1
        )
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<200 {
            await store.record(
                .feedbackSendFailed,
                level: .error,
                metadata: DiagnosticEventMetadata(
                    errorDomain: .feedbackNetwork,
                    numericCode: Int64(index),
                    httpStatusClass: 5
                ),
                at: start.addingTimeInterval(TimeInterval(index * 2))
            )
        }

        let report = await store.export(
            context: context(now: start),
            generatedAt: start.addingTimeInterval(500),
            maximumBytes: 4_096
        )
        XCTAssertLessThanOrEqual(report.utf8.count, 4_096)
        XCTAssertTrue(report.contains("truncated=true"))
    }

    private func temporaryDirectory(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("WiFiUsage-DiagnosticLogTests-\(suffix)-\(UUID().uuidString)")
    }

    private func context(now: Date) -> DiagnosticReportContext {
        DiagnosticReportContext(
            appVersion: "1.1.0",
            appBuild: "2",
            distribution: "PublicRelease",
            operatingSystemVersion: "macOS 26.5.2",
            architecture: "arm64",
            repositoryReady: true,
            wifiState: .identified,
            physicalSamplingActive: true,
            applicationSamplingState: "running"
        )
    }
}
