import AppKit
import SystemConfiguration

/// Controls a system VPN configuration (any app's packet tunnel) through SystemConfiguration —
/// the same mechanism as the VPN switch in System Settings. The VPN app itself does not need to run.
/// Status changes arrive as callbacks; nothing is polled.
@Observable
final class VPNService {
    enum State: Equatable {
        case unavailable, disconnected, connecting, connected, disconnecting

        var isOn: Bool { self == .connected }
        var isBusy: Bool { self == .connecting || self == .disconnecting }
    }

    struct ServiceInfo: Identifiable, Hashable {
        let id: String
        let name: String
        let providerBundleID: String?
        let displayName: String
    }

    private(set) var state: State = .unavailable
    private(set) var services: [ServiceInfo] = []
    private(set) var current: ServiceInfo?

    @ObservationIgnored private var connection: SCNetworkConnection?
    @ObservationIgnored private let settings: Settings

    init(settings: Settings) {
        self.settings = settings
        reload()
    }

    var displayName: String { current?.displayName ?? "VPN" }

    /// Re-reads the list of VPN configurations and re-attaches to the selected one.
    func reload() {
        services = Self.loadServices()
        let preferred = settings.vpnServiceID.flatMap { id in services.first { $0.id == id } }
        let target = preferred ?? services.first(where: Self.isConnected) ?? services.first
        if target?.id != current?.id || connection == nil {
            attach(to: target)
        } else {
            refreshStatus()
        }
    }

    func select(_ service: ServiceInfo) {
        settings.vpnServiceID = service.id
        attach(to: service)
    }

    #if PEEK_DEBUG
    /// Screenshot aid only: shows a state without touching the real VPN.
    func debugShow(_ state: State) { self.state = state }
    #endif

    func refreshStatus() {
        let next = connection.map { Self.map(SCNetworkConnectionGetStatus($0)) } ?? .unavailable
        if next != state { state = next }
    }

    func toggle() {
        guard let connection, let current else { return }
        switch state {
        case .connected, .connecting:
            state = .disconnecting
            if !SCNetworkConnectionStop(connection, true) {
                Self.scutil("stop", current.id)
            }
        case .disconnected, .disconnecting:
            state = .connecting
            // linger: true — a started VPN must outlive Peek (quit, crash restart, reinstall).
            if !SCNetworkConnectionStart(connection, nil, true) {
                Self.scutil("start", current.id)
            }
        case .unavailable:
            break
        }
    }

    // MARK: - Private

    private func attach(to service: ServiceInfo?) {
        if let connection {
            SCNetworkConnectionSetDispatchQueue(connection, nil)
        }
        connection = nil
        current = service
        guard let service else { state = .unavailable; return }

        var context = SCNetworkConnectionContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        let callback: SCNetworkConnectionCallBack = { _, status, info in
            guard let info else { return }
            // Delivered on the main queue (see SCNetworkConnectionSetDispatchQueue below).
            MainActor.assumeIsolated {
                let service = Unmanaged<VPNService>.fromOpaque(info).takeUnretainedValue()
                service.state = VPNService.map(status)
            }
        }

        guard let newConnection = SCNetworkConnectionCreateWithServiceID(
            nil, service.id as CFString, callback, &context)
        else {
            state = .unavailable
            return
        }
        SCNetworkConnectionSetDispatchQueue(newConnection, .main)
        connection = newConnection
        refreshStatus()
    }

    /// Default pick while nothing is chosen in Settings: the profile that is on right now.
    private static func isConnected(_ service: ServiceInfo) -> Bool {
        guard let probe = SCNetworkConnectionCreateWithServiceID(nil, service.id as CFString, nil, nil)
        else { return false }
        return SCNetworkConnectionGetStatus(probe) == .connected
    }

    private static func map(_ status: SCNetworkConnectionStatus) -> State {
        switch status {
        case .connected: .connected
        case .connecting: .connecting
        case .disconnecting: .disconnecting
        case .disconnected: .disconnected
        default: .unavailable
        }
    }

    private static func loadServices() -> [ServiceInfo] {
        guard let prefs = SCPreferencesCreate(nil, "Peek" as CFString, nil),
              let all = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService]
        else { return [] }

        return all.compactMap { service -> ServiceInfo? in
            guard SCNetworkServiceGetEnabled(service),
                  let interface = SCNetworkServiceGetInterface(service),
                  (SCNetworkInterfaceGetInterfaceType(interface) as String?) == "VPN",
                  let id = SCNetworkServiceGetServiceID(service) as String?
            else { return nil }
            let name = (SCNetworkServiceGetName(service) as String?) ?? "VPN"
            let config = SCNetworkInterfaceGetConfiguration(interface) as? [String: Any]
            let provider = config?["NEProviderBundleIdentifier"] as? String
            return ServiceInfo(id: id, name: name, providerBundleID: provider,
                               displayName: appDisplayName(provider: provider) ?? name)
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// "com.example.vpn.PacketTunnel" → app "com.example.vpn" → that app's name.
    private static func appDisplayName(provider: String?) -> String? {
        guard var components = provider?.split(separator: "."), components.count > 1 else { return nil }
        while components.count > 1 {
            components.removeLast()
            let bundleID = components.joined(separator: ".")
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                return FileManager.default.displayName(atPath: url.path)
                    .replacingOccurrences(of: ".app", with: "")
            }
        }
        return nil
    }

    /// Fallback path if the SystemConfiguration call is refused.
    private static func scutil(_ verb: String, _ id: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
        process.arguments = ["--nc", verb, id]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
