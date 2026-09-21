import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

enum Actions {
    static let logDir = Discovery.home.appendingPathComponent(".notch-fleet/logs")

    /// Appends one line per delivery attempt. Sending is the part of this app
    /// that can fail invisibly — a keystroke going to the wrong window looks
    /// exactly like nothing happening — so each attempt records what it tried.
    /// Set by the app so a send can ask how many agents share its target app;
    /// only the fleet knows that.
    static var sharingTargetApp: ((Agent) -> Int)?

    private static var lastSent: (fingerprint: String, at: Date)?
    private static let duplicateLock = NSLock()

    static func trace(_ line: String) {
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
        let entry = "\(stamp)  \(line)\n"
        let url = logDir.appendingPathComponent("send.log")
        // Rotate rather than grow forever; one previous file is enough history.
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
           size > 512 * 1024 {
            let previous = logDir.appendingPathComponent("send.log.1")
            try? FileManager.default.removeItem(at: previous)
            try? FileManager.default.moveItem(at: url, to: previous)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(entry.utf8))
        } else {
            try? Data(entry.utf8).write(to: url)
        }
    }

    /// Interrupt the current turn without ending the session.
    static func interrupt(_ agent: Agent) -> String {
        kill(agent.pid, SIGINT) == 0
            ? "Interrupted \(agent.name)"
            : "Could not interrupt \(agent.name) (pid \(agent.pid))"
    }

    /// Ask the process to exit. The conversation is kept on disk either way.
    static func quit(_ agent: Agent) -> String {
        kill(agent.pid, SIGTERM) == 0
            ? "Sent quit to \(agent.name)"
            : "Could not quit \(agent.name) (pid \(agent.pid))"
    }

    /// Hands `text` to a running agent. Every source has its own documented
    /// route in, and all three run detached so nothing steals focus from the
    /// terminal you are in. Output lands in ~/.notch-fleet/logs.
    ///
    /// - Claude: `claude --resume <id> -p` replays into that exact session.
    /// - Codex: `codex queue --thread <id> --message` hands the text to the
    ///   running app-server daemon, which is the same mechanism the ChatGPT
    ///   desktop app uses. The bundled binary is not on the login PATH, so it
    ///   is called by the path the live process was launched from.
    /// - Cursor: `cursor-agent --continue --workspace <dir> -p` picks up the
    ///   newest chat in that workspace. The per-worker socket would target the
    ///   exact worker, but it speaks an undocumented binary protocol, so the
    ///   supported CLI is the safer foundation.
    /// `allowKeystrokes` is false for anything automated. Typing into a focused
    /// window is fine when a person just asked for it and is watching; doing it
    /// on a timer could put text into whatever they happen to have in front of
    /// them, including an editor.
    /// Queues a message for delivery and returns immediately.
    ///
    /// Everything that can block now happens on a background queue. Twice this
    /// froze the app by waiting on `osascript` from the main thread — once for
    /// System Events, once for scripting a terminal — because macOS blocks that
    /// process while it asks the user about automation. Nothing on the delivery
    /// path may be synchronous.
    ///
    /// `allowKeystrokes` is false for anything automated: typing into a focused
    /// window is fine when a person just asked and is watching, but on a timer
    /// it could land wherever they happen to be.
    static func send(_ text: String, to agent: Agent, allowKeystrokes: Bool = true) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Nothing to send" }

        // SwiftUI fires a TextField's onSubmit on focus changes as well as on
        // return, so one keypress could dispatch twice — pasting the message,
        // submitting it, then pasting it again into the emptied prompt.
        let fingerprint = "\(agent.id)|\(trimmed)"
        duplicateLock.lock()
        let repeated = lastSent.map {
            $0.fingerprint == fingerprint && Date().timeIntervalSince($0.at) < 4
        } ?? false
        if !repeated { lastSent = (fingerprint, Date()) }
        duplicateLock.unlock()
        if repeated {
            trace("DUPE \(agent.source.label) \(agent.name): ignored a repeat within 4s")
            return "Already sending that"
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = deliver(trimmed, to: agent, allowKeystrokes: allowKeystrokes)
            DispatchQueue.main.async { onResult?(outcome) }
        }
        return "Sending to \(agent.name)…"
    }

    /// Reports what actually happened, since `send` returns before it knows.
    static var onResult: ((String) -> Void)?

    /// The real work, always off the main thread.
    private static func deliver(_ text: String, to agent: Agent, allowKeystrokes: Bool) -> String {
        let label = "\(agent.source.label) \(agent.name)"
        let preview = String(text.prefix(80))
        let app = agent.ownerAppName ?? "its app"

        // 1. A scriptable terminal can be told which tab, which is exact.
        if TerminalDelivery.send(text, to: agent) {
            trace("TAB  \(label): \(preview)")
            return "Delivered to \(agent.name)'s tab"
        }

        // 2. A real API, where the source has one.
        if !needsKeystrokes(agent), let script = sendScript(text, to: agent) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
            proc.arguments = ["-lc", script]
            do { try proc.run() } catch {
                trace("FAIL \(label): \(error.localizedDescription)")
                return "Failed to launch: \(error.localizedDescription)"
            }
            trace("CLI  \(label): \(preview)")
            return "Sent \"\(text)\" to \(agent.name)"
        }

        // 3. Typing at a window. Never unattended.
        guard allowKeystrokes else {
            trace("SKIP \(label): keystroke delivery is not used unattended")
            return "\(agent.name) can only be messaged by hand"
        }

        // Keys reach only the focused tab, so two agents in one app cannot be
        // told apart — refuse rather than deliver to the wrong one.
        if let others = sharingTargetApp?(agent), others > 1 {
            copyToClipboard(text)
            trace("AMBIG \(label): \(others) agents share \(app), cannot aim")
            return "\(others) agents share \(app) — copied instead, paste into the right one"
        }
        return handOff(text, to: agent)
    }

    private static func copyToClipboard(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }

    /// True when the only way in is typing at a window: an interactive Claude
    /// session and a Cursor chat both have a text box and no local API behind
    /// it. These are the agents `deliver` will not touch unattended.
    static func needsKeystrokes(_ agent: Agent) -> Bool {
        if ProcessInfo.processInfo.environment["FLEET_ALLOW_HEADLESS"] == "1" { return false }
        switch agent.source {
        case .claude: return agent.isInteractive
        case .cursor: return true
        case .codex: return false
        }
    }

    private static func sendScript(_ text: String, to agent: Agent) -> String? {
        let log = quoted(logDir.appendingPathComponent("\(logName(agent)).log").path)
        let body = quoted(text)

        switch agent.source {
        case .claude:
            guard let session = agent.sessionId else { return nil }
            // `claude --resume -p` starts a *second* process against the same
            // session id. For a background session that is the intended way to
            // drive it — there is no terminal to conflict with. For an
            // interactive session it forks the conversation: the reply lands in
            // a log the user never sees, while appending to the transcript the
            // live TUI is also writing. So only background sessions get it.
            guard !agent.isInteractive
                || ProcessInfo.processInfo.environment["FLEET_ALLOW_HEADLESS"] == "1"
            else { return nil }
            return """
            cd \(quoted(agent.cwd)) && \
            claude --resume \(quoted(session)) -p \(body) \
            < /dev/null >> \(log) 2>&1 &
            """

        case .codex:
            guard let session = agent.sessionId, let binary = agent.executable else { return nil }
            return """
            \(quoted(binary)) queue --thread \(quoted(session)) --message \(body) \
            < /dev/null >> \(log) 2>&1 &
            """

        case .cursor:
            // Reached by keystrokes instead: `cursor-agent --continue` looks
            // for a *local* chat, and a Cursor agent is a cloud agent, so it
            // reported "No previous chats found" every time.
            return nil
        }
    }

    /// Delivers without taking your focus.
    ///
    /// The message goes on the clipboard and the paste and return keys are
    /// posted *straight to the target process* with `CGEventPostToPid`, so the
    /// app never has to come to the front. Earlier this activated the window
    /// and drove System Events, which stole focus for every message and made
    /// it feel like the user had to take part.
    ///
    /// Still needs Accessibility, because synthesising key events is what
    /// macOS gates — but no Apple Events and no window switching.
    /// Types the message at a window: clipboard, then paste and return posted
    /// to that app's process.
    ///
    /// Routing already happened in `deliver`; this is only the keystroke leg.
    /// It is already on a background queue, so the waits here are fine.
    private static func handOff(_ text: String, to agent: Agent) -> String {
        copyToClipboard(text)

        let label = "\(agent.source.label) \(agent.name)"
        let preview = String(text.prefix(80))
        let app = agent.ownerAppName ?? "the window"

        guard AXIsProcessTrusted() else {
            requestAccessibility()
            trace("CLIP \(label): no Accessibility permission")
            return "Copied — press ⌘V in \(app). Grant Accessibility to skip this."
        }
        guard let pid = agent.ownerPid else {
            trace("CLIP \(label): no owner pid")
            _ = reveal(agent)
            return "Copied — press ⌘V in \(app)"
        }

        // A terminal accepts posted key events while it sits in the background;
        // an Electron app does not, because Chromium only routes keys to its
        // renderer when the window is key. Posting to a background Cursor
        // logged a clean send and did nothing at all. Detected from the bundle,
        // so any Electron-based editor or terminal is handled the same way.
        let needsFocus = agent.ownerApp.map { TerminalDelivery.needsFocus(appBundle: $0) } ?? false
        if needsFocus {
            _ = reveal(agent)
            usleep(700_000)
            // Cursor's chat input has to be focused first, or the paste would
            // land in whatever file is open and edit their code.
            postKey(.l, flags: .maskCommand, to: pid)
            usleep(450_000)
        }

        postKey(.v, flags: .maskCommand, to: pid)
        // Claude Code reads a bracketed paste as one batch; a return arriving
        // too soon is swallowed with it.
        usleep(1_000_000)
        postKey(.return, flags: [], to: pid)

        trace("POST \(label) -> pid \(pid)\(needsFocus ? " (focused)" : ""): \(preview)")
        return needsFocus
            ? "Typed into \(app) — it has to be focused to accept keys"
            : "Sent to \(agent.name) — \(app) stays where it is"
    }

    /// The handful of keys this needs, by virtual keycode.
    private enum Key: CGKeyCode {
        case v = 9
        case l = 37
        case `return` = 36
    }

    /// Posts one key press to a specific process. Unlike System Events, this
    /// does not require the app to be frontmost.
    private static func postKey(_ key: Key, flags: CGEventFlags, to pid: pid_t) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source,
                                      virtualKey: key.rawValue,
                                      keyDown: isDown) else { continue }
            event.flags = flags
            event.postToPid(pid)
        }
    }

    /// Whether keystroke delivery is possible at all right now. macOS caches
    /// this per process, so a grant made while the app is running is not
    /// visible until it relaunches.
    static var accessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// Opens the exact settings pane, since "grant Accessibility" is otherwise
    /// four levels deep in System Settings.
    static func openAccessibilitySettings() {
        Discovery.run("/usr/bin/open",
                      ["x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"])
    }

    /// Asks once, with the system prompt, rather than failing silently.
    private static var askedForAccessibility = false

    private static func requestAccessibility() {
        guard !askedForAccessibility else { return }
        askedForAccessibility = true
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Logs are grouped per conversation where there is one, per process otherwise.
    private static func logName(_ agent: Agent) -> String {
        if let session = agent.sessionId { return session }
        return agent.id
    }

    /// Brings the agent's own window forward: the terminal a Claude session
    /// is running in, or the app hosting a worker. For Cursor the workspace is
    /// passed too, so it opens the right project rather than whatever was last
    /// focused.
    static func reveal(_ agent: Agent) -> String {
        guard let app = agent.ownerApp,
              FileManager.default.fileExists(atPath: app) else {
            return "Cannot tell which app \(agent.name) is running in"
        }

        // Never pass a path. `open -a Cursor <folder>` opens a second window,
        // and even the VS Code CLI with a folder tends to open rather than
        // raise. These apps are already running the agent, so activating the
        // app is enough to get back to the work.
        //
        // Off the main thread: `open` takes a few hundred milliseconds, and the
        // window raise is an Apple Event that can wait on consent.
        let workspace = (agent.cwd as NSString).lastPathComponent
        let process = processName(forApp: app) ?? agent.ownerAppName
        let cwd = agent.cwd
        let isCursor = agent.source == .cursor
        DispatchQueue.global(qos: .userInitiated).async {
            // Cursor records which agent belongs to a workspace for some
            // workspaces; where it did, its own deeplink focuses that exact
            // agent instead of just raising whatever window was last used.
            if isCursor, !cwd.isEmpty, let link = CursorAgents.deeplink(forWorkspace: cwd) {
                Discovery.run("/usr/bin/open", [link])
                trace("LINK CURSOR \(cwd): \(link)")
                return
            }
            Discovery.run("/usr/bin/open", ["-a", app])
            if let process, !workspace.isEmpty {
                raiseWindow(preferring: workspace, inProcess: process)
            }
        }

        let name = agent.ownerAppName ?? "its app"
        // Only Claude tells us the pane; the app comes forward either way.
        return agent.source == .claude
            ? "Opened \(name) — look for the \(agent.name) tab"
            : "Opened \(name)"
    }

    /// System Events knows processes by their executable name — Ghostty.app's
    /// process is "ghostty", not "Ghostty" — so the bundle is asked.
    static func processName(forApp app: String) -> String? {
        let plist = (app as NSString).appendingPathComponent("Contents/Info.plist")
        guard let data = FileManager.default.contents(atPath: plist),
              let obj = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil) as? [String: Any]
        else { return nil }
        return obj["CFBundleExecutable"] as? String
    }

    /// Brings an existing window forward — the one whose title names this
    /// workspace if there is one, otherwise whatever window the app already
    /// has. Never creates a window.
    ///
    /// Cursor usually has a single window (often titled "Cursor Agents") with
    /// the agents listed inside it, and its Electron accessibility tree
    /// exposes no rows, so selecting one particular agent is not automatable.
    /// Landing on the right window is as far as this can honestly go.
    private static func raiseWindow(preferring name: String, inProcess process: String) {
        let script = """
        tell application "System Events"
            if not (exists process "\(process)") then return
            tell process "\(process)"
                set frontmost to true
                if (count of windows) is 0 then return
                set target to missing value
                repeat with w in windows
                    try
                        if name of w contains "\(name)" then
                            set target to w
                            exit repeat
                        end if
                    end try
                end repeat
                if target is missing value then set target to window 1
                try
                    perform action "AXRaise" of target
                end try
            end tell
        end tell
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try? proc.run()
    }

    /// Reveals the transcript this app has been reading, for the full history.
    static func revealTranscript(_ agent: Agent) -> String {
        guard let session = agent.sessionId,
              let url = Discovery.transcriptIndex()[session] else {
            return "No transcript on disk for \(agent.name)"
        }
        Discovery.run("/usr/bin/open", ["-R", url.path])
        return "Revealed \(url.lastPathComponent)"
    }

    static func openLog(_ agent: Agent) -> String {
        let log = logDir.appendingPathComponent("\(logName(agent)).log").path
        guard FileManager.default.fileExists(atPath: log) else {
            return "No log yet — it appears once you send something"
        }
        Discovery.run("/usr/bin/open", ["-R", log])
        return "Revealed \(logName(agent)).log"
    }

    /// POSIX single-quote escaping: close, insert a literal quote, reopen.
    static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
