import CoreFoundation
import Foundation

public struct AppRuntimeConfiguration: Equatable, Sendable {
    public enum DistributionVariant: String, CaseIterable, Sendable {
        case personal = "Personal"
        case publicTest = "PublicTest"
        case publicRelease = "PublicRelease"

        fileprivate var expectedApplicationSupportDirectory: String {
            switch self {
            case .personal, .publicRelease:
                "WiFiUsage"
            case .publicTest:
                "WiFiUsage-PublicTest"
            }
        }

        fileprivate var allowsSensitiveCapabilities: Bool {
            self == .personal
        }
    }

    public static let current = AppRuntimeConfiguration(bundle: .main)

    public let distributionVariant: DistributionVariant
    public let applicationSupportDirectory: String
    public var applicationSupportDirectoryName: String { applicationSupportDirectory }
    public let allowsLocationSSIDAccess: Bool
    public let allowsLegacyDatabaseImport: Bool
    public let isValid: Bool

    public var isPublicDistribution: Bool {
        distributionVariant != .personal
    }

    public init(bundle: Bundle) {
        self.init(
            infoDictionary: bundle.infoDictionary ?? [:],
            expectedVariant: Self.buildVariant
        )
    }

    public init(
        infoDictionary: [String: Any],
        expectedVariant: DistributionVariant
    ) {
        let configuredVariant = (infoDictionary[InfoKey.distributionVariant] as? String)
            .flatMap(DistributionVariant.init(rawValue:))
        let configuredDirectory = infoDictionary[InfoKey.applicationSupportDirectory] as? String
        let configuredLocationAccess = Self.strictBoolean(
            infoDictionary[InfoKey.allowsLocationSSIDAccess]
        )
        let configuredLegacyImport = Self.strictBoolean(
            infoDictionary[InfoKey.allowsLegacyDatabaseImport]
        )

        let expectedSensitiveValue = expectedVariant.allowsSensitiveCapabilities
        let configurationIsValid = configuredVariant == expectedVariant
            && configuredDirectory == expectedVariant.expectedApplicationSupportDirectory
            && configuredLocationAccess == expectedSensitiveValue
            && configuredLegacyImport == expectedSensitiveValue

        distributionVariant = expectedVariant
        applicationSupportDirectory = expectedVariant.expectedApplicationSupportDirectory
        isValid = configurationIsValid

        // Sensitive capabilities are enabled only for a fully valid Personal build.
        // Public builds and malformed configurations always fail closed.
        allowsLocationSSIDAccess = configurationIsValid && expectedSensitiveValue
        allowsLegacyDatabaseImport = configurationIsValid && expectedSensitiveValue
    }

    private static var buildVariant: DistributionVariant {
        #if WU_PUBLIC_TEST
        .publicTest
        #elseif WU_PUBLIC_RELEASE
        .publicRelease
        #else
        .personal
        #endif
    }

    private static func strictBoolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return nil
        }
        return number.boolValue
    }

    private enum InfoKey {
        static let distributionVariant = "WUDistributionVariant"
        static let applicationSupportDirectory = "WUApplicationSupportDirectory"
        static let allowsLocationSSIDAccess = "WUAllowsLocationSSIDAccess"
        static let allowsLegacyDatabaseImport = "WUAllowsLegacyDatabaseImport"
    }
}
