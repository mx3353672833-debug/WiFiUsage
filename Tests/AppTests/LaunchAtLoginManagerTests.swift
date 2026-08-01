import Foundation
import XCTest
@testable import WiFiUsage

final class LaunchAtLoginManagerTests: XCTestCase {
    func testDerivesTrimmedConfigurationSpecificLabels() {
        let applicationURL = URL(fileURLWithPath: "/Applications/WiFiUsage.app")

        XCTAssertEqual(
            LaunchAtLoginManager(
                bundleIdentifier: " one.xjp.WiFiUsage ",
                applicationURL: applicationURL
            ).label,
            "one.xjp.WiFiUsage.launchAtLogin"
        )
        XCTAssertEqual(
            LaunchAtLoginManager(
                bundleIdentifier: "one.xjp.WiFiUsage.PublicTest",
                applicationURL: applicationURL
            ).label,
            "one.xjp.WiFiUsage.PublicTest.launchAtLogin"
        )
    }

    func testInvalidBundleIdentifiersFailWithoutTouchingLaunchAgents() {
        let applicationURL = URL(fileURLWithPath: "/Applications/WiFiUsage.app")

        for identifier in [nil, "", ".one.xjp", "one.xjp.", "one_xjp.WiFiUsage"] as [String?] {
            let manager = LaunchAtLoginManager(
                bundleIdentifier: identifier,
                applicationURL: applicationURL
            )
            XCTAssertEqual(manager.label, "")
            XCTAssertEqual(manager.state, .notFound)
            XCTAssertThrowsError(try manager.setEnabled(true)) { error in
                guard case LaunchAtLoginError.invalidBundleIdentifier = error else {
                    return XCTFail("Expected invalidBundleIdentifier, got \(error)")
                }
            }
        }
    }

    func testUnstableApplicationLocationFailsBeforeFilesystemAccess() {
        let manager = LaunchAtLoginManager(
            bundleIdentifier: "one.xjp.WiFiUsage.Tests",
            applicationURL: URL(fileURLWithPath: "/tmp/WiFiUsage.app")
        )

        XCTAssertEqual(manager.state, .notFound)
        XCTAssertThrowsError(try manager.setEnabled(true)) { error in
            guard case LaunchAtLoginError.unstableApplicationLocation = error else {
                return XCTFail("Expected unstableApplicationLocation, got \(error)")
            }
        }
    }
}
