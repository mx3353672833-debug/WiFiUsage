import Foundation
import XCTest
@testable import WiFiUsage

final class AppRuntimeConfigurationTests: XCTestCase {
    func testValidPersonalConfigurationEnablesSensitiveCapabilities() {
        let configuration = AppRuntimeConfiguration(
            infoDictionary: dictionary(
                variant: .personal,
                directory: "WiFiUsage",
                locationAccess: true,
                legacyImport: true
            ),
            expectedVariant: .personal
        )

        XCTAssertTrue(configuration.isValid)
        XCTAssertFalse(configuration.isPublicDistribution)
        XCTAssertEqual(configuration.applicationSupportDirectoryName, "WiFiUsage")
        XCTAssertTrue(configuration.allowsLocationSSIDAccess)
        XCTAssertTrue(configuration.allowsLegacyDatabaseImport)
    }

    func testMalformedPersonalConfigurationFailsClosed() {
        let malformedConfigurations: [[String: Any]] = [
            dictionary(
                variant: .publicTest,
                directory: "WiFiUsage",
                locationAccess: true,
                legacyImport: true
            ),
            dictionary(
                variant: .personal,
                directory: "WrongDirectory",
                locationAccess: true,
                legacyImport: true
            ),
            dictionary(
                variant: .personal,
                directory: "WiFiUsage",
                locationAccess: false,
                legacyImport: true
            ),
            [
                "WUDistributionVariant": "Personal",
                "WUApplicationSupportDirectory": "WiFiUsage",
                "WUAllowsLocationSSIDAccess": 1,
                "WUAllowsLegacyDatabaseImport": true
            ]
        ]

        for dictionary in malformedConfigurations {
            let configuration = AppRuntimeConfiguration(
                infoDictionary: dictionary,
                expectedVariant: .personal
            )
            XCTAssertFalse(configuration.isValid)
            XCTAssertFalse(configuration.allowsLocationSSIDAccess)
            XCTAssertFalse(configuration.allowsLegacyDatabaseImport)
        }
    }

    func testValidPublicConfigurationsRemainCapabilityDisabled() {
        for (variant, directory) in [
            (AppRuntimeConfiguration.DistributionVariant.publicTest, "WiFiUsage-PublicTest"),
            (.publicRelease, "WiFiUsage")
        ] {
            let configuration = AppRuntimeConfiguration(
                infoDictionary: dictionary(
                    variant: variant,
                    directory: directory,
                    locationAccess: false,
                    legacyImport: false
                ),
                expectedVariant: variant
            )

            XCTAssertTrue(configuration.isValid)
            XCTAssertTrue(configuration.isPublicDistribution)
            XCTAssertFalse(configuration.allowsLocationSSIDAccess)
            XCTAssertFalse(configuration.allowsLegacyDatabaseImport)
        }
    }

    func testMalformedPublicConfigurationFailsClosedAndUsesExpectedDirectory() {
        let validValues = dictionary(
            variant: .publicTest,
            directory: "WiFiUsage-PublicTest",
            locationAccess: false,
            legacyImport: false
        )
        let mutations: [(String, Any?)] = [
            ("WUDistributionVariant", "Personal"),
            ("WUApplicationSupportDirectory", "WiFiUsage"),
            ("WUAllowsLocationSSIDAccess", true),
            ("WUAllowsLegacyDatabaseImport", true),
            ("WUAllowsLocationSSIDAccess", 0),
            ("WUAllowsLegacyDatabaseImport", nil)
        ]

        for (key, replacement) in mutations {
            var values = validValues
            values[key] = replacement
            let configuration = AppRuntimeConfiguration(
                infoDictionary: values,
                expectedVariant: .publicTest
            )

            XCTAssertFalse(configuration.isValid, "Expected invalid configuration after changing \(key)")
            XCTAssertEqual(configuration.distributionVariant, .publicTest)
            XCTAssertEqual(configuration.applicationSupportDirectoryName, "WiFiUsage-PublicTest")
            XCTAssertFalse(configuration.allowsLocationSSIDAccess)
            XCTAssertFalse(configuration.allowsLegacyDatabaseImport)
        }
    }

    private func dictionary(
        variant: AppRuntimeConfiguration.DistributionVariant,
        directory: String,
        locationAccess: Bool,
        legacyImport: Bool
    ) -> [String: Any] {
        [
            "WUDistributionVariant": variant.rawValue,
            "WUApplicationSupportDirectory": directory,
            "WUAllowsLocationSSIDAccess": locationAccess,
            "WUAllowsLegacyDatabaseImport": legacyImport
        ]
    }
}
