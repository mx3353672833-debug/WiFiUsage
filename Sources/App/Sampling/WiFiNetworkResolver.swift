import CoreLocation
import CoreWLAN
import Foundation
import UsageCore

public enum WiFiNameAccessState: String, Equatable, Sendable {
    case locationServicesDisabled
    case notDetermined
    case restricted
    case denied
    case authorized
}

public final class WiFiNetworkResolver: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    public typealias WiFiNameAccessStateHandler =
        @MainActor @Sendable (WiFiNameAccessState) -> Void

    private let wifiClient: CWWiFiClient
    private let locationManager: CLLocationManager
    private let stateHandlerLock = NSLock()
    private var stateHandler: WiFiNameAccessStateHandler?

    public override init() {
        wifiClient = CWWiFiClient.shared()
        locationManager = CLLocationManager()
        super.init()
        locationManager.delegate = self
    }

    public var wifiNameAccessState: WiFiNameAccessState {
        guard CLLocationManager.locationServicesEnabled() else {
            return .locationServicesDisabled
        }

        switch locationManager.authorizationStatus {
        case .notDetermined:
            return .notDetermined
        case .restricted:
            return .restricted
        case .denied:
            return .denied
        case .authorizedAlways, .authorizedWhenInUse:
            return .authorized
        @unknown default:
            return .restricted
        }
    }

    /// Called on the main actor whenever Core Location's authorization state changes.
    /// Assigning a handler also delivers the current state immediately.
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
            Task { @MainActor in
                newValue(currentState)
            }
        }
    }

    /// Requests location authorization used by macOS when disclosing SSID.
    /// Interface discovery and byte sampling continue when permission is denied.
    public func requestSSIDAuthorization() {
        if Thread.isMainThread {
            requestAuthorizationOnMainThread()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.requestAuthorizationOnMainThread()
            }
        }
    }

    /// Re-publishes the current state, for example after returning from System Settings.
    public func refreshWiFiNameAccessState() {
        publishWiFiNameAccessState()
    }

    public func currentNetwork() -> WiFiNetworkIdentity? {
        guard let interface = activeWiFiInterface(),
              let name = interface.interfaceName,
              !name.isEmpty,
              if_nametoindex(name) != 0 else {
            return nil
        }
        return WiFiNetworkIdentity(
            interfaceName: name,
            interfaceIndex: if_nametoindex(name),
            ssid: interface.ssid()
        )
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        publishWiFiNameAccessState()
    }

    private func requestAuthorizationOnMainThread() {
        guard wifiNameAccessState == .notDetermined else {
            publishWiFiNameAccessState()
            return
        }
        locationManager.requestWhenInUseAuthorization()
    }

    private func publishWiFiNameAccessState() {
        let currentState = wifiNameAccessState
        stateHandlerLock.lock()
        let handler = stateHandler
        stateHandlerLock.unlock()

        guard let handler else { return }
        Task { @MainActor in
            handler(currentState)
        }
    }

    private func activeWiFiInterface() -> CWInterface? {
        var interfaces: [CWInterface] = []
        var interfaceNames = Set<String>()

        func appendIfUnique(_ interface: CWInterface?) {
            guard let interface,
                  let name = interface.interfaceName,
                  !name.isEmpty,
                  interfaceNames.insert(name).inserted else {
                return
            }
            interfaces.append(interface)
        }

        // Prefer CoreWLAN's default interface when it is connected, but enumerate all
        // interfaces because the default can be stale on Macs with multiple adapters.
        appendIfUnique(wifiClient.interface())
        wifiClient.interfaces()?.forEach { appendIfUnique($0) }

        let participatingInterfaces = interfaces.filter {
            guard let name = $0.interfaceName, if_nametoindex(name) != 0 else {
                return false
            }
            return $0.powerOn()
                && $0.serviceActive()
                && $0.interfaceMode() != .none
        }

        return participatingInterfaces.first(where: { $0.interfaceMode() == .station })
            ?? participatingInterfaces.first
    }
}
