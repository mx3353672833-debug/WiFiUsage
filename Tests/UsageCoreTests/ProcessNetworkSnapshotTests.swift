import Foundation
import XCTest
@testable import UsageCore

final class ProcessNetworkSnapshotTests: XCTestCase {
    func testParserReadsProcessNamesPIDsAndCounters() {
        let output = """
        ,bytes_in,bytes_out,
        Safari.123,40,12,
        "Name, ""Quoted"" Comma.456",100,9,
        malformed
        """

        XCTAssertEqual(
            ProcessNetworkSnapshotParser.parse(output),
            [
                ProcessNetworkCounter(
                    processName: "Safari",
                    processIdentifier: 123,
                    bytes: UsageBytes(downloadedBytes: 40, uploadedBytes: 12)
                ),
                ProcessNetworkCounter(
                    processName: "Name, \"Quoted\" Comma",
                    processIdentifier: 456,
                    bytes: UsageBytes(downloadedBytes: 100, uploadedBytes: 9)
                )
            ]
        )
    }

    func testParserSplitsFramesAndUsesHeaderColumnOrder() {
        let output = """
        ,bytes_out,bytes_in,\r
        First.App.123,8,50,\r
        ,bytes_out,bytes_in,\r
        First.App.123,2,10,\r
        New Process.456,4,20,\r
        """

        XCTAssertEqual(
            ProcessNetworkSnapshotParser.parseFrames(output),
            [
                [
                    ProcessNetworkCounter(
                        processName: "First.App",
                        processIdentifier: 123,
                        bytes: UsageBytes(downloadedBytes: 50, uploadedBytes: 8)
                    )
                ],
                [
                    ProcessNetworkCounter(
                        processName: "First.App",
                        processIdentifier: 123,
                        bytes: UsageBytes(downloadedBytes: 10, uploadedBytes: 2)
                    ),
                    ProcessNetworkCounter(
                        processName: "New Process",
                        processIdentifier: 456,
                        bytes: UsageBytes(downloadedBytes: 20, uploadedBytes: 4)
                    )
                ]
            ]
        )
        XCTAssertEqual(
            ProcessNetworkSnapshotParser.parse(output),
            ProcessNetworkSnapshotParser.parseFrames(output).last
        )
    }

    func testParserRejectsIncompleteOrInvalidRows() {
        let output = """
        ,bytes_in,bytes_out,
        Valid.1,2,3,
        Negative.-2,4,5,
        Overflow.3,18446744073709551616,1,
        Missing.4,10,
        "Unclosed.5,10,20,
        """

        XCTAssertEqual(
            ProcessNetworkSnapshotParser.parse(output),
            [
                ProcessNetworkCounter(
                    processName: "Valid",
                    processIdentifier: 1,
                    bytes: UsageBytes(downloadedBytes: 2, uploadedBytes: 3)
                )
            ]
        )
        XCTAssertTrue(
            ProcessNetworkSnapshotParser.parse("Safari.123,40,12,").isEmpty
        )
    }

    func testTrackerDropsFirstSnapshotAndProducesDeltas() {
        var tracker = ProcessNetworkDeltaTracker()
        let firstDate = Date(timeIntervalSince1970: 100)
        let secondDate = Date(timeIntervalSince1970: 105)

        XCTAssertTrue(tracker.observe([
            counter(name: "Safari", pid: 1, down: 100, up: 20)
        ], at: firstDate).isEmpty)

        XCTAssertEqual(
            tracker.observe([
                counter(name: "Safari", pid: 1, down: 175, up: 35)
            ], at: secondDate),
            [
                ProcessNetworkDelta(
                    processName: "Safari",
                    processIdentifier: 1,
                    startedAt: firstDate,
                    endedAt: secondDate,
                    bytes: UsageBytes(downloadedBytes: 75, uploadedBytes: 15)
                )
            ]
        )
    }

    func testTrackerRebaselinesNewProcessesAndCounterDecreases() {
        var tracker = ProcessNetworkDeltaTracker()
        _ = tracker.observe([
            counter(name: "Browser", pid: 10, down: 500, up: 100)
        ], at: Date(timeIntervalSince1970: 1))

        XCTAssertEqual(
            tracker.observe([
                counter(name: "Browser", pid: 10, down: 25, up: 140),
                counter(name: "New App", pid: 11, down: 999, up: 999)
            ], at: Date(timeIntervalSince1970: 2)),
            [
                ProcessNetworkDelta(
                    processName: "Browser",
                    processIdentifier: 10,
                    startedAt: Date(timeIntervalSince1970: 1),
                    endedAt: Date(timeIntervalSince1970: 2),
                    bytes: UsageBytes(downloadedBytes: 0, uploadedBytes: 40)
                )
            ]
        )
    }

    func testTrackerRetainsTemporarilyMissingProcessBaseline() {
        var tracker = ProcessNetworkDeltaTracker()
        _ = tracker.observe([
            counter(name: "Short App", pid: 99, down: 10, up: 2)
        ], at: Date(timeIntervalSince1970: 1))
        _ = tracker.observe([], at: Date(timeIntervalSince1970: 2))

        XCTAssertEqual(
            tracker.observe([
                counter(name: "Short App", pid: 99, down: 500, up: 500)
            ], at: Date(timeIntervalSince1970: 3)),
            [
                ProcessNetworkDelta(
                    processName: "Short App",
                    processIdentifier: 99,
                    startedAt: Date(timeIntervalSince1970: 1),
                    endedAt: Date(timeIntervalSince1970: 3),
                    bytes: UsageBytes(downloadedBytes: 490, uploadedBytes: 498)
                )
            ]
        )
    }

    func testTrackerCountsFirstObservationForProcessStartedDuringMonitoring() {
        var tracker = ProcessNetworkDeltaTracker()
        _ = tracker.observe([], at: Date(timeIntervalSince1970: 10))

        XCTAssertEqual(
            tracker.observe([
                counter(
                    name: "New App",
                    pid: 42,
                    startedAt: Date(timeIntervalSince1970: 10.25),
                    down: 700,
                    up: 50
                )
            ], at: Date(timeIntervalSince1970: 12)),
            [
                ProcessNetworkDelta(
                    processName: "New App",
                    processIdentifier: 42,
                    startedAt: Date(timeIntervalSince1970: 10.25),
                    endedAt: Date(timeIntervalSince1970: 12),
                    bytes: UsageBytes(downloadedBytes: 700, uploadedBytes: 50)
                )
            ]
        )
    }

    func testTrackerSeparatesPIDReuseByProcessStartTime() {
        var tracker = ProcessNetworkDeltaTracker()
        _ = tracker.observe([
            counter(
                name: "Worker",
                pid: 7,
                startedAt: Date(timeIntervalSince1970: 1),
                down: 900,
                up: 100
            )
        ], at: Date(timeIntervalSince1970: 5))

        XCTAssertEqual(
            tracker.observe([
                counter(
                    name: "Worker",
                    pid: 7,
                    startedAt: Date(timeIntervalSince1970: 5.5),
                    down: 20,
                    up: 3
                )
            ], at: Date(timeIntervalSince1970: 6)),
            [
                ProcessNetworkDelta(
                    processName: "Worker",
                    processIdentifier: 7,
                    startedAt: Date(timeIntervalSince1970: 5.5),
                    endedAt: Date(timeIntervalSince1970: 6),
                    bytes: UsageBytes(downloadedBytes: 20, uploadedBytes: 3)
                )
            ]
        )
    }

    private func counter(
        name: String,
        pid: Int32,
        startedAt: Date? = nil,
        down: UInt64,
        up: UInt64
    ) -> ProcessNetworkCounter {
        ProcessNetworkCounter(
            processName: name,
            processIdentifier: pid,
            processStartedAt: startedAt,
            bytes: UsageBytes(downloadedBytes: down, uploadedBytes: up)
        )
    }
}
