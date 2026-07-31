import Foundation
import UsageCore

public enum PhysicalWiFiSamplerError: Error, Equatable, Sendable {
    case invalidSamplingInterval
}

/// Diffs cumulative physical Wi-Fi counters. The first observation, interface changes,
/// and counter decreases establish a new baseline and deliberately emit no traffic.
public actor PhysicalWiFiSampler {
    public typealias SampleHandler = @Sendable (PhysicalUsageSample) async throws -> Void

    private struct Baseline: Sendable {
        let network: WiFiNetworkIdentity
        let observedAt: Date
        let receivedBytes: UInt64
        let transmittedBytes: UInt64
    }

    private let counterProvider: any InterfaceCounterProviding
    private let networkResolver: WiFiNetworkResolver
    private let samplingInterval: Duration
    private let sampleHandler: SampleHandler
    private var baseline: Baseline?
    private var samplingTask: Task<Void, Never>?

    public init(
        counterProvider: any InterfaceCounterProviding = SystemInterfaceCounterProvider(),
        networkResolver: WiFiNetworkResolver,
        samplingInterval: Duration = .seconds(1),
        sampleHandler: @escaping SampleHandler
    ) throws {
        guard samplingInterval > .zero else {
            throw PhysicalWiFiSamplerError.invalidSamplingInterval
        }
        self.counterProvider = counterProvider
        self.networkResolver = networkResolver
        self.samplingInterval = samplingInterval
        self.sampleHandler = sampleHandler
    }

    public func start() {
        guard samplingTask == nil else { return }
        samplingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await self.sampleOnce()
                } catch {
                    // A transient CoreWLAN/sysctl/storage error must not terminate sampling.
                }
                do {
                    try await Task.sleep(for: self.samplingInterval)
                } catch {
                    break
                }
            }
        }
    }

    public func stop() {
        samplingTask?.cancel()
        samplingTask = nil
        baseline = nil
    }

    public func resetBaseline() {
        baseline = nil
    }

    @discardableResult
    public func sampleOnce(at observedAt: Date = Date()) async throws -> PhysicalUsageSample? {
        guard let network = networkResolver.currentNetwork(),
              network.interfaceIndex != 0,
              !Self.isVirtualInterface(network.interfaceName) else {
            baseline = nil
            return nil
        }

        let counters = try counterProvider.interfaceCounters()
        guard let current = counters.first(where: {
            $0.index == network.interfaceIndex &&
            $0.name == network.interfaceName &&
            !Self.isVirtualInterface($0.name)
        }) else {
            baseline = nil
            return nil
        }

        let currentBaseline = Baseline(
            network: network,
            observedAt: observedAt,
            receivedBytes: current.receivedBytes,
            transmittedBytes: current.transmittedBytes
        )
        defer { baseline = currentBaseline }

        guard let previous = baseline,
              previous.network.interfaceName == network.interfaceName,
              previous.network.interfaceIndex == network.interfaceIndex,
              previous.network.ssid == network.ssid,
              observedAt > previous.observedAt else {
            return nil
        }

        guard current.receivedBytes >= previous.receivedBytes,
              current.transmittedBytes >= previous.transmittedBytes else {
            return nil
        }

        let bytes = UsageBytes(
            downloadedBytes: current.receivedBytes - previous.receivedBytes,
            uploadedBytes: current.transmittedBytes - previous.transmittedBytes
        )
        guard bytes != .zero else { return nil }

        let sample = PhysicalUsageSample(
            network: network,
            startedAt: previous.observedAt,
            endedAt: observedAt,
            bytes: bytes
        )
        try await sampleHandler(sample)
        return sample
    }

    public static func isVirtualInterface(_ name: String) -> Bool {
        let lowercased = name.lowercased()
        let virtualPrefixes = [
            "awdl", "llw", "utun", "tun", "tap", "bridge", "vnic", "vmnet",
            "gif", "stf", "ipsec", "ppp", "lo", "anpi", "ap"
        ]
        return virtualPrefixes.contains { lowercased.hasPrefix($0) }
    }
}
