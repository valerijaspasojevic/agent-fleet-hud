import Foundation

/// Delivers a message into the *exact* terminal tab running an agent.
///
/// Posting key events to an app only ever reaches whatever tab happens to be
/// focused, which is fine with one session and silently wrong with two. Some
/// terminals are scriptable and can be told which tab to write to, which
/// removes the guesswork — and needs no focus at all.
///
/// Supported precisely:
/// - **Ghostty** — `input text … to <terminal>`, matched on the terminal's
///   working directory. Its dictionary exposes no tty, so the directory is the
///   key.
/// - **Terminal.app** — `do script … in <tab whose tty is …>`, matched on the
///   agent's controlling terminal, which is exact.
///
/// Everything else falls back to posted keystrokes, guarded by a check that
/// only one agent is using that app.
enum TerminalDelivery {
    enum Target {
        case ghostty
        case terminalApp
        case iTerm

        /// Matched on the bundle identifier, not the file name, so a renamed
        /// or relocated app still works.
        static func forApp(_ bundlePath: String) -> Target? {
            switch bundleIdentifier(ofApp: bundlePath) {
            case "com.mitchellh.ghostty": return .ghostty
            case "com.apple.Terminal": return .terminalApp
            case "com.googlecode.iterm2": return .iTerm
            default: return nil
            }
        }

        private static func bundleIdentifier(ofApp path: String) -> String? {
            let plist = (path as NSString).appendingPathComponent("Contents/Info.plist")
            guard let data = FileManager.default.contents(atPath: plist),
                  let obj = try? PropertyListSerialization.propertyList(
                      from: data, options: [], format: nil) as? [String: Any]
            else { return nil }
            return obj["CFBundleIdentifier"] as? String
        }
    }

    /// True when the app cannot receive posted key events unless it is
    /// frontmost. Chromium only routes keys to its renderer for the key
    /// window, so an Electron app must be focused first — detected from the
    /// bundle rather than by keeping a list of app names.
    static func needsFocus(appBundle: String) -> Bool {
        let framework = (appBundle as NSString)
            .appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        return FileManager.default.fileExists(atPath: framework)
    }

    /// Writes into the tab running this agent. Returns false when the tab
    /// could not be identified, so the caller can fall back.
    static func send(_ text: String, to agent: Agent) -> Bool {
        guard let app = agent.ownerApp, let target = Target.forApp(app) else { return false }
        switch target {
        case .ghostty: return sendGhostty(text, cwd: agent.cwd)
        case .terminalApp: return sendTerminalApp(text, tty: agent.tty)
        case .iTerm: return sendITerm(text, tty: agent.tty)
        }
    }

    // MARK: Ghostty

    private static func sendGhostty(_ text: String, cwd: String) -> Bool {
        guard !cwd.isEmpty else { return false }
        // Two different commands, and the distinction is the whole problem:
        // Ghostty documents `input text` as "input text to a terminal as if it
        // was pasted", so any newline inside it — LF or CR — is pasted content,
        // not Enter. The message landed in the right tab and sat there.
        // `send key "enter"` is a real keyboard event, and it is addressed to
        // one terminal, so this stays exact and needs no focus.
        let script = """
        tell application "Ghostty"
            set hit to missing value
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        set term to focused terminal of t
                        if (working directory of term) is \(literal(cwd)) then
                            set hit to term
                            exit repeat
                        end if
                    end try
                end repeat
                if hit is not missing value then exit repeat
            end repeat
            if hit is missing value then return "no-tab"
            input text \(literal(text)) to hit
            delay 0.6
            send key "enter" to hit
            return "ok"
        end tell
        """
        return run(script) == "ok"
    }

    // MARK: Terminal.app

    private static func sendTerminalApp(_ text: String, tty: String?) -> Bool {
        guard let tty else { return false }
        let device = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
        // `do script … in <tab>` types into that tab and submits it.
        let script = """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        if (tty of t) is \(literal(device)) then
                            do script \(literal(text)) in t
                            return "ok"
                        end if
                    end try
                end repeat
            end repeat
            return "no-tab"
        end tell
        """
        return run(script) == "ok"
    }

    // MARK: iTerm2

    /// iTerm exposes `tty` on a session, so the match is exact. `write text`
    /// submits, so no separate key event is needed.
    ///
    /// Untested — iTerm was not installed on the machine this was written on,
    /// so treat it as best-effort: it returns false and falls back if the
    /// session cannot be found.
    private static func sendITerm(_ text: String, tty: String?) -> Bool {
        guard let tty else { return false }
        let device = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
        let script = """
        tell application "iTerm"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with se in sessions of t
                        try
                            if (tty of se) is \(literal(device)) then
                                tell se to write text \(literal(text))
                                return "ok"
                            end if
                        end try
                    end repeat
                end repeat
            end repeat
            return "no-tab"
        end tell
        """
        return run(script) == "ok"
    }

    // MARK: Plumbing

    /// AppleScript has no `\n` escape, so a multi-line message is built by
    /// concatenating literals with `linefeed`.
    private static func literal(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines).map { line -> String in
            let escaped = line
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        return lines.count == 1 ? lines[0] : lines.joined(separator: " & linefeed & ")
    }

    /// Runs the script with a hard deadline.
    ///
    /// `osascript` blocks indefinitely when macOS wants to ask about
    /// controlling another app, and the first attempt to script a terminal is
    /// exactly when that happens. Waiting on it without a deadline froze the
    /// whole app for as long as the prompt went unanswered.
    ///
    /// Must never be called on the main thread.
    private static func run(_ script: String, timeout: TimeInterval = 6) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        let output = Pipe()
        proc.standardOutput = output
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }

        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            proc.waitUntilExit()
            finished.signal()
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            proc.terminate()
            Actions.trace("HUNG osascript for a terminal — Automation consent likely pending")
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
