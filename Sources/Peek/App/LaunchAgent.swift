import AppKit

/// Start-at-login + crash recovery through a per-user launchd agent.
///
/// `KeepAlive.SuccessfulExit = false` means launchd relaunches Peek only when it dies abnormally
/// (crash, kill). Quitting from the menu exits with status 0 and is respected.
/// No StandardOutPath / StandardErrorPath: nothing is ever written to disk.
enum LaunchAgent {
    static let label = "com.lexeler.Peek.agent"
    static let agentFlag = "--agent"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/LaunchAgents/\(label).plist")
    }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    static var launchedByAgent: Bool { CommandLine.arguments.contains(agentFlag) }

    /// Set once start-at-login was installed or turned off, so the first-launch default never
    /// overrides a choice made in Settings.
    private static let decidedKey = "launchAgentDecided"

    /// A copy that was just dragged into Applications (e.g. from a shared zip): start at login by
    /// default, like `build.sh --install`. Not for builds elsewhere or a translocated (quarantined) copy.
    static var shouldEnableOnFirstLaunch: Bool {
        guard !isInstalled, !UserDefaults.standard.bool(forKey: decidedKey),
              let path = Bundle.main.executablePath
        else { return false }
        return path.contains("/Applications/") && !path.contains("/AppTranslocation/")
    }

    private static var domain: String { "gui/\(getuid())" }
    private static var service: String { "\(domain)/\(label)" }

    /// Writes the agent plist pointing at the current executable and (re)loads it.
    /// Loading starts a launchd-owned instance immediately (RunAtLoad).
    @discardableResult
    static func install() -> Bool {
        guard let executable = Bundle.main.executableURL?.path else { return false }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable, agentFlag],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
            "ThrottleInterval": 3,
        ]
        do {
            try FileManager.default.createDirectory(
                at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
        } catch {
            return false
        }
        UserDefaults.standard.set(true, forKey: decidedKey)
        // Running as this job's own process: it is still loaded (turning the toggle off only removes
        // the plist), so rewriting the plist is enough. Booting it out here would SIGTERM ourselves.
        if launchedByAgent { return true }
        launchctl("bootout", service)
        return launchctl("bootstrap", domain, plistURL.path) == 0
    }

    /// The executable the agent plist points at, if any.
    static var registeredExecutable: String? {
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let arguments = plist["ProgramArguments"] as? [String]
        else { return nil }
        return arguments.first
    }

    /// Removes start-at-login. With `stopRunning == false` the current launchd job keeps running
    /// until the user quits or logs out, so turning the toggle off never kills the app under you.
    static func uninstall(stopRunning: Bool) {
        UserDefaults.standard.set(true, forKey: decidedKey)
        try? FileManager.default.removeItem(at: plistURL)
        if stopRunning { launchctl("bootout", service) }
    }

    /// Asks launchd to start the agent's instance if it is not running yet.
    @discardableResult
    static func kickstart() -> Bool {
        if launchctl("kickstart", service) == 0 { return true }
        // The plist exists but the job was never loaded in this session (e.g. copied manually).
        return launchctl("bootstrap", domain, plistURL.path) == 0
    }

    @discardableResult
    private static func launchctl(_ arguments: String...) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}

/// Guarantees a single running Peek and that, when start-at-login is enabled,
/// the running copy is the launchd-owned one (so crashes are recovered automatically).
enum InstanceGuard {
    static func claim() -> Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        let bundleID = Bundle.main.bundleIdentifier ?? "com.lexeler.Peek"
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != me }

        if LaunchAgent.launchedByAgent {
            // launchd's instance always wins; politely retire any manually opened copy.
            others.forEach { $0.terminate() }
            return true
        }
        if LaunchAgent.isInstalled,
           LaunchAgent.registeredExecutable == Bundle.main.executablePath {
            // Opened from Finder/Spotlight: hand over to launchd (no-op if it is already running).
            if LaunchAgent.kickstart() { return false }
        }
        // First launch after being dragged into Applications: launchd starts its own instance
        // right away (RunAtLoad), which takes over from this one.
        if others.isEmpty, LaunchAgent.shouldEnableOnFirstLaunch, LaunchAgent.install() { return false }
        // A different copy (e.g. a fresh build elsewhere) runs unmanaged — never silently swaps binaries.
        return others.isEmpty
    }
}
