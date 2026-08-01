import XCTest
@testable import UsageCore

final class WiFiNetworkNameTests: XCTestCase {
    func testNormalizeTrimsNamesAndRejectsMissingValues() {
        XCTAssertNil(WiFiNetworkName.normalize(nil))
        XCTAssertNil(WiFiNetworkName.normalize(""))
        XCTAssertNil(WiFiNetworkName.normalize(" \n\t "))
        XCTAssertEqual(WiFiNetworkName.normalize("  Café 📶\n"), "Café 📶")
    }

    func testNormalizeRejectsPlaceholdersCaseInsensitively() {
        for value in [
            "<redacted>", " <REDACTED> ", "<unknown>", "<none>",
            "(null)", "(NONE)", "null", " NULL\n"
        ] {
            XCTAssertNil(WiFiNetworkName.normalize(value), "Expected placeholder to be filtered: \(value)")
        }
    }

    func testNetworkIdentifiersUseNormalizedSSIDAndStableInterfaceFallback() {
        let normalized = WiFiNetworkIdentity(
            interfaceName: "en0",
            interfaceIndex: 4,
            ssid: "  Home:5G  "
        )
        let sameSSIDOnAnotherInterface = WiFiNetworkIdentity(
            interfaceName: "en9",
            interfaceIndex: 99,
            ssid: "Home:5G"
        )
        let placeholder = WiFiNetworkIdentity(
            interfaceName: "en0",
            interfaceIndex: 4,
            ssid: "<redacted>"
        )
        let missingAfterIndexChange = WiFiNetworkIdentity(
            interfaceName: "en0",
            interfaceIndex: 88,
            ssid: nil
        )

        XCTAssertEqual(normalized.ssid, "Home:5G")
        XCTAssertEqual(normalized.networkID, sameSSIDOnAnotherInterface.networkID)
        XCTAssertEqual(normalized.networkID, "ssid:v1:486f6d653a3547")
        XCTAssertNil(placeholder.ssid)
        XCTAssertEqual(placeholder.networkID, missingAfterIndexChange.networkID)
        XCTAssertEqual(placeholder.networkID, "unidentified:v1:656e30")
    }
}
