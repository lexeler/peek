import AppKit
@preconcurrency import Translation

/// RU ⇄ EN translation with Apple's on-device Translation framework.
///
/// The framework never runs inside Peek: a `Peek --translator` helper process is spawned on the
/// first translation and dismissed 90 s after the panel closes (see `TranslatorHelper`).
/// Direction is detected from the text.
@Observable
final class TranslatorService {
    enum Direction: Equatable {
        case ruToEn, enToRu

        var source: String { self == .ruToEn ? "ru" : "en" }
        var target: String { self == .ruToEn ? "en" : "ru" }
        var label: String { self == .ruToEn ? "RU → EN" : "EN → RU" }
        var flipped: Direction { self == .ruToEn ? .enToRu : .ruToEn }
    }

    enum Phase: Equatable { case idle, translating, done, needsLanguages, failed }

    var input = "" {
        didSet { if input != oldValue { inputChanged(previous: oldValue) } }
    }

    private(set) var output = ""
    private(set) var direction: Direction = .ruToEn
    private(set) var phase: Phase = .idle
    /// Last known state of the RU/EN language assets (persisted; refreshed on failures and in Settings).
    private(set) var languagesReady: Bool {
        didSet { UserDefaults.standard.set(languagesReady, forKey: Self.readyKey) }
    }
    private(set) var copiedAt: Date?
    /// True from the Download button until the system reports both languages installed.
    private(set) var isDownloading = false
    /// Drives SwiftUI's `.translationTask` in the Settings window (the only UI-capable session).
    private(set) var downloadRequest: TranslationSession.Configuration?

    /// The last phrase survives this long after the panel closes, then the line starts empty again.
    static let retention: Duration = .seconds(300)
    /// The helper process lingers this long after the panel closes, then exits.
    static let helperIdle: Duration = .seconds(90)
    private static let readyKey = "translatorLanguagesReady"

    @ObservationIgnored private var manualDirection: Direction?
    @ObservationIgnored private var job: Task<Void, Never>?
    @ObservationIgnored private var resetTask: Task<Void, Never>?
    @ObservationIgnored private var helperStopTask: Task<Void, Never>?
    @ObservationIgnored private var downloadWatch: Task<Void, Never>?
    @ObservationIgnored private var helper: TranslatorHelperClient?
    @ObservationIgnored private var helperGeneration = 0
    @ObservationIgnored private var nextRequestID = 0
    @ObservationIgnored private var pending: [Int: CheckedContinuation<TranslatorProtocol.Response?, Never>] = [:]
    @ObservationIgnored private var panelOpen = false

    init() {
        languagesReady = UserDefaults.standard.object(forKey: Self.readyKey) as? Bool ?? true
    }

    // MARK: - Panel lifecycle

    func activate() {
        panelOpen = true
        resetTask?.cancel()
        resetTask = nil
        helperStopTask?.cancel()
        helperStopTask = nil
    }

    func deactivate() {
        panelOpen = false
        armHelperIdleStop()
        resetTask?.cancel()
        resetTask = Task { [weak self] in
            try? await Task.sleep(for: Self.retention)
            guard !Task.isCancelled else { return }
            self?.reset()
        }
    }

    func shutdown() {
        stopHelper()
    }

    // MARK: - User actions

    func flipDirection() {
        manualDirection = direction.flipped
        direction = direction.flipped
        retranslate(immediately: true)
    }

    func clear() {
        input = ""
    }

    func copyOutput() {
        guard !output.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(output, forType: .string)
        copiedAt = Date()
    }

    // MARK: - Language assets

    /// Starts the one-time download of the RU/EN language assets.
    /// The download itself runs in a system daemon; Peek only watches its status while it is in flight.
    func startDownload() {
        guard !isDownloading, !languagesReady else { return }
        isDownloading = true
        downloadRequest = TranslationSession.Configuration(source: Locale.Language(identifier: "ru"),
                                                           target: Locale.Language(identifier: "en"))
        downloadWatch?.cancel()
        downloadWatch = Task { [weak self] in
            for _ in 0..<600 { // give up after ~20 minutes
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                await self.checkLanguages()
                if self.languagesReady { break }
            }
            self?.isDownloading = false
            self?.downloadRequest = nil
        }
    }

    /// Called with the session SwiftUI provides; shows the system download prompt if needed.
    func prepareDownload(using session: TranslationSession) async {
        do {
            try await session.prepareTranslation()
        } catch is CancellationError {
            // The settings window closed; the system keeps downloading and the watch keeps polling.
        } catch {
            // Declined or failed: stop pretending to download.
            downloadWatch?.cancel()
            downloadWatch = nil
            isDownloading = false
            downloadRequest = nil
            await checkLanguages()
        }
    }

    /// Asks the helper whether both languages are installed.
    func checkLanguages() async {
        guard let response = await request(.init(id: 0, op: .check)), let ready = response.ready else { return }
        languagesReady = ready
        if ready, phase == .needsLanguages {
            retranslate(immediately: true)
        } else if !ready, !input.isEmpty {
            phase = .needsLanguages
        }
    }

    // MARK: - Translation

    private func reset() {
        job?.cancel()
        manualDirection = nil
        copiedAt = nil
        input = ""
    }

    private func inputChanged(previous: String) {
        copiedAt = nil
        // Paste / dictation / replace-all arrive as one bulk change: that's a new phrase, so
        // forget a manual direction flip and translate right away (no typing debounce).
        let bulk = abs(input.count - previous.count) > 1
        if previous.isEmpty || input.isEmpty || bulk { manualDirection = nil }
        retranslate(immediately: bulk)
    }

    private func retranslate(immediately: Bool) {
        job?.cancel()
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            output = ""
            phase = .idle
            return
        }
        direction = manualDirection ?? Self.detect(text)
        let direction = self.direction
        job = Task { [weak self] in
            if !immediately { try? await Task.sleep(for: .milliseconds(260)) }
            guard !Task.isCancelled else { return }
            await self?.translate(text, direction: direction)
        }
    }

    private func translate(_ text: String, direction: Direction) async {
        if phase != .done { phase = .translating }
        let response = await request(.init(id: 0, op: .translate, text: text,
                                           source: direction.source, target: direction.target))
        guard !Task.isCancelled else { return }
        if let translated = response?.text {
            output = translated
            phase = .done
            if !languagesReady { languagesReady = true }
        } else if response?.error == "notInstalled" {
            languagesReady = false
            phase = .needsLanguages
        } else {
            phase = .failed
        }
    }

    /// Cyrillic-majority text is Russian, Latin-majority is English.
    static func detect(_ text: String) -> Direction {
        var cyrillic = 0
        var latin = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0400...0x04FF: cyrillic += 1
            case 0x41...0x5A, 0x61...0x7A: latin += 1
            default: break
            }
        }
        return latin > cyrillic ? .enToRu : .ruToEn
    }

    // MARK: - Helper process

    /// Sends one request to the helper (spawning it if needed); nil if the helper is unavailable.
    private func request(_ template: TranslatorProtocol.Request) async -> TranslatorProtocol.Response? {
        guard let helper = ensureHelper() else { return nil }
        nextRequestID &+= 1
        let request = TranslatorProtocol.Request(id: nextRequestID, op: template.op, text: template.text,
                                                 source: template.source, target: template.target)
        let id = request.id
        let response = await withCheckedContinuation { continuation in
            pending[id] = continuation
            helper.send(request)
        }
        armHelperIdleStop()
        return response
    }

    private func ensureHelper() -> TranslatorHelperClient? {
        if let helper { return helper }
        helperGeneration &+= 1
        let generation = helperGeneration
        let client = TranslatorHelperClient { [weak self] response in
            Task { @MainActor in self?.pending.removeValue(forKey: response.id)?.resume(returning: response) }
        } onExit: { [weak self] in
            Task { @MainActor in
                guard let self, self.helperGeneration == generation else { return }
                self.helper = nil
                self.failPending()
            }
        }
        do {
            try client.start()
        } catch {
            return nil
        }
        helper = client
        return client
    }

    /// The helper exits after `helperIdle` without the panel open (e.g. after a Settings check).
    private func armHelperIdleStop() {
        guard helper != nil, !panelOpen else { return }
        helperStopTask?.cancel()
        helperStopTask = Task { [weak self] in
            try? await Task.sleep(for: Self.helperIdle)
            guard !Task.isCancelled, let self, !self.panelOpen, !self.isDownloading else { return }
            self.stopHelper()
        }
    }

    private func stopHelper() {
        helperGeneration &+= 1 // ignore the old helper's exit callback
        helper?.stop()
        helper = nil
        failPending()
    }

    private func failPending() {
        let waiting = pending
        pending.removeAll()
        waiting.values.forEach { $0.resume(returning: nil) }
    }
}
