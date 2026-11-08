import AppKit

/// Shared services. One instance for the whole app, shared by every screen's island.
final class AppEnvironment {
    let settings = Settings()
    let vpn: VPNService
    let bluetooth = BluetoothService()
    let nowPlaying = NowPlayingService()
    let translator = TranslatorService()
    let recycler = IdleRecycler()

    private lazy var settingsWindow = SettingsWindowController(environment: self)

    init() {
        vpn = VPNService(settings: settings)
    }

    private var reliefTask: Task<Void, Never>?

    func panelWillOpen() {
        reliefTask?.cancel()
        recycler.panelOpened()
        nowPlaying.activate()
        bluetooth.activate()
        vpn.refreshStatus()
        translator.activate()
    }

    func panelDidClose() {
        nowPlaying.deactivate()
        bluetooth.deactivate()
        translator.deactivate()
        recycler.panelClosed()
        // Rendering the open panel leaves freed-but-dirty malloc pages behind; hand them back once
        // things have settled (after the music stream's grace period).
        reliefTask?.cancel()
        reliefTask = Task {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            malloc_zone_pressure_relief(nil, 0)
        }
    }

    func showSettings() {
        vpn.reload()
        settingsWindow.show()
    }

    func systemDidWake() {
        vpn.reload()
    }

    func shutdown() {
        nowPlaying.stopStream()
        translator.shutdown()
    }
}
