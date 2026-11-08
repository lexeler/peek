import AppKit
import SwiftUI

/// Observable UI state of one island.
@Observable
final class NotchModel {
    enum Phase { case collapsed, peeking, expanded }

    var phase: Phase = .collapsed
    var geometry: IslandGeometry
    /// Liquid Glass is only in the view tree while open/animating — no backdrop work at rest.
    var glassActive = false
    /// Incremented to ask the translator field to take focus and select its text.
    var focusToken = 0
    /// Height used for pointer hit-testing while open. Not read by any view.
    @ObservationIgnored private(set) var expandedHeight: CGFloat = 230
    @ObservationIgnored private var shrinkTask: Task<Void, Never>?
    @ObservationIgnored private var pendingHeight: CGFloat?

    init(geometry: IslandGeometry) {
        self.geometry = geometry
    }

    /// Each open starts from the designed minimum (see `expandedScreenRect`) and grows from there.
    func resetHeight() {
        shrinkTask?.cancel()
        shrinkTask = nil
        pendingHeight = nil
        expandedHeight = 0
    }

    /// Growth applies at once; shrinking waits for the resize spring, so the panel can't close
    /// under a pointer that is still visibly inside it.
    func reportHeight(_ height: CGFloat) {
        if height >= expandedHeight {
            shrinkTask?.cancel()
            shrinkTask = nil
            pendingHeight = nil
            expandedHeight = height
            return
        }
        pendingHeight = height // a running shrink picks up the latest value; no task per frame
        guard shrinkTask == nil else { return }
        shrinkTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard let self, !Task.isCancelled else { return }
            self.shrinkTask = nil
            if let pending = self.pendingHeight { self.expandedHeight = pending }
            self.pendingHeight = nil
        }
    }
}

/// Callbacks from the SwiftUI tree to the controller.
struct IslandActions {
    var hover: (Bool) -> Void
    var open: () -> Void
    var close: () -> Void
    var openSettings: () -> Void
    var quit: () -> Void
}

enum Motion {
    static var reduce: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var open: Animation { reduce ? .smooth(duration: 0.2) : .spring(duration: 0.32, bounce: 0.08) }
    static var close: Animation { reduce ? .smooth(duration: 0.15) : .spring(duration: 0.22, bounce: 0) }
    static var peek: Animation { reduce ? .smooth(duration: 0.15) : .spring(duration: 0.26, bounce: 0.2) }
    static var resize: Animation { reduce ? .smooth(duration: 0.2) : .spring(duration: 0.34, bounce: 0) }
}

/// Owns one screen's panel: hover intent, open/close, keyboard focus hand-off.
/// Pointer monitors exist only while the island is open, so the idle cost is zero.
final class IslandController {
    let model: NotchModel
    private(set) var slot: ScreenSlot
    private let panel: NotchPanel
    private unowned let environment: AppEnvironment
    private let onWillOpen: (IslandController) -> Void

    private var openTask: Task<Void, Never>?
    private var monitors: [Any] = []
    /// When pinned the island ignores the pointer leaving / outside clicks (used for screenshots).
    var pinned = false

    /// Sub-pixel tolerance only: leaving the visible panel closes it immediately.
    private static let exitMargin: CGFloat = 1

    init(slot: ScreenSlot, environment: AppEnvironment, onWillOpen: @escaping (IslandController) -> Void) {
        self.slot = slot
        self.environment = environment
        self.onWillOpen = onWillOpen
        model = NotchModel(geometry: slot.geometry)
        panel = NotchPanel(frame: slot.collapsedWindowFrame)

        let actions = IslandActions(
            hover: { [weak self] inside in self?.hoverChanged(inside) },
            open: { [weak self] in self?.open() },
            close: { [weak self] in self?.close() },
            openSettings: { [weak self] in
                self?.close()
                environment.showSettings()
            },
            quit: { NSApp.terminate(nil) })

        let root = NotchRootView(model: model, actions: actions)
            .environment(environment.settings)
            .environment(environment.vpn)
            .environment(environment.bluetooth)
            .environment(environment.nowPlaying)
            .environment(environment.translator)

        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        host.safeAreaRegions = []
        host.frame = CGRect(origin: .zero, size: slot.collapsedWindowFrame.size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        panel.onCommandComma = actions.openSettings
        panel.orderFrontRegardless()
    }

    func update(_ newSlot: ScreenSlot) {
        guard newSlot != slot else { return }
        slot = newSlot
        model.geometry = newSlot.geometry
        panel.setFrame(currentFrame, display: true)
    }

    /// Re-asserts the panel after sleep, Space or display changes.
    func ensureVisible() {
        panel.setFrame(currentFrame, display: false)
        panel.orderFrontRegardless()
    }

    /// Large only while open or animating; tiny at rest.
    private var currentFrame: CGRect {
        model.phase == .expanded || model.glassActive ? slot.windowFrame : slot.collapsedWindowFrame
    }

    func tearDown() {
        close()
        removeMonitors()
        panel.orderOut(nil)
        panel.close()
    }

    // MARK: - Hover / open / close

    private func hoverChanged(_ inside: Bool) {
        switch model.phase {
        case .expanded:
            // Becoming key rebuilds tracking areas and can report a false exit — verify the real pointer.
            if !inside { evaluatePointer() }
        case .collapsed, .peeking:
            if inside {
                guard openTask == nil else { return }
                withAnimation(Motion.peek) { model.phase = .peeking }
                let delay = environment.settings.hoverDelay
                openTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(delay))
                    guard !Task.isCancelled else { return }
                    self?.open()
                }
            } else {
                openTask?.cancel()
                openTask = nil
                if model.phase == .peeking {
                    withAnimation(Motion.close) { model.phase = .collapsed }
                }
            }
        }
    }

    func open() {
        openTask?.cancel()
        openTask = nil
        guard model.phase != .expanded else { return }
        onWillOpen(self)
        environment.panelWillOpen()
        // Grow the (transparent) window first; content is pinned top-centre, so nothing moves.
        panel.setFrame(slot.windowFrame, display: false)
        model.glassActive = true
        withAnimation(Motion.open) { model.phase = .expanded }
        panel.allowsKey = true
        panel.makeKeyAndOrderFront(nil)
        model.focusToken &+= 1
        installMonitors()
    }

    func close() {
        openTask?.cancel()
        openTask = nil
        guard model.phase != .collapsed else { return }
        let wasExpanded = model.phase == .expanded
        removeMonitors()
        withAnimation(Motion.close) {
            model.phase = .collapsed
        } completion: { [weak self] in
            guard let self, self.model.phase == .collapsed else { return }
            self.model.glassActive = false
            self.panel.setFrame(self.slot.collapsedWindowFrame, display: true)
        }
        if wasExpanded {
            model.resetHeight()
            relinquishKeyFocus()
            environment.panelDidClose()
        }
    }

    /// Hands keyboard focus back to the app the user was working in.
    private func relinquishKeyFocus() {
        panel.allowsKey = false
        guard panel.isKeyWindow else { return }
        panel.makeFirstResponder(nil)
        panel.orderOut(nil)
        panel.orderFrontRegardless()
    }

    // MARK: - Pointer tracking while open

    private var expandedScreenRect: CGRect {
        let geometry = model.geometry
        let width = geometry.expandedTotalWidth
        // Never smaller than the designed panel, so a mid-animation measurement can't close it under the cursor.
        let height = geometry.topInset + max(model.expandedHeight, geometry.expandedMinimumHeight)
        return CGRect(x: slot.anchorX - width / 2, y: slot.screenTop - height,
                      width: width, height: height + 2)
    }

    private func pointerIsNear() -> Bool {
        expandedScreenRect.insetBy(dx: -Self.exitMargin, dy: -Self.exitMargin).contains(NSEvent.mouseLocation)
    }

    /// Closes the moment the pointer leaves the panel — no grace period.
    private func evaluatePointer() {
        guard model.phase == .expanded, !pinned else { return }
        if !pointerIsNear() { close() }
    }

    private func clickedOutside() {
        guard model.phase == .expanded, !pinned else { return }
        if !expandedScreenRect.contains(NSEvent.mouseLocation) { close() }
    }

    private func installMonitors() {
        removeMonitors()
        panel.acceptsMouseMovedEvents = true
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { [weak self] _ in
            self?.evaluatePointer()
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: moves, handler: { [weak self] event in
            self?.evaluatePointer()
            return event
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] _ in
            self?.clickedOutside()
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: clicks, handler: { [weak self] event in
            self?.clickedOutside()
            return event
        }) { monitors.append(monitor) }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        panel.acceptsMouseMovedEvents = false
    }
}
