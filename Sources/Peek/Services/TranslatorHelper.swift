import Foundation
@preconcurrency import Translation

/// Line-delimited JSON protocol between Peek and its translation helper process.
nonisolated enum TranslatorProtocol {
    struct Request: Codable, Sendable {
        enum Operation: String, Codable, Sendable { case translate, check }
        let id: Int
        let op: Operation
        var text: String?
        var source: String?
        var target: String?
    }

    struct Response: Codable, Sendable {
        let id: Int
        var text: String?
        /// "notInstalled" or "failed".
        var error: String?
        /// For `check`: both RU→EN and EN→RU assets are installed.
        var ready: Bool?
    }
}

/// `Peek --translator`: a short-lived child process that hosts Apple's Translation framework.
///
/// Why a separate process: once any process touches Translation, the framework keeps a 15-second
/// heartbeat (with system log lines) running for the rest of that process's life. Hosting it here
/// lets Peek drop it completely — the helper exits as soon as Peek closes its stdin (idle timeout,
/// quit or crash), so it can never outlive Peek.
enum TranslatorHelper {
    static func run() async {
        var sessions: [String: TranslationSession] = [:]
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()

        func reply(_ response: TranslatorProtocol.Response) {
            guard var data = try? encoder.encode(response) else { return }
            data.append(0x0A)
            FileHandle.standardOutput.write(data) // parent gone → SIGPIPE → we exit, as intended
        }

        do {
            for try await line in FileHandle.standardInput.bytes.lines {
                guard let request = try? decoder.decode(TranslatorProtocol.Request.self, from: Data(line.utf8))
                else { continue }

                switch request.op {
                case .check:
                    reply(.init(id: request.id, ready: await languagesInstalled()))

                case .translate:
                    guard let text = request.text, let source = request.source, let target = request.target else {
                        reply(.init(id: request.id, error: "failed"))
                        continue
                    }
                    let key = "\(source)>\(target)"
                    let sourceLanguage = Locale.Language(identifier: source)
                    let targetLanguage = Locale.Language(identifier: target)
                    // The system's translationd exits when idle. The first request after that wakes it,
                    // but fails its preflight ("waiting on downloads", TranslationErrorDomain 16) before
                    // the daemon is up — and meanwhile even reports the languages as missing.
                    // So retry on a fresh session before believing anything is wrong.
                    var translated: String?
                    for delay in [0, 500, 1000, 2000] {
                        if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
                        do {
                            let session = sessions[key]
                                ?? TranslationSession(installedSource: sourceLanguage, target: targetLanguage)
                            sessions[key] = session
                            translated = try await session.translate(text).targetText
                            break
                        } catch {
                            sessions[key] = nil
                        }
                    }
                    if let translated {
                        reply(.init(id: request.id, text: translated))
                    } else {
                        let status = await LanguageAvailability().status(from: sourceLanguage, to: targetLanguage)
                        reply(.init(id: request.id, error: status == .installed ? "failed" : "notInstalled"))
                    }
                }
            }
        } catch {
            // stdin closed with an error — same as EOF: we're done.
        }
    }

    private static func languagesInstalled() async -> Bool {
        let availability = LanguageAvailability()
        let ru = Locale.Language(identifier: "ru")
        let en = Locale.Language(identifier: "en")
        let ruEn = await availability.status(from: ru, to: en)
        let enRu = await availability.status(from: en, to: ru)
        return ruEn == .installed && enRu == .installed
    }
}

/// Peek's side of the helper: spawns it on demand, matches responses to requests by id.
nonisolated final class TranslatorHelperClient: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let onResponse: @Sendable (TranslatorProtocol.Response) -> Void
    private let onExit: @Sendable () -> Void

    init(onResponse: @escaping @Sendable (TranslatorProtocol.Response) -> Void,
         onExit: @escaping @Sendable () -> Void) {
        self.onResponse = onResponse
        self.onExit = onExit
    }

    func start() throws {
        guard let executable = Bundle.main.executableURL else { throw CocoaError(.executableNotLoadable) }
        process.executableURL = executable
        process.arguments = ["--translator"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            self?.output.fileHandleForReading.readabilityHandler = nil
            self?.onExit()
        }
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self.consume(data)
        }
        try process.run()
    }

    func send(_ request: TranslatorProtocol.Request) {
        guard var data = try? encoder.encode(request) else { return }
        data.append(0x0A)
        // Peek ignores SIGPIPE, so a dead helper surfaces as a thrown error, not a crash.
        try? input.fileHandleForWriting.write(contentsOf: data)
    }

    /// Closing stdin makes the helper finish and exit on its own.
    func stop() {
        try? input.fileHandleForWriting.close()
    }

    // Serial on the pipe's reading queue.
    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let response = try? decoder.decode(TranslatorProtocol.Response.self, from: Data(line)) {
                onResponse(response)
            }
        }
    }
}
