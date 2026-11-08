import AppKit

/// Keeps exactly one island per eligible display and rebuilds them when displays change,
/// after sleep/wake and after fast user switching.
final class NotchController {
    private let environment: AppEnvironment
    private var islands: [CGDirectDisplayID: IslandController] = [:]
    private var rebuildTask: Task<Void, Never>?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func start() {
        rebuild()

        let app = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter

        observe(app, NSApplication.didChangeScreenParametersNotification) { $0.scheduleRebuild(after: 0.3) }
        observe(app, .peekLayoutChanged) { $0.scheduleRebuild(after: 0.05) }
        observe(workspace, NSWorkspace.didWakeNotification) {
            $0.environment.systemDidWake()
            $0.scheduleRebuild(after: 1.0)
        }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.scheduleRebuild(after: 0.5) }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.scheduleRebuild(after: 0.5) }
        observe(workspace, NSWorkspace.willSleepNotification) { controller in
            controller.islands.values.forEach { $0.close() }
        }

        #if PEEK_DEBUG
        DebugHooks.install(controller: self)
        #endif
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ handler: @escaping @MainActor (NotchController) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        }
        observers.append((center, token))
    }

    private func scheduleRebuild(after delay: Double) {
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.rebuild()
        }
    }

    private func rebuild() {
        let slots = ScreenSlot.current(settings: environment.settings)
        let wanted = Set(slots.map(\.displayID))

        for (id, island) in islands where !wanted.contains(id) {
            island.tearDown()
            islands[id] = nil
        }
        for slot in slots {
            if let island = islands[slot.displayID] {
                island.update(slot)
                island.ensureVisible()
            } else {
                islands[slot.displayID] = IslandController(slot: slot, environment: environment) { [weak self] opening in
                    self?.islands.values.filter { $0 !== opening }.forEach { $0.close() }
                }
            }
        }
    }

    /// Every island closed and settled (no glass on screen).
    var isIdle: Bool {
        islands.values.allSatisfy { $0.model.phase == .collapsed && !$0.model.glassActive }
    }

    #if PEEK_DEBUG
    var debugIslands: [IslandController] { Array(islands.values) }
    func debugShowSettings() { environment.showSettings() }
    var debugTranslator: TranslatorService { environment.translator }
    var debugSettings: Settings { environment.settings }
    var debugVPN: VPNService { environment.vpn }
    #endif
}

#if PEEK_DEBUG
/// Development-only remote control (compiled only with -DPEEK_DEBUG):
/// `notifyutil`-style distributed notifications to open/close the island for screenshots.
enum DebugHooks {
    static func install(controller: NotchController) {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.lexeler.Peek.debug"), object: nil, queue: .main
        ) { [weak controller] note in
            let command = note.object as? String
            MainActor.assumeIsolated {
                guard let controller else { return }
                switch command {
                case "open":
                    controller.debugIslands.first?.pinned = true
                    controller.debugIslands.first?.open()
                case "close":
                    controller.debugIslands.forEach { $0.pinned = false; $0.close() }
                case "settings": controller.debugShowSettings()
                case "settings-close":
                    NSApp.windows.filter { !($0 is NSPanel) && $0.isVisible }.forEach { $0.close() }
                case "copy": controller.debugTranslator.copyOutput()
                case let text? where text.hasPrefix("indicator:"):
                    if let style = IndicatorStyle(rawValue: String(text.dropFirst(10))) {
                        controller.debugSettings.indicator = style
                    }
                case let text? where text.hasPrefix("rim:"):
                    let v = text.dropFirst(4).split(separator: ",").compactMap { Double($0) }
                    if v.count == 4 {
                        CollapsedIndicator.rim = .init(width: v[0], blur: v[1], on: v[2], off: v[3])
                        let current = controller.debugSettings.indicator
                        controller.debugSettings.indicator = .none
                        controller.debugSettings.indicator = current
                    }
                case "vpn-off": controller.debugVPN.debugShow(.disconnected)
                case "vpn-on": controller.debugVPN.debugShow(.connected)
                case "vpn-connecting": controller.debugVPN.debugShow(.connecting)
                case let text? where text.hasPrefix("top:"):
                    if let style = TopStyle(rawValue: String(text.dropFirst(4))) {
                        controller.debugSettings.topStyle = style
                    }
                case let text? where text.hasPrefix("transparency:"):
                    if let value = Double(text.dropFirst(13)) { controller.debugSettings.transparency = value }
                case let text? where text.hasPrefix("material:"):
                    if let style = GlassStyle(rawValue: String(text.dropFirst(9))) {
                        controller.debugSettings.glass = style
                    }
                case let text? where text.hasPrefix("type:"):
                    controller.debugTranslator.input = String(text.dropFirst(5))
                default: break
                }
            }
        }
    }
}
#endif
