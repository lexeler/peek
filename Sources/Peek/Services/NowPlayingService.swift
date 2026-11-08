import AppKit
import ImageIO

/// System "Now Playing" (Yandex Music, browsers, Apple Music, …).
///
/// Since macOS 15.4 only Apple-entitled processes may read MediaRemote, so data comes from the
/// bundled mediaremote-adapter running under /usr/bin/perl. The stream process lives only while
/// the panel is open (+ a short grace period): zero cost while the notch is idle.
@Observable
final class NowPlayingService {
    struct Track: Equatable {
        var title: String
        var artist: String
        var bundleID: String?
        var duration: Double
        var elapsed: Double
        var timestamp: Date
        var rate: Double
        var playing: Bool

        /// Elapsed playback time extrapolated to `date`.
        func elapsed(at date: Date) -> Double {
            guard playing else { return elapsed }
            let value = elapsed + date.timeIntervalSince(timestamp) * max(rate, 0)
            return duration > 0 ? min(value, duration) : value
        }
    }

    private(set) var track: Track?
    private(set) var artwork: CGImage?
    private(set) var isAvailable: Bool

    @ObservationIgnored private let adapter: AdapterPaths?
    @ObservationIgnored private var stream: AdapterStream?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var clearTask: Task<Void, Never>?
    @ObservationIgnored private var stopTask: Task<Void, Never>?

    init() {
        adapter = AdapterPaths.locate()
        isAvailable = adapter != nil
    }

    func activate() {
        stopTask?.cancel()
        stopTask = nil
        guard stream == nil, let adapter else { return }
        // Callbacks from a previous (stopped) stream must never touch the current one.
        generation &+= 1
        let generation = self.generation
        let stream = AdapterStream(paths: adapter) { [weak self] snapshot in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.apply(snapshot)
            }
        } onExit: { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.stream = nil
            }
        }
        self.stream = stream
        stream.start()
    }

    func deactivate() {
        stopTask?.cancel()
        stopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.stopStream()
        }
    }

    func stopStream() {
        stream?.stop()
        stream = nil
    }

    func togglePlayPause() {
        send(2)
        guard var current = track else { return }
        let now = Date()
        current.elapsed = current.elapsed(at: now)
        current.timestamp = now
        current.playing.toggle()
        track = current
    }

    func next() { send(4) }
    func previous() { send(5) }

    func openPlayer() {
        let bundleID = track?.bundleID ?? "ru.yandex.desktop.music"
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "ru.yandex.desktop.music")
        else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - Private

    private func apply(_ snapshot: AdapterStream.Snapshot) {
        guard let title = snapshot.title, !title.isEmpty else {
            // "{}" means nothing is playing — but the adapter also emits one empty payload right
            // before the first real one, so clear only if nothing arrives shortly after.
            clearTask?.cancel()
            clearTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self else { return }
                self.track = nil
                self.artwork = nil
            }
            return
        }
        clearTask?.cancel()
        clearTask = nil
        let next = Track(
            title: title,
            artist: snapshot.artist ?? "",
            bundleID: snapshot.bundleID,
            duration: snapshot.duration,
            elapsed: snapshot.elapsed,
            timestamp: snapshot.timestamp,
            rate: snapshot.rate,
            playing: snapshot.playing)
        if next != track { track = next }
        if snapshot.artworkChanged {
            artwork = snapshot.artwork?.image
        }
    }

    private func send(_ command: Int) {
        guard let adapter else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [adapter.script, adapter.framework, "send", String(command)]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}

nonisolated struct AdapterPaths: Sendable {
    let script: String
    let framework: String

    static func locate() -> AdapterPaths? {
        let bundle = Bundle.main
        guard let script = bundle.path(forResource: "mediaremote-adapter", ofType: "pl"),
              let frameworks = bundle.privateFrameworksPath
        else { return nil }
        let framework = (frameworks as NSString).appendingPathComponent("MediaRemoteAdapter.framework")
        guard FileManager.default.fileExists(atPath: framework),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/perl")
        else { return nil }
        return AdapterPaths(script: script, framework: framework)
    }
}

/// Owns the perl stream process. Reads and parses JSON lines off the main thread.
nonisolated final class AdapterStream: @unchecked Sendable {
    struct ImageBox: @unchecked Sendable { let image: CGImage }

    struct Snapshot: Sendable {
        var isEmpty = true
        var title: String?
        var artist: String?
        var bundleID: String?
        var duration: Double = 0
        var elapsed: Double = 0
        var timestamp = Date()
        var rate: Double = 0
        var playing = false
        var artwork: ImageBox?
        var artworkChanged = false
    }

    /// Runs the adapter as a child and kills it as soon as our end of stdin closes —
    /// so the adapter can never outlive Peek, even after a crash or SIGKILL.
    /// SIGKILL, not TERM: the adapter only honours TERM once its run loop is running,
    /// and it has nothing to flush.
    private static let watchdog = """
    use POSIX ();
    my $pid = fork();
    POSIX::_exit(1) unless defined $pid;
    if ($pid == 0) { open(STDIN, '<', '/dev/null'); exec('/usr/bin/perl', @ARGV); POSIX::_exit(127); }
    close(STDOUT);
    $SIG{CHLD} = sub { POSIX::_exit(0) };
    $SIG{TERM} = sub { kill('KILL', $pid); POSIX::_exit(0) };
    my $buf; 1 while sysread(STDIN, $buf, 64);
    kill('KILL', $pid); POSIX::_exit(0);
    """

    private let paths: AdapterPaths
    private let onSnapshot: @Sendable (Snapshot) -> Void
    private let onExit: @Sendable () -> Void
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private var buffer = Data()
    /// Full state rebuilt from the adapter's full payloads + diffs (diffs keep artwork out of
    /// every event — it is sent once per track).
    private var merged: [String: Any] = [:]
    private var lastArtworkKey: Int?
    private let dateParser = ISO8601DateFormatter()

    init(paths: AdapterPaths,
         onSnapshot: @escaping @Sendable (Snapshot) -> Void,
         onExit: @escaping @Sendable () -> Void) {
        self.paths = paths
        self.onSnapshot = onSnapshot
        self.onExit = onExit
    }

    func start() {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", Self.watchdog, paths.script, paths.framework, "stream", "--debounce=40"]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            self?.stdoutPipe.fileHandleForReading.readabilityHandler = nil
            self?.onExit()
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self.consume(data)
        }
        do {
            try process.run()
        } catch {
            onExit()
        }
    }

    func stop() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        try? stdinPipe.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    // Called serially on the pipe's reading queue.
    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let snapshot = parse(line) { onSnapshot(snapshot) }
        }
        if buffer.count > 8 * 1024 * 1024 { buffer.removeAll() } // corrupt stream guard
    }

    private func parse(_ line: Data) -> Snapshot? {
        guard !line.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        else { return nil }
        let payload = (object["payload"] as? [String: Any]) ?? [:]
        let isDiff = (object["diff"] as? Bool) ?? false
        if isDiff {
            for (key, value) in payload {
                if value is NSNull { merged.removeValue(forKey: key) } else { merged[key] = value }
            }
        } else {
            merged = payload
        }

        var snapshot = Snapshot()
        snapshot.isEmpty = merged.isEmpty
        snapshot.title = merged["title"] as? String
        snapshot.artist = merged["artist"] as? String
        snapshot.bundleID = (merged["parentApplicationBundleIdentifier"] as? String)
            ?? (merged["bundleIdentifier"] as? String)
        snapshot.duration = Self.finite(merged["duration"])
        snapshot.elapsed = Self.finite(merged["elapsedTime"])
        snapshot.rate = Self.finite(merged["playbackRate"])
        snapshot.playing = (merged["playing"] as? Bool) ?? (snapshot.rate > 0)
        if let stamp = merged["timestamp"] as? String, let date = dateParser.date(from: stamp) {
            snapshot.timestamp = date
        }

        // Artwork only when this event actually carries it (or replaces everything).
        // NSString length/hash is O(1) — hashing a multi-megabyte Swift String is not.
        if !isDiff || payload["artworkData"] != nil {
            let artwork = merged["artworkData"] as? NSString
            let key = artwork.map { $0.length ^ $0.hash }
            if key != lastArtworkKey {
                lastArtworkKey = key
                snapshot.artworkChanged = true
                if let artwork, let data = Data(base64Encoded: artwork as String, options: .ignoreUnknownCharacters) {
                    snapshot.artwork = Self.thumbnail(data).map(ImageBox.init)
                }
            }
        }
        return snapshot
    }

    private static func finite(_ value: Any?) -> Double {
        guard let number = value as? Double, number.isFinite, number >= 0 else { return 0 }
        return number
    }

    /// Downscaled to what the UI draws (64 pt @2x) — keeps memory flat.
    private static func thumbnail(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 160,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
