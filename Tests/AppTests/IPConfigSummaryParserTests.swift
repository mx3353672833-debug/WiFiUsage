import Foundation
import XCTest
@testable import WiFiUsage

final class IPConfigSummaryParserTests: XCTestCase {
    func testParsesOnlyTopLevelSSIDAndPreservesColons() throws {
        let output = """
        <dictionary> {
          BSSID : aa:bb:cc:dd:ee:ff
          Nested : <dictionary> {
            SSID : Wrong Network
            InterfaceType : Ethernet
            LinkStatusActive : FALSE
          }
          SSID : Office:Guest:5G
          InterfaceType : WiFi
          LinkStatusActive : TRUE
        }
        """

        let summary = try XCTUnwrap(IPConfigSummaryParser.parse(Data(output.utf8)))
        XCTAssertEqual(summary.ssid, "Office:Guest:5G")
        XCTAssertTrue(summary.isWiFi)
        XCTAssertTrue(summary.isLinkActive)
    }

    func testBSSIDAndNestedSSIDCannotBecomeSSID() throws {
        let output = """
        <dictionary> {
          BSSID : 11:22:33:44:55:66
          Network : <dictionary> {
            SSID : Nested Secret Network
          }
          InterfaceType : WiFi
          LinkStatusActive : TRUE
        }
        """

        let summary = try XCTUnwrap(IPConfigSummaryParser.parse(Data(output.utf8)))
        XCTAssertNil(summary.ssid)
        XCTAssertTrue(summary.isWiFi)
        XCTAssertTrue(summary.isLinkActive)
    }

    func testFiltersTopLevelSSIDPlaceholdersAndWhitespace() throws {
        for value in ["   ", "<redacted>", " <UNKNOWN> ", "(null)", "NULL", "(NONE)"] {
            let output = """
            <dictionary> {
              SSID : \(value)
              InterfaceType : WiFi
              LinkStatusActive : TRUE
            }
            """
            let summary = try XCTUnwrap(IPConfigSummaryParser.parse(Data(output.utf8)))
            XCTAssertNil(summary.ssid, "Expected placeholder to be filtered: \(value)")
        }
    }

    func testRejectsInvalidUTF8AndOutputWithoutRootDictionary() {
        XCTAssertNil(IPConfigSummaryParser.parse(Data([0xFF, 0xFE])))
        XCTAssertNil(IPConfigSummaryParser.parse(Data("SSID : Exposed Network".utf8)))
    }
}
