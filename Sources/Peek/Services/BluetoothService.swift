import AppKit
import CoreBluetooth
import IOBluetooth

/// Paired headphones (AirPods, Huawei FreeBuds/FreeClip, …) with one-tap connect/disconnect.
/// Initialised lazily on first panel open, so the permission prompt appears in context.
/// Connection changes arrive as IOBluetooth notifications; nothing is polled.
@Observable
final class BluetoothService {
    enum Access: Equatable { case unknown, allowed, denied, poweredOff }

    struct Device: Identifiable, Equatable {
        let id: String
        let name: String
        let symbol: String
        var isConnected: Bool
        var battery: Int?
        var isBusy: Bool
    }

    private(set) var access: Access = .unknown
    private(set) var devices: [Device] = []

    @ObservationIgnored private var loadedOnce = false
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var observer: Observer?
    @ObservationIgnored private var connectNotification: IOBluetoothUserNotification?
    @ObservationIgnored private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]
    @ObservationIgnored private var busyTimeouts: [String: Task<Void, Never>] = [:]

    /// Called every time the panel opens. Notifications are only registered while it is open:
    /// the list is re-read on every open anyway, so nothing is listened to at rest.
    func activate() {
        switch CBManager.authorization {
        case .denied, .restricted:
            if access != .denied { access = .denied }
            return
        default:
            break
        }
        let observer = self.observer ?? Observer(owner: self)
        self.observer = observer
        if connectNotification == nil {
            connectNotification = IOBluetoothDevice.register(
                forConnectNotifications: observer, selector: #selector(Observer.deviceConnected(_:device:)))
        }
        refreshTask?.cancel()
        if loadedOnce {
            // The previous list is on screen already; re-read after the open animation so the
            // synchronous IOBluetooth calls never land on an animation frame.
            refreshTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(420))
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        } else {
            loadedOnce = true
            refresh()
        }
    }

    /// Called when the panel closes.
    func deactivate() {
        refreshTask?.cancel()
        refreshTask = nil
        connectNotification?.unregister()
        connectNotification = nil
        disconnectNotifications.values.forEach { $0.unregister() }
        disconnectNotifications.removeAll()
    }

    func toggle(_ device: Device) {
        guard let index = devices.firstIndex(where: { $0.id == device.id }),
              !devices[index].isBusy,
              let bt = IOBluetoothDevice(addressString: device.id)
        else { return }

        devices[index].isBusy = true
        armBusyTimeout(for: device.id)
        if bt.isConnected() {
            bt.closeConnection()
        } else {
            // Asynchronous: completion arrives in Observer.connectionComplete(_:status:).
            if bt.openConnection(observer) != kIOReturnSuccess {
                setBusy(false, for: device.id)
            }
        }
    }

    func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Private

    fileprivate func refresh() {
        if IOBluetoothHostController.default()?.powerState != kBluetoothHCIPowerStateON {
            let next: Access = CBManager.authorization == .denied ? .denied : .poweredOff
            if access != next { access = next }
            if !devices.isEmpty { devices = [] }
            return
        }
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        let nextAccess: Access
        if paired.isEmpty, CBManager.authorization != .allowedAlways {
            nextAccess = CBManager.authorization == .denied ? .denied : .unknown
        } else {
            nextAccess = .allowed
        }
        if access != nextAccess { access = nextAccess }

        let busy = Set(devices.filter(\.isBusy).map(\.id))
        let next = paired
            .filter(Self.isHeadphones)
            .compactMap { bt -> Device? in
                guard let address = bt.addressString else { return nil }
                let name = bt.name ?? bt.nameOrAddress ?? "Наушники"
                let connected = bt.isConnected()
                if connected, connectNotification != nil, disconnectNotifications[address] == nil, let observer {
                    disconnectNotifications[address] = bt.register(
                        forDisconnectNotification: observer,
                        selector: #selector(Observer.deviceDisconnected(_:device:)))
                }
                return Device(
                    id: address, name: name, symbol: Self.symbol(for: name),
                    isConnected: connected,
                    battery: connected ? Self.battery(of: bt) : nil,
                    isBusy: busy.contains(address))
            }
            .sorted { lhs, rhs in
                if lhs.isConnected != rhs.isConnected { return lhs.isConnected }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        if next != devices { devices = next }
    }

    /// Main-actor side of every IOBluetooth callback (they arrive on IOBluetooth's own queue).
    fileprivate func connectionChanged(address: String?, disconnected: Bool) {
        guard connectNotification != nil || devices.contains(where: \.isBusy) else { return }
        if let address {
            setBusy(false, for: address)
            if disconnected {
                // The disconnect callback already unregistered itself.
                disconnectNotifications.removeValue(forKey: address)
            } else if IOBluetoothDevice(addressString: address)?.isConnected() == false {
                disconnectNotifications.removeValue(forKey: address)?.unregister()
            }
        }
        refresh()
    }

    private func setBusy(_ busy: Bool, for id: String) {
        if !busy { busyTimeouts.removeValue(forKey: id)?.cancel() }
        if let index = devices.firstIndex(where: { $0.id == id }) {
            devices[index].isBusy = busy
        }
    }

    private func armBusyTimeout(for id: String) {
        busyTimeouts[id]?.cancel()
        busyTimeouts[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled else { return }
            self?.setBusy(false, for: id)
            self?.refresh()
        }
    }

    /// Audio major class with headset / hands-free / headphones minor class.
    /// Speakers (e.g. smart speakers) and non-audio devices are excluded on purpose.
    private static func isHeadphones(_ device: IOBluetoothDevice) -> Bool {
        let major = device.deviceClassMajor
        let minor = device.deviceClassMinor
        if major == 0x04 { return [0x01, 0x02, 0x06].contains(minor) }
        let name = (device.name ?? "").lowercased()
        return ["airpods", "buds", "freeclip", "headphone", "beats"].contains { name.contains($0) }
    }

    private static func symbol(for name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("airpods max") { return "airpods.max" }
        if lower.contains("airpods pro") { return "airpods.pro" }
        if lower.contains("airpods") { return "airpods" }
        if lower.contains("buds") || lower.contains("clip") { return "earbuds" }
        return "headphones"
    }

    /// Battery levels exposed by IOBluetooth for AirPods/HFP devices. Optional and best-effort.
    private static func battery(of device: IOBluetoothDevice) -> Int? {
        let keys = ["batteryPercentSingle", "batteryPercentCombined", "batteryPercentLeft", "batteryPercentRight"]
        var values: [Int] = []
        for key in keys where device.responds(to: NSSelectorFromString(key)) {
            if let value = device.value(forKey: key) as? Int, value > 0, value <= 100 {
                if key == "batteryPercentSingle" || key == "batteryPercentCombined" { return value }
                values.append(value)
            }
        }
        return values.min()
    }

    /// Objective-C target for IOBluetooth callbacks (always delivered on the main run loop).
    /// Objective-C target for IOBluetooth callbacks.
    ///
    /// On macOS 26 IOBluetooth delivers these on its private coordinator queue, not the main thread
    /// (and registering for connect notifications fires immediately for already-connected devices).
    /// So this class is explicitly nonisolated: it only reads the address and hops to the main actor.
    nonisolated private final class Observer: NSObject, @unchecked Sendable {
        weak var owner: BluetoothService?

        init(owner: BluetoothService) { self.owner = owner }

        @objc func deviceConnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
            forward(address: device.addressString, disconnected: false)
        }

        @objc func deviceDisconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
            note.unregister()
            forward(address: device.addressString, disconnected: true)
        }

        @objc func connectionComplete(_ device: IOBluetoothDevice, status: IOReturn) {
            forward(address: device.addressString, disconnected: false)
        }

        private func forward(address: String?, disconnected: Bool) {
            Task { @MainActor [weak self] in
                self?.owner?.connectionChanged(address: address, disconnected: disconnected)
            }
        }
    }
}
