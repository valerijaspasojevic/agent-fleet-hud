import AppKit
import Foundation

enum Source: String, CaseIterable {
    case claude, codex, cursor

    var label: String {
        switch self {
        case .claude: return "CLAUDE"
        case .codex: return "CODEX"
        case .cursor: return "CURSOR"
        }
    }

    /// Only Claude publishes a real "my turn ended, your move" status.
    ///
    /// Cursor keeps its worker process alive between turns and its worker log
    /// is a 30-second heartbeat, so a finished agent looks identical to a
    /// working one. Codex has no per-thread process and its index is only
    /// written when a thread is saved. Painting either green would claim
    /// something neither of them tells us, so they report `.running` instead.
    var publishesIdleState: Bool { self == .claude }
}

enum AgentState {
    case busy, idle, live, asking, limited

    var label: String {
        switch self {
        case .busy: return "busy"
        case .idle: return "idle"
        case .live: return "running"
        case .asking: return "needs you"
        case .limited: return "limit reached"
        }
    }

    /// A question is actionable, so it sorts first. A limit is not actionable
    /// but it is why nothing is happening, so it sorts second. `.running`
    /// carries no news at all, so it sorts last.
    var urgency: Int {
        switch self {
        case .asking: return 0
        case .limited: return 1
        case .busy: return 2
        case .idle: return 3
        case .live: return 4
        }
    }
}

struct Agent: Identifiable, Equatable {
    let id: String
    let source: Source
    let name: String
    let cwd: String
    let pid: pid_t
    let state: AgentState
    /// Seconds since the state last changed, or since the process started.
    let age: Double
    let sessionId: String?
    let detail: String
    /// Newest thing the agent said, for the third line of the row.
    let message: String
    /// Set when it looks like the agent is blocked on an answer from you.
    let question: String?
    /// Set when this session's own request was rejected for hitting the limit.
    let limitResetsAt: Date?
    /// How much of the window is gone, when the source reports a percentage
    /// rather than a hard rejection.
    let limitUsedPercent: Double?
    /// When that percentage was recorded, for sources that report one.
    let limitReadAt: Date?
    /// Model doing the work, already shortened for display.
    let model: String
    /// The CLI to drive this agent with, when it is not on the login PATH.
    let executable: String?
    /// A session with a live TUI. Driving one headlessly forks it; a
    /// background session has no terminal to conflict with.
    let isInteractive: Bool
    /// The .app this agent is living inside — the terminal running a Claude
    /// session, or the editor hosting a worker. Used to jump to it.
    let ownerApp: String?
    /// That app's pid, so keystrokes can be posted straight to it without
    /// bringing it to the front.
    let ownerPid: pid_t?
    /// The agent's controlling terminal, which is what lets a scriptable
    /// terminal be told *which tab* to deliver to.
    let tty: String?

    /// "Ghostty" from "/Applications/Ghostty.app".
    var ownerAppName: String? {
        ownerApp.map { ((($0 as NSString).lastPathComponent) as NSString).deletingPathExtension }
    }

    /// Every source turned out to have a documented way in:
    /// Claude resumes a session id, Codex queues onto a thread, Cursor
    /// continues the newest chat in a workspace.
    var canMessage: Bool {
        switch source {
        case .claude, .codex: return sessionId != nil
        case .cursor: return !cwd.isEmpty
        }
    }

    static func == (a: Agent, b: Agent) -> Bool {
        a.id == b.id && a.state == b.state && a.age == b.age && a.detail == b.detail
            && a.message == b.message && a.question == b.question && a.model == b.model
            && a.limitResetsAt == b.limitResetsAt && a.limitUsedPercent == b.limitUsedPercent
    }
}

// MARK: - Process snapshot

struct RunningProcess {
    let pid: pid_t
    let ppid: pid_t
    let age: Double
    /// Controlling terminal, e.g. "ttys007", or nil for a GUI process.
    let tty: String?
    let command: String
}

enum Discovery {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    static func scan() -> [Agent] {
        let procs = snapshotProcesses()
        var agents = claudeAgents(procs: procs)
        agents += cursorAgents(procs: procs)
        agents += codexAgents(procs: procs)
        // Whatever needs you first, then what is working, then longest-waiting.
        return agents.sorted { l, r in
            if l.state.urgency != r.state.urgency { return l.state.urgency < r.state.urgency }
            if l.source != r.source { return l.source.rawValue < r.source.rawValue }
            return l.age > r.age
        }
    }

    static func snapshotProcesses() -> [pid_t: RunningProcess] {
        guard let out = run("/bin/ps", ["-axo", "pid=,ppid=,etime=,tty=,command="]) else { return [:] }
        var map: [pid_t: RunningProcess] = [:]
        for line in out.split(separator: "\n") {
            var rest = Substring(line).drop(while: { $0 == " " })
            guard let pidEnd = rest.firstIndex(of: " "), let pid = pid_t(rest[..<pidEnd]) else { continue }
            rest = rest[pidEnd...].drop(while: { $0 == " " })
            guard let ppidEnd = rest.firstIndex(of: " "), let ppid = pid_t(rest[..<ppidEnd]) else { continue }
            rest = rest[ppidEnd...].drop(while: { $0 == " " })
            guard let etEnd = rest.firstIndex(of: " ") else { continue }
            let age = parseEtime(String(rest[..<etEnd]))
            rest = rest[etEnd...].drop(while: { $0 == " " })
            guard let ttyEnd = rest.firstIndex(of: " ") else { continue }
            // ps prints "??" for a process with no controlling terminal.
            let rawTty = String(rest[..<ttyEnd])
            let tty = rawTty == "??" ? nil : rawTty
            let command = String(rest[ttyEnd...].drop(while: { $0 == " " }))
            map[pid] = RunningProcess(pid: pid, ppid: ppid, age: age, tty: tty, command: command)
        }
        return map
    }

    /// ps etime is [[dd-]hh:]mm:ss
    static func parseEtime(_ raw: String) -> Double {
        var str = raw
        var days = 0.0
        if let dash = str.firstIndex(of: "-") {
            days = Double(str[..<dash]) ?? 0
            str = String(str[str.index(after: dash)...])
        }
        var secs = 0.0
        for part in str.split(separator: ":") { secs = secs * 60 + (Double(part) ?? 0) }
        return days * 86400 + secs
    }

    // MARK: Claude Code

    /// Claude publishes live per-session state to ~/.claude/sessions/<pid>.json,
    /// including a busy/idle status it keeps current.
    static func claudeAgents(procs: [pid_t: RunningProcess]) -> [Agent] {
        let dir = home.appendingPathComponent(".claude/sessions")
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        let transcripts = transcriptIndex()
        var out: [Agent] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pidNum = obj["pid"] as? NSNumber else { continue }
            let pid = pid_t(truncating: pidNum)
            // A stale state file outlives its process; require a live pid that is still Claude.
            guard let proc = procs[pid], proc.command.contains("claude") else { continue }

            let cwd = obj["cwd"] as? String ?? ""
            let status = (obj["status"] as? String ?? "").lowercased()
            let name = (obj["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (cwd as NSString).lastPathComponent

            // statusUpdatedAt is epoch milliseconds; fall back to process age.
            var age = proc.age
            if let ms = obj["statusUpdatedAt"] as? NSNumber {
                let changed = Date(timeIntervalSince1970: ms.doubleValue / 1000)
                age = max(0, Date().timeIntervalSince(changed))
            }

            let kind = obj["kind"] as? String ?? "interactive"
            var detail = abbreviate(cwd)
            if kind != "interactive" { detail += "  ·  \(kind)" }

            let sessionId = obj["sessionId"] as? String
            let peek = sessionId.map { peekTranscript($0, in: transcripts) } ?? SessionPeek()

            // A question outranks the published status: an open AskUserQuestion
            // or plan review leaves the session "busy" while it is really stuck
            // on you.
            var state: AgentState = status == "busy" ? .busy : .idle
            if peek.question != nil || (state == .idle && peek.message.hasSuffix("?")) {
                state = .asking
            }
            // Being blocked outranks everything: it is why nothing is moving.
            if peek.limitResetsAt != nil { state = .limited }

            out.append(Agent(
                id: "claude-\(pid)",
                source: .claude,
                name: name,
                cwd: cwd,
                pid: pid,
                state: state,
                age: age,
                sessionId: sessionId,
                detail: detail,
                message: peek.message,
                question: peek.question ?? (state == .asking ? peek.message : nil),
                limitResetsAt: peek.limitResetsAt,
                limitUsedPercent: nil,
                limitReadAt: nil,
                model: peek.model,
                executable: nil,
                isInteractive: kind == "interactive",
                ownerApp: owningApp(of: pid, in: procs),
                ownerPid: owningProcess(of: pid, in: procs)?.pid
                    ?? owningApp(of: pid, in: procs).flatMap { mainAppPid(bundle: $0, in: procs) },
                tty: proc.tty
            ))
        }
        return out
    }

    // MARK: Demo

    /// A fixed sample fleet so every colour can be seen at once, without
    /// waiting to hit a limit or for an agent to ask something. Set
    /// `FLEET_DEMO=1`. The pid is deliberately one that cannot exist, so a
    /// misfired Stop or Quit hits nothing — never 0 or -1, which would signal
    /// this app's own process group or every process we own.
    static let demoPid: pid_t = 999_999

    static func demoAgents() -> [Agent] {
        func row(_ name: String, _ source: Source, _ state: AgentState, age: Double,
                 path: String, model: String, message: String,
                 question: String? = nil, resets: Date? = nil) -> Agent {
            Agent(id: "demo-\(name)", source: source, name: name, cwd: path, pid: demoPid,
                  state: state, age: age, sessionId: "demo-\(name)",
                  detail: "fabricated row · not a real agent",
                  message: message, question: question, limitResetsAt: resets,
                  limitUsedPercent: nil, limitReadAt: nil, model: model, executable: nil,
                  isInteractive: source == .claude,
                  ownerApp: nil,
                  ownerPid: nil, tty: nil)
        }

        return [
            row("SAMPLE needs-you", .claude, .asking, age: 142,
                path: "/demo/sample-project", model: "sample", message: "",
                question: "This row is fake — a real one would show the question here"),
            row("SAMPLE blocked", .claude, .limited, age: 1_840,
                path: "/demo/sample-project", model: "sample",
                message: "This row is fake — a real one would show the limit notice here",
                resets: Date().addingTimeInterval(2 * 3600 + 14 * 60)),
            row("SAMPLE working", .claude, .busy, age: 37,
                path: "/demo/sample-project", model: "sample",
                message: "This row is fake — a real one would show the latest message here"),
            row("SAMPLE idle", .claude, .idle, age: 420,
                path: "/demo/sample-project", model: "sample",
                message: "This row is fake"),
            row("SAMPLE cursor", .cursor, .live, age: 474,
                path: "/demo/sample-project", model: "sample", message: ""),
            row("SAMPLE codex", .codex, .live, age: 259_770,
                path: "/demo/sample-project", model: "sample", message: ""),
        ].sorted { l, r in
            if l.state.urgency != r.state.urgency { return l.state.urgency < r.state.urgency }
            return l.age > r.age
        }
    }

    // MARK: Transcripts

    struct SessionPeek {
        /// Newest assistant text, or the tool it is running if it has not spoken yet.
        var message: String = ""
        /// The thing it is waiting on you for, when we can name it.
        var question: String?
        /// Model on the newest assistant turn.
        var model: String = ""
        /// Set when the newest thing that happened was a rate-limit rejection
        /// whose window has not rolled over yet.
        var limitResetsAt: Date?
    }

    /// Maps session id to its transcript. Session files are named by pid, so the
    /// transcript has to be found by id across every project directory.
    static func transcriptIndex() -> [String: URL] {
        let root = home.appendingPathComponent(".claude/projects")
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return [:]
        }
        var index: [String: URL] = [:]
        for dir in dirs {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                index[file.deletingPathExtension().lastPathComponent] = file
            }
        }
        return index
    }

    /// Reads the tail of a transcript for the latest thing the agent said and
    /// whether it is parked on a question. A tool call with no matching result
    /// is an agent waiting on the human — that covers both AskUserQuestion and
    /// a plan sitting in review.
    static func peekTranscript(_ sessionId: String, in index: [String: URL]) -> SessionPeek {
        guard let url = index[sessionId], let text = tail(url, bytes: 160 * 1024) else { return SessionPeek() }

        var peek = SessionPeek()
        var openTools: Set<String> = []
        var asks: [String: String] = [:]
        // A rejection only means "blocked right now" if nothing succeeded
        // after it, so both are tracked in transcript order.
        var seq = 0
        var lastLiveTurn = -1
        var rejection: (resetsAt: Date, seq: Int)?

        for line in text.split(separator: "\n") {
            seq += 1

            if line.contains("\"resetsAt\"") {
                if let obj = try? JSONSerialization.jsonObject(
                        with: Data(line.utf8)) as? [String: Any],
                   let quota = obj["quotaLimits"] as? [String: Any],
                   (quota["status"] as? String)?.lowercased() == "rejected",
                   let secs = quota["resetsAt"] as? NSNumber {
                    rejection = (Date(timeIntervalSince1970: secs.doubleValue), seq)
                }
            }

            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = obj["message"] as? [String: Any],
                  let blocks = message["content"] as? [[String: Any]] else { continue }

            let isAssistant = obj["type"] as? String == "assistant"
            let isError = obj["isApiErrorMessage"] as? Bool ?? false

            // The rejection is itself an assistant turn stamped
            // `model: "<synthetic>"`, which is not a model anyone chose.
            if isAssistant, !isError, let model = message["model"] as? String,
               !model.hasPrefix("<") {
                peek.model = shortModel(model)
            }
            if isAssistant, !isError { lastLiveTurn = seq }

            for block in blocks {
                switch block["type"] as? String {
                case "text":
                    let raw = (block["text"] as? String) ?? ""
                    let trimmed = collapse(raw)
                    // Only the assistant's own words; a user turn is not news.
                    // The limit notice counts — it explains the silence.
                    if !trimmed.isEmpty, isAssistant { peek.message = trimmed }
                case "tool_use":
                    guard let id = block["id"] as? String else { continue }
                    openTools.insert(id)
                    let name = block["name"] as? String ?? "a tool"
                    if let prompt = askPrompt(name: name, input: block["input"] as? [String: Any]) {
                        asks[id] = prompt
                    }
                    if peek.message.isEmpty { peek.message = "running \(name)" }
                case "tool_result":
                    if let id = block["tool_use_id"] as? String {
                        openTools.remove(id)
                        asks[id] = nil
                    }
                default:
                    continue
                }
            }
        }

        peek.question = asks.first { openTools.contains($0.key) }?.value
        if let rejection, rejection.resetsAt > Date(), rejection.seq >= lastLiveTurn {
            peek.limitResetsAt = rejection.resetsAt
        }
        return peek
    }

    /// The tools that genuinely block on a person, and the wording to show.
    static func askPrompt(name: String, input: [String: Any]?) -> String? {
        switch name {
        case "AskUserQuestion":
            if let questions = input?["questions"] as? [[String: Any]],
               let first = questions.first?["question"] as? String {
                return collapse(first)
            }
            return "asked you a question"
        case "ExitPlanMode":
            return "waiting for you to approve a plan"
        default:
            return nil
        }
    }

    /// Reads the last `bytes` of a file, dropping the partial first line.
    static func tail(_ url: URL, bytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }
        // A byte cut can land mid-codepoint, so decode leniently.
        var text = String(decoding: data, as: UTF8.self)
        if start > 0, let newline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: newline)...])
        }
        return text
    }

    /// One line, no runs of whitespace, short enough for a row.
    static func collapse(_ text: String, limit: Int = 180) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }

    // MARK: Cursor

    static func cursorAgents(procs: [pid_t: RunningProcess]) -> [Agent] {
        var out: [Agent] = []
        for (pid, proc) in procs {
            let cmd = proc.command
            guard cmd.contains("cursor-agent") else { continue }
            // Electron helpers mention the path too; only the CLI itself counts.
            guard !cmd.contains("--type=") else { continue }
            guard cmd.contains("/bin/cursor-agent") || cmd.hasPrefix("cursor-agent") else { continue }

            let isWorker = cmd.contains("worker start")
            // An explicit --model wins; otherwise the CLI uses the configured default.
            let model = flagValue(cmd, "--model").map(shortModel) ?? cursorDefaultModel()

            // The worker's own socket is the one place that distinguishes an
            // agent actually running through it from a worker sitting idle.
            let reading = flagValue(cmd, "--worker-api-socket")
                .flatMap { $0.split(separator: " ").first.map(String.init) }
                .flatMap { CursorWorkers.status(socketPath: $0) }

            let state: AgentState
            let workerDetail: String
            switch reading?.status {
            case .claimed:
                state = .busy
                workerDetail = "agent running through this worker"
            case .ready:
                // Connected and not in use. Whether the agent finished or never
                // started is not something the worker knows.
                state = .idle
                workerDetail = "connected · no agent running"
            case .disconnected:
                state = .live
                workerDetail = "not connected to Cursor"
            default:
                state = .live
                workerDetail = reading == nil ? "no status from worker" : "status unknown"
            }
            let dir = flagValue(cmd, "--worker-dir") ?? ""
            var name = flagValue(cmd, "--name") ?? ""
            // --name reads "~/dev/foo @ Valerija's MacBook Air"; keep the project half.
            if let at = name.range(of: " @ ") { name = String(name[..<at.lowerBound]) }
            if name.isEmpty { name = dir.isEmpty ? "cursor-agent" : (dir as NSString).lastPathComponent }

            out.append(Agent(
                id: "cursor-\(pid)",
                source: .cursor,
                name: name,
                cwd: dir,
                pid: pid,
                state: isWorker ? state : .live,
                age: proc.age,
                sessionId: nil,
                detail: isWorker ? workerDetail : "cli session",
                message: "",
                question: nil,
                limitResetsAt: nil,
                limitUsedPercent: nil,
                limitReadAt: nil,
                model: model,
                executable: executablePath(cmd),
                isInteractive: false,
                // A worker is spawned by the Cursor app itself.
                ownerApp: owningApp(of: pid, in: procs) ?? appPath(bundleId: "com.todesktop.230313mzl4w4u92"),
                ownerPid: owningProcess(of: pid, in: procs)?.pid
                    ?? (owningApp(of: pid, in: procs)
                        ?? appPath(bundleId: "com.todesktop.230313mzl4w4u92"))
                        .flatMap { mainAppPid(bundle: $0, in: procs) },
                tty: nil
            ))
        }
        return out
    }

    // MARK: Codex

    static func codexAgents(procs: [pid_t: RunningProcess]) -> [Agent] {
        var out: [Agent] = []
        for (pid, proc) in procs {
            let cmd = proc.command
            // Match on the executable, not anywhere in the line: a shell or an
            // editor whose command line merely mentions codex is not an agent.
            // Two shapes: ChatGPT.app runs `codex … app-server`, and the
            // standalone CLI (npm/brew) runs `codex` on its own. Matching the
            // executable rather than the whole line keeps a shell that merely
            // mentions codex from being taken for an agent.
            guard let binary = executablePath(cmd),
                  binary == "codex" || binary.hasSuffix("/codex") else { continue }
            let isDaemon = cmd.contains(" app-server")
            // Recency decides whether anything is *moving*; the newest thread
            // of any age is still the right thing to message, so a quiet
            // daemon stays reachable.
            let codex = CodexState.snapshot()
            let threads = codex.threads

            // Thread recency is a fact worth showing, but it is not a turn
            // status: a thread saved an hour ago says nothing about whether
            // anything is working right now. The usage window, on the other
            // hand, is a real reading from the server.
            var detail: String
            if let newest = threads.first {
                let idle = Date().timeIntervalSince(newest.updated)
                detail = "last thread \(shortAge(idle)) ago · \(newest.name)"
            } else {
                detail = "no saved threads"
            }
            if let usage = codex.usage {
                // The age matters: Codex only writes this when it runs, so a
                // percentage with no timestamp could be from this morning.
                let age = shortAge(Date().timeIntervalSince(usage.recordedAt))
                detail = "\(Int(usage.usedPercent))% of the \(usage.windowLabel) "
                    + "(read \(age) ago) · " + detail
            }
            out.append(Agent(
                id: "codex-\(pid)",
                source: .codex,
                name: isDaemon ? "codex app-server" : "codex",
                cwd: home.path,
                pid: pid,
                // Daemon is up; whether an agent inside it is working is not
                // something Codex publishes locally. Being out of window,
                // though, it does tell us.
                state: (codex.usage?.isBlocked ?? false) ? .limited : .live,
                age: proc.age,
                // A message goes to the thread that moved last, which is the
                // one you were just working in.
                sessionId: threads.first?.id,
                detail: detail,
                message: "",
                question: nil,
                limitResetsAt: codex.usage?.isBlocked == true ? codex.usage?.resetsAt : nil,
                limitUsedPercent: codex.usage?.usedPercent,
                limitReadAt: codex.usage?.recordedAt,
                // Codex keeps the model in its config, not per thread.
                model: codexDefaultModel(),
                executable: binary,
                isInteractive: false,
                ownerApp: owningApp(of: pid, in: procs) ?? appPath(bundleId: "com.openai.codex"),
                ownerPid: owningProcess(of: pid, in: procs)?.pid
                    ?? (owningApp(of: pid, in: procs) ?? appPath(bundleId: "com.openai.codex"))
                        .flatMap { mainAppPid(bundle: $0, in: procs) },
                tty: nil
            ))
        }
        return out
    }

    // MARK: Helpers

    /// Pulls a `--flag value` out of a command line, stopping at the next flag.
    /// Values may contain spaces, so we cannot just split on whitespace.
    static func flagValue(_ command: String, _ flag: String) -> String? {
        guard let start = command.range(of: flag + " ") else { return nil }
        let tail = command[start.upperBound...]
        if let next = tail.range(of: " --") {
            return String(tail[..<next.lowerBound])
        }
        return String(tail)
    }

    /// Walks up the parent chain to the first process running out of an .app
    /// bundle. A Claude session sits under zsh under login under the terminal,
    /// so this is what tells us which window to bring forward.
    static func owningApp(of pid: pid_t, in procs: [pid_t: RunningProcess]) -> String? {
        owningProcess(of: pid, in: procs)?.app
    }

    /// Where an app actually is, asked of the system rather than assumed to be
    /// in /Applications — people keep apps in ~/Applications, on other volumes,
    /// or under a different name entirely.
    static func appPath(bundleId: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return nil
        }
        return url.path
    }

    /// The pid of an app's own main process, found directly rather than by
    /// ancestry. A worker can be re-parented to launchd when whatever started
    /// it exits — a worker re-parented to launchd has been seen in practice —
    /// and then there is no chain to walk. The app hosting the UI is still
    /// running, and that is what keystrokes must go to.
    ///
    /// Electron helpers carry `--type=`; the main process does not. The lowest
    /// matching pid is taken so the answer is stable.
    static func mainAppPid(bundle: String, in procs: [pid_t: RunningProcess]) -> pid_t? {
        let executablePrefix = bundle + "/Contents/MacOS/"
        return procs.values
            .filter { $0.command.hasPrefix(executablePrefix) && !$0.command.contains("--type=") }
            .map(\.pid)
            .min()
    }

    /// The .app bundle and the pid of the process running it.
    static func owningProcess(of pid: pid_t,
                              in procs: [pid_t: RunningProcess]) -> (app: String, pid: pid_t)? {
        var current = pid
        // Depth-capped, and the pid must strictly decrease toward launchd, so
        // a corrupt table cannot spin here.
        for _ in 0..<16 {
            guard let proc = procs[current] else { return nil }
            if let range = proc.command.range(of: ".app/Contents/MacOS/") {
                return (String(proc.command[..<range.lowerBound]) + ".app", proc.pid)
            }
            guard proc.ppid > 1, proc.ppid != current else { return nil }
            current = proc.ppid
        }
        return nil
    }

    /// Trims a model id down to something that fits a row: drops the vendor
    /// prefix and the trailing release date.
    static func shortModel(_ raw: String) -> String {
        var model = raw
        for prefix in ["claude-", "anthropic/", "openai/", "models/"] where model.hasPrefix(prefix) {
            model.removeFirst(prefix.count)
        }
        if let dash = model.lastIndex(of: "-") {
            let tail = model[model.index(after: dash)...]
            if tail.count == 8, tail.allSatisfy(\.isNumber) { model = String(model[..<dash]) }
        }
        return model
    }

    /// Cursor and Codex keep the chosen model in their own config rather than
    /// per session, so that default is the best we can honestly show.
    static func cursorDefaultModel() -> String {
        let url = home.appendingPathComponent(".cursor/cli-config.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = obj["model"] as? [String: Any] else { return "" }
        let name = (model["displayNameShort"] as? String)
            ?? (model["displayName"] as? String)
            ?? (model["modelId"] as? String) ?? ""
        return shortModel(name)
    }

    static func codexDefaultModel() -> String {
        let url = home.appendingPathComponent(".codex/config.toml")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("model"), let eq = trimmed.firstIndex(of: "=") else { continue }
            // Stop at the first `model = ...`; `model_reasoning_effort` is a
            // different key and must not match.
            let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
            guard key == "model" else { continue }
            let value = trimmed[trimmed.index(after: eq)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return shortModel(value)
        }
        return ""
    }

    /// The binary from a command line. Codex ships inside ChatGPT.app and is
    /// not on the login PATH, so the only reliable way to call it is the path
    /// the running process was launched from.
    static func executablePath(_ command: String) -> String? {
        if let flag = command.range(of: " -") {
            let head = String(command[..<flag.lowerBound])
            return head.isEmpty ? nil : head
        }
        return command.split(separator: " ").first.map(String.init)
    }

    static func abbreviate(_ path: String) -> String {
        let h = home.path
        return path.hasPrefix(h) ? "~" + path.dropFirst(h.count) : path
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: tool)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
