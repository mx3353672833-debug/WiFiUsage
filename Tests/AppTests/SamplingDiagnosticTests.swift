import Foundation
import XCTest
@testable import WiFiUsage

final class SamplingDiagnosticTests: XCTestCase {
    func testApplicationCommandFailureKeepsOnlyStatusAndRetryCount() {
        let failure = ProcessNetworkSampler.diagnosticFailure(
            for: ProcessNetworkSamplerError.commandFailed(
                7,
                "SSID: Private Wi-Fi /Users/alice secret@example.com"
            ),
            retryCount: 3
        )

        XCTAssertEqual(failure.kind, .commandFailed)
        XCTAssertEqual(failure.numericCode, 7)
        XCTAssertEqual(failure.retryCount, 3)
    }

    func testApplicationUnknownFailureDoesNotCarryNSErrorDetails() {
        let failure = ProcessNetworkSampler.diagnosticFailure(
            for: NSError(
                domain: "private.example",
                code: 99,
                userInfo: [NSLocalizedDescriptionKey: "/Users/alice/private.txt"]
            ),
            retryCount: 1
        )

        XCTAssertEqual(failure.kind, .unknown)
        XCTAssertNil(failure.numericCode)
        XCTAssertEqual(failure.retryCount, 1)
    }

    func testPhysicalCounterFailureKeepsOnlySafeDomainAndCode() {
        let failure = PhysicalWiFiSampler.diagnosticFailure(
            for: SystemInterfaceCounterError.systemCall(5)
        )

        XCTAssertEqual(failure.domain, .interfaceCounters)
        XCTAssertEqual(failure.numericCode, 5)
    }
}
