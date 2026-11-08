import AppKit

// Command-line maintenance entry points (used by scripts/build.sh); they never start the UI.
let arguments = CommandLine.arguments
if arguments.contains("--install-agent") {
    exit(LaunchAgent.install() ? 0 : 1)
}
if arguments.contains("--uninstall-agent") {
    LaunchAgent.uninstall(stopRunning: true)
    exit(0)
}
// Translation helper child process (see TranslatorHelper): no UI, exits when Peek closes its stdin.
if arguments.contains("--translator") {
    await TranslatorHelper.run()
    exit(0)
}

// Writing to a pipe whose reader died (a helper process) must surface as an error, never kill Peek.
signal(SIGPIPE, SIG_IGN)

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
