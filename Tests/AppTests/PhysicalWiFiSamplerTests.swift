import Foundation
import UsageCore
import XCTest
@testable import WiFiUsage

final class PhysicalWiFiSamplerTests: XCTestCase {
    func testNetworkChangeRebaselinesWithoutCrossNetworkDelta() async throws {
        let networkA = WiFiNetworkIdentity(interfaceName: "en0", interfaceIndex: 7, ssid: "A")
        let networkB = WiFiNetworkIdentity(interfaceName: "en0", interfaceIndex: 7, ssid: "B")
        let resolver = FakeNetworkResolver(networks: [networkA, networkB, networkB])
        let counters = FakeCounterProvider(snapshots: [
            [counter(received: 100, transmitted: 50)],
            [counter(received: 180, transmitted: 90)],
            [counter(received: 230, transmitted: 105)]
        ])
        let samples = SampleRecorder()
        let sampler = try PhysicalWiFiSampler(
            counterProvider: counters,
            networkResolver: resolver,
            sampleHandler: { sample in await samples.append(sample) }
        )
        let firstDate = Date(timeIntervalSince1970: 100)
        let switchDate = Date(timeIntervalSince1970: 110)
        let secondBDate = Date(timeIntervalSince1970: 120)

        let firstSample = try await sampler.sampleOnce(at: firstDate)
        let switchSample = try await sampler.sampleOnce(at: switchDate)
        let sample = try await sampler.sampleOnce(at: secondBDate)

        XCTAssertNil(firstSample)
        XCTAssertNil(switchSample)
        XCTAssertEqual(sample?.network, networkB)
        XCTAssertEqual(sample?.startedAt, switchDate)
        XCTAssertEqual(sample?.endedAt, secondBDate)
        XCTAssertEqual(sample?.bytes, UsageBytes(downloadedBytes: 50, uploadedBytes: 15))
        let recorded = await samples.values
        XCTAssertEqual(recorded, sample.map { [$0] } ?? [])
    }

    func testNilNetworkResetsBaseline() async throws {
        let network = WiFiNetworkIdentity(interfaceName: "en0", interfaceIndex: 7, ssid: "A")
        let resolver = FakeNetworkResolver(networks: [network, nil, network, network])
        let counters = FakeCounterProvider(snapshots: [
            [counter(received: 100, transmitted: 50)],
            [counter(received: 250, transmitted: 100)],
            [counter(received: 275, transmitted: 112)]
        ])
        let samples = SampleRecorder()
        let sampler = try PhysicalWiFiSampler(
            counterProvider: counters,
            networkResolver: resolver,
            sampleHandler: { sample in await samples.append(sample) }
        )
        let firstDate = Date(timeIntervalSince1970: 200)
        let missingDate = Date(timeIntervalSince1970: 210)
        let resetDate = Date(timeIntervalSince1970: 220)
        let finalDate = Date(timeIntervalSince1970: 230)

        let firstSample = try await sampler.sampleOnce(at: firstDate)
        let missingSample = try await sampler.sampleOnce(at: missingDate)
        let resetSample = try await sampler.sampleOnce(at: resetDate)
        let sample = try await sampler.sampleOnce(at: finalDate)

        XCTAssertNil(firstSample)
        XCTAssertNil(missingSample)
        XCTAssertNil(resetSample)
        XCTAssertEqual(sample?.startedAt, resetDate)
        XCTAssertEqual(sample?.endedAt, finalDate)
        XCTAssertEqual(sample?.bytes, UsageBytes(downloadedBytes: 25, uploadedBytes: 12))
        let recorded = await samples.values
        XCTAssertEqual(recorded, sample.map { [$0] } ?? [])
        XCTAssertEqual(counters.callCount, 3, "A nil network must not read interface counters")
    }

    private static func counter(received: UInt64, transmitted: UInt64) -> SystemInterfaceCounter {
        SystemInterfaceCounter(
            name: "en0",
            index: 7,
            receivedBytes: received,
            transmittedBytes: transmitted
        )
    }

    private func counter(received: UInt64, transmitted: UInt64) -> SystemInterfaceCounter {
        Self.counter(received: received, transmitted: transmitted)
    }
}

private final class FakeCounterProvider: InterfaceCounterProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [[SystemInterfaceCounter]]
    private(set) var callCount = 0

    init(snapshots: [[SystemInterfaceCounter]]) {
        self.snapshots = snapshots
    }

    func interfaceCounters() throws -> [SystemInterfaceCounter] {
        lock.lock()
        defer { lock.unlock() }
        callCount += 1
        return snapshots.isEmpty ? [] : snapshots.removeFirst()
    }
}

private final class FakeNetworkResolver: WiFiNetworkResolving, @unchecked Sendable {
    private let lock = NSLock()
    private var networks: [WiFiNetworkIdentity?]
    private var stateHandler: WiFiNameAccessStateHandler?

    init(networks: [WiFiNetworkIdentity?]) {
        self.networks = networks
    }

    var wifiNameAccessState: WiFiNameAccessState { .notRequired }

    var onWiFiNameAccessStateChange: WiFiNameAccessStateHandler? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stateHandler
        }
        set {
            lock.lock()
            stateHandler = newValue
            lock.unlock()
        }
    }

    func requestSSIDAuthorization() {}
    func refreshWiFiNameAccessState() {}

    func currentNetwork() async -> WiFiNetworkIdentity? {
        lock.withLock {
            networks.isEmpty ? nil : networks.removeFirst()
        }
    }
}

private actor SampleRecorder {
    private(set) var values: [PhysicalUsageSample] = []

    func append(_ sample: PhysicalUsageSample) {
        values.append(sample)
    }
}
