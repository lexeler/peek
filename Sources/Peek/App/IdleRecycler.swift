import AppKit
import Darwin

/// Quietly restarts Peek after a long idle stretch to give memory back.
///
/// Once the panel has been used, SwiftUI / Metal / Liquid Glass keep ~15 MB of one-time state plus
/// allocator fragmentation that never shrinks back. When the panel has stayed closed for a while,
/// Peek exits with a non-zero status and launchd (KeepAlive) immediately starts a fresh copy (~13 MB).
/// The black island over the notch is gone for a fraction of a second; nothing else is visible.
///
/// Zero idle cost: a single deferred task per close, no polling. Only active under launchd —
/// a manually started Peek would simply quit.
final class IdleRecycler {
    /// Overridable for testing: `defaults write com.lexeler.Peek recycleAfterIdleSeconds 20`.
    static let defaultIdle: Double = 15 * 60
    private static let footprintThreshold: UInt64 = 20 * 1024 * 1024
    /// Any non-zero status makes launchd restart the job (KeepAlive.SuccessfulExit = false).
    private static let restartStatus: Int32 = 75 // EX_TEMPFAIL

    /// Whether it's safe right now (panel closed, no settings window, nothing in flight).
    var canRecycle: () -> Bool = { false }
    /// Last chance to stop helper processes cleanly.
    var willRecycle: () -> Void = {}

    private var task: Task<Void, Never>?

    private var idleDelay: Double {
        let custom = UserDefaults.standard.double(forKey: "recycleAfterIdleSeconds")
        return custom > 0 ? custom : Self.defaultIdle
    }

    func panelOpened() {
        task?.cancel()
        task = nil
    }

    func panelClosed() {
        guard LaunchAgent.launchedByAgent else { return }
        schedule(after: idleDelay)
    }

    private func schedule(after seconds: Double) {
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            self.task = nil
            self.recycleIfWorthIt()
        }
    }

    private func recycleIfWorthIt() {
        guard let footprint = Self.footprint(), footprint > Self.footprintThreshold else { return }
        guard canRecycle() else {
            schedule(after: 60) // busy right now — look again in a minute
            return
        }
        willRecycle()
        exit(Self.restartStatus)
    }

    /// The same number Activity Monitor shows as "Memory".
    static func footprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }
}
