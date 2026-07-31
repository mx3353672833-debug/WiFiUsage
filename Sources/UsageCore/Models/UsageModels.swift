import Foundation

/// The network category attached to physical and application usage records.
public enum CarrierKind: String, Codable, CaseIterable, Hashable, Sendable {
    case wifi
    case wired
    case cellular
    case loopback
    case other
    case unknown
}

/// Download and upload byte counts for a sampling interval.
public struct UsageBytes: Codable, Hashable, Sendable {
    public var downloadedBytes: UInt64
    public var uploadedBytes: UInt64

    public init(downloadedBytes: UInt64 = 0, uploadedBytes: UInt64 = 0) {
        self.downloadedBytes = downloadedBytes
        self.uploadedBytes = uploadedBytes
    }

    public init(inboundBytes: UInt64, outboundBytes: UInt64) {
        self.init(downloadedBytes: inboundBytes, uploadedBytes: outboundBytes)
    }

    public var inboundBytes: UInt64 { downloadedBytes }
    public var outboundBytes: UInt64 { uploadedBytes }

    public var totalBytes: UInt64 {
        let (sum, overflow) = downloadedBytes.addingReportingOverflow(uploadedBytes)
        return overflow ? .max : sum
    }

    public static let zero = UsageBytes()

    public static func + (lhs: UsageBytes, rhs: UsageBytes) -> UsageBytes {
        UsageBytes(
            downloadedBytes: saturatedSum(lhs.downloadedBytes, rhs.downloadedBytes),
            uploadedBytes: saturatedSum(lhs.uploadedBytes, rhs.uploadedBytes)
        )
    }

    public static func += (lhs: inout UsageBytes, rhs: UsageBytes) {
        lhs = lhs + rhs
    }

    private static func saturatedSum(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }
}

public struct WiFiNetworkIdentity: Codable, Hashable, Sendable {
    public let interfaceName: String
    public let interfaceIndex: UInt32
    public let ssid: String?

    public init(interfaceName: String, interfaceIndex: UInt32, ssid: String? = nil) {
        self.interfaceName = interfaceName
        self.interfaceIndex = interfaceIndex
        self.ssid = ssid
    }

    public var networkID: String {
        WiFiNetworkIdentifier.make(interfaceName: interfaceName, ssid: ssid)
    }
}

public enum WiFiNetworkIdentifier {
    public static func make(interfaceName: String, ssid: String?) -> String {
        if let ssid, !ssid.isEmpty {
            return "ssid:v1:\(hexEncoded(ssid))"
        }
        return "unidentified:v1:\(hexEncoded(interfaceName))"
    }

    private static func hexEncoded(_ value: String) -> String {
        value.utf8.map { String(format: "%02x", $0) }.joined()
    }
}

public struct KnownWiFiNetwork: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let ssid: String?
    public let interfaceName: String
    public let firstSeenAt: Date
    public let lastSeenAt: Date

    public init(
        id: String,
        ssid: String?,
        interfaceName: String,
        firstSeenAt: Date,
        lastSeenAt: Date
    ) {
        self.id = id
        self.ssid = ssid
        self.interfaceName = interfaceName
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
    }

    public init(identity: WiFiNetworkIdentity, observedAt: Date = Date()) {
        self.init(
            id: identity.networkID,
            ssid: identity.ssid,
            interfaceName: identity.interfaceName,
            firstSeenAt: observedAt,
            lastSeenAt: observedAt
        )
    }

    public var isIdentified: Bool {
        guard let ssid else { return false }
        return !ssid.isEmpty
    }
}

public struct WiFiPlanAssignment: Codable, Hashable, Sendable {
    public let networkID: String
    public let planID: UUID
    public let updatedAt: Date

    public init(networkID: String, planID: UUID, updatedAt: Date = Date()) {
        self.networkID = networkID
        self.planID = planID
        self.updatedAt = updatedAt
    }
}

public struct PhysicalUsageSample: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let network: WiFiNetworkIdentity
    public let startedAt: Date
    public let endedAt: Date
    public let bytes: UsageBytes

    public init(
        id: UUID = UUID(),
        network: WiFiNetworkIdentity,
        startedAt: Date,
        endedAt: Date,
        bytes: UsageBytes
    ) {
        self.id = id
        self.network = network
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.bytes = bytes
    }
}

public struct ApplicationUsageSample: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let applicationIdentifier: String
    public let carrier: CarrierKind
    public let startedAt: Date
    public let endedAt: Date
    public let bytes: UsageBytes

    public init(
        id: UUID = UUID(),
        applicationIdentifier: String,
        carrier: CarrierKind,
        startedAt: Date,
        endedAt: Date,
        bytes: UsageBytes
    ) {
        self.id = id
        self.applicationIdentifier = applicationIdentifier
        self.carrier = carrier
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.bytes = bytes
    }

    /// Compatibility initializer for application samples written before carrier attribution.
    public init(
        id: UUID = UUID(),
        applicationIdentifier: String,
        startedAt: Date,
        endedAt: Date,
        bytes: UsageBytes
    ) {
        self.init(
            id: id,
            applicationIdentifier: applicationIdentifier,
            carrier: .unknown,
            startedAt: startedAt,
            endedAt: endedAt,
            bytes: bytes
        )
    }
}

/// A compact time bucket used by the free process sampler.
public struct ApplicationUsageBucket: Codable, Hashable, Sendable {
    public let applicationIdentifier: String
    public let carrier: CarrierKind
    public let bucketStart: Date
    public let endedAt: Date
    public let bytes: UsageBytes

    public init(
        applicationIdentifier: String,
        carrier: CarrierKind,
        bucketStart: Date,
        endedAt: Date,
        bytes: UsageBytes
    ) {
        self.applicationIdentifier = applicationIdentifier
        self.carrier = carrier
        self.bucketStart = bucketStart
        self.endedAt = endedAt
        self.bytes = bytes
    }
}

public struct ApplicationUsageTotal: Codable, Hashable, Sendable {
    public let applicationIdentifier: String
    public let carrier: CarrierKind
    public var bytes: UsageBytes

    public init(
        applicationIdentifier: String,
        carrier: CarrierKind,
        bytes: UsageBytes
    ) {
        self.applicationIdentifier = applicationIdentifier
        self.carrier = carrier
        self.bytes = bytes
    }

    /// Compatibility initializer for totals that are not split by carrier.
    public init(applicationIdentifier: String, bytes: UsageBytes) {
        self.init(applicationIdentifier: applicationIdentifier, carrier: .unknown, bytes: bytes)
    }
}
