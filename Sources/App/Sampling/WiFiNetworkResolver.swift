import CoreLocation
import CoreWLAN
import Darwin
import Foundation
import UsageCore

public enum WiFiNameAccessState: String, Equatable, Sendable {
    case notRequired
    case locationServicesDisabled
    case notDetermined
    case restricted
    case denied
    case authorized
}

public protocol WiFiNetworkResolving: AnyObject, Sendable {
    typealias WiFiNameAccessStateHandler = @MainActor @Sendable (WiFiNameAccessState) -> Void

    var wifiNameAccessState: WiFiNameAccessState { get }
    var onWiFiNameAccessStateChange: WiFiNameAccessStateHandler? { get set }
    func requestSSIDAuthorization()
    func refreshWiFiNameAccessState()
    func currentNetwork() async -> WiFiNetworkIdentity?
}

public final class WiFiNetworkResolver: WiFiNetworkResolving, @unchecked Sendable {
    private let wifiClient: CWWiFiClient
    private let ssidProvider: any IPConfigSSIDProviding
    private let locationAuthorization: LocationSSIDAuthorization?
    private let stateHandlerLock = NSLock()
    private var stateHandler: WiFiNameAccessStateHandler?

    public init(
        runtimeConfiguration: AppRuntimeConfiguration = .current,
        wifiClient: CWWiFiClient = .shared(),
        ssidProvider: any IPConfigSSIDProviding = IPConfigSSIDProvider()
    ) {
        self.wifiClient = wifiClient
        self.ssidProvider = ssidProvider
        locationAuthorization = runtimeConfiguration.allowsLocationSSIDAccess
            ? LocationSSIDAuthorization()
            : nil
        locationAuthorization?.onStateChange = { [weak self] state in
            self?.publishWiFiNameAccessState(state)
        }
    }

    public var wifiNameAccessState: WiFiNameAccessState {
        locationAuthorization?.state ?? .notRequired
    }

    public var onWiFiNameAccessStateChange: WiFiNameAccessStateHandler? {
        get {
            stateHandlerLock.lock()
            defer { stateHandlerLock.unlock() }
            return stateHandler
        }
        set {
            stateHandlerLock.lock()
            stateHandler = newValue
            stateHandlerLock.unlock()
            guard let newValue else { return }
            let currentState = wifiNameAccessState
            Task { @MainActor in newValue(currentState) }
        }
    }

    public func requestSSIDAuthorization() {
        locationAuthorization?.requestAuthorization()
    }

    public func refreshWiFiNameAccessState() {
        publishWiFiNameAccessState(wifiNameAccessState)
    }

    public func currentNetwork() async -> WiFiNetworkIdentity? {
        let candidates = candidateInterfaces()
        guard !candidates.isEmpty else { return nil }

        if let participating = preferredParticipatingInterface(in: candidates) {
            let name = participating.name
            let coreWLANSSID = WiFiNetworkName.normalize(participating.interface?.ssid())
            if let coreWLANSSID {
                return Self.identity(name: name, ssid: coreWLANSSID)
            }
            guard let fallback = await ssidProvider.summary(for: name),
                  !Task.isCancelled,
                  fallback.isWiFi,
                  fallback.isLinkActive else {
                return Self.identity(name: name, ssid: nil)
            }
            return Self.identity(name: name, ssid: fallback.ssid)
        }

        for candidate in candidates {
            guard !Task.isCancelled else { return nil }
            guard let summary = await ssidProvider.summary(for: candidate.name),
                  summary.isWiFi,
                  summary.isLinkActive else {
                continue
            }
            guard !Task.isCancelled else { return nil }
            return Self.identity(name: candidate.name, ssid: summary.ssid)
        }
        return nil
    }

    private struct Candidate {
        let name: String
        let interface: CWInterface?
    }

    private func candidateInterfaces() -> [Candidate] {
        var candidates: [Candidate] = []
        var names = Set<String>()

        func append(_ interface: CWInterface?) {
            guard let interface,
                  let name = interface.interfaceName else { return }
            append(name: name, interface: interface)
        }
        func append(name: String, interface: CWInterface?) {
            guard Self.isUsableInterfaceName(name), names.insert(name).inserted else { return }
            candidates.append(Candidate(name: name, interface: interface))
        }

        append(wifiClient.interface())
        wifiClient.interfaces()?.forEach { append($0) }
        wifiClient.interfaceNames()?.forEach { name in
            append(name: name, interface: wifiClient.interface(withName: name))
        }
        return candidates
    }

    private func preferredParticipatingInterface(in candidates: [Candidate]) -> Candidate? {
        let participating = candidates.filter(Self.isParticipating)
        return participating.first(where: { $0.interface?.interfaceMode() == .station })
            ?? participating.first
    }

    private static func isParticipating(_ candidate: Candidate) -> Bool {
        guard let interface = candidate.interface else { return false }
        return interface.powerOn()
            && interface.serviceActive()
            && interface.interfaceMode() != .none
    }

    private static func identity(name: String, ssid: String?) -> WiFiNetworkIdentity? {
        let index = name.withCString { if_nametoindex($0) }
        guard index != 0 else { return nil }
        return WiFiNetworkIdentity(interfaceName: name, interfaceIndex: index, ssid: ssid)
    }

    private static func isUsableInterfaceName(_ name: String) -> Bool {
        guard !name.isEmpty,
              !PhysicalWiFiSampler.isVirtualInterface(name),
              name.utf8.count < Int(IFNAMSIZ) else { return false }
        return name.withCString { if_nametoindex($0) } != 0
    }

    private func publishWiFiNameAccessState(_ state: WiFiNameAccessState) {
        stateHandlerLock.lock()
        let handler = stateHandler
        stateHandlerLock.unlock()
        guard let handler else { return }
        Task { @MainActor in handler(state) }
    }
}

private final class LocationSSIDAuthorization: NSObject, CLLocationManagerDelegate,
    @unchecked Sendable {
    private let manager: CLLocationManager
    var onStateChange: (@Sendable (WiFiNameAccessState) -> Void)?

    override init() {
        manager = CLLocationManager()
        super.init()
        manager.delegate = self
    }

    var state: WiFiNameAccessState {
        guard CLLocationManager.locationServicesEnabled() else {
            return .locationServicesDisabled
        }
        switch manager.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorizedAlways, .authorizedWhenInUse: return .authorized
        @unknown default: return .restricted
        }
    }

    func requestAuthorization() {
        if Thread.isMainThread {
            requestAuthorizationOnMainThread()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.requestAuthorizationOnMainThread()
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onStateChange?(state)
    }

    private func requestAuthorizationOnMainThread() {
        guard state == .notDetermined else {
            onStateChange?(state)
            return
        }
        manager.requestWhenInUseAuthorization()
    }
}
