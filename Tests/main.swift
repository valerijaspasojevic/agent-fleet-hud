import Foundation

// A plain executable rather than XCTest, so `./test.sh` works with nothing but
// the Swift toolchain — the same bar as `./build.sh`.
//
// Most of these encode something that was once wrong. The window-anchoring
// formula is checked against a reset Claude Code actually recorded; the
// duplicate guard exists because one keypress could send twice; the autopilot
// guards exist because unattended messages cost real quota.

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool) {
    if condition {
        passed += 1
        print("  ok   \(name)")
    } else {
        failed += 1
        print("  FAIL \(name)")
    }
}

func section(_ title: String) { print("\n\(title)") }

func agent(_ source: Source,
           state: AgentState = .idle,
           interactive: Bool = true,
           session: String? = "session-1",
           resets: Date? = nil,
           age: Double = 600,
           cwd: String = "/tmp/workspace") -> Agent {
    Agent(id: "\(source.rawValue)-test", source: source, name: "test-agent", cwd: cwd, pid: 1,
          state: state, age: age, sessionId: session, detail: "", message: "", question: nil,
          limitResetsAt: resets, limitUsedPercent: resets != nil ? 97 : nil, limitReadAt: nil,
          model: "model", executable: "/bin/echo", isInteractive: interactive,
          ownerApp: nil, ownerPid: nil, tty: nil)
}

// MARK: - Usage windows

section("usage windows")

let iso = ISO8601DateFormatter()
let recordedAnchor = iso.date(from: "2026-09-20T08:36:03Z")!.timeIntervalSince1970
let derivedEnd = (recordedAnchor / Limits.anchorStep).rounded(.down) * Limits.anchorStep
    + Limits.windowLength
// Claude Code recorded resetsAt = 1789911000 for a window anchored here.
check("a derived window end matches a recorded resetsAt", derivedEnd == 1789911000)
check("a window that has closed is not reported",
      Limits.estimatedWindowEnd(stamps: [recordedAnchor]) == nil)
check("an open window is reported",
      Limits.estimatedWindowEnd(stamps: [Date().timeIntervalSince1970]) != nil)

let stamp = Limits.firstTimestamp(in: Substring(#"{"timestamp":"2026-09-20T08:36:03.123Z"}"#))
check("the hand-rolled timestamp parser matches Foundation", stamp == recordedAnchor)
check("a line with no timestamp yields nil",
      Limits.firstTimestamp(in: Substring(#"{"other":1}"#)) == nil)
check("a malformed month is rejected",
      Limits.firstTimestamp(in: Substring(#"{"timestamp":"2026-99-20T08:36:03Z"}"#)) == nil)

check("days_from_civil agrees with a known epoch day",
      Limits.daysFromEpoch(year: 1970, month: 1, day: 1) == 0)
check("and with a leap year",
      Limits.daysFromEpoch(year: 2000, month: 3, day: 1) == 11017)

check("a duration rounds to whole minutes", shortDuration(3660) == "1h 1m")
check("a sub-minute duration says so", shortDuration(30) == "<1m")

// MARK: - Codex

section("codex")

check("a rollout filename yields its thread id",
      CodexState.threadId(
        fromRollout: "rollout-2026-09-19T15-45-59-01a0b4cd-63fb-7ae0-abe2-bcadb6e8f991_x.jsonl")
        == "01a0b4cd-63fb-7ae0-abe2-bcadb6e8f991")
check("a rollout without a turn suffix also works",
      CodexState.threadId(
        fromRollout: "rollout-2026-09-12T10-33-24-01a094bf-f9a5-7250-8940-7042d936908d.jsonl")
        == "01a094bf-f9a5-7250-8940-7042d936908d")
check("a filename with no uuid yields nil",
      CodexState.threadId(fromRollout: "rollout-nonsense.jsonl") == nil)

let blocked = CodexUsage(usedPercent: 97, windowMinutes: 300,
                         resetsAt: Date().addingTimeInterval(3600), recordedAt: Date())
check("97% counts as blocked", blocked.isBlocked)
check("a live window is live", blocked.isLive)
check("the window label is readable", blocked.windowLabel == "5h window")
let fine = CodexUsage(usedPercent: 40, windowMinutes: 300,
                      resetsAt: Date().addingTimeInterval(3600), recordedAt: Date())
check("40% is not blocked", !fine.isBlocked)

// MARK: - Delivery routing

section("delivery routing")

check("an interactive Claude session is typed at",
      Actions.needsKeystrokes(agent(.claude, interactive: true)))
check("a background Claude session has a real API",
      !Actions.needsKeystrokes(agent(.claude, interactive: false)))
check("Cursor is typed at", Actions.needsKeystrokes(agent(.cursor)))
check("Codex has a real API", !Actions.needsKeystrokes(agent(.codex)))

check("a nonexistent bundle is not a terminal",
      TerminalDelivery.Target.forApp("/nowhere/Nothing.app") == nil)
check("a nonexistent bundle is treated as native",
      !TerminalDelivery.needsFocus(appBundle: "/nowhere/Nothing.app"))
if let terminal = Discovery.appPath(bundleId: "com.apple.Terminal") {
    check("Terminal.app is recognised by bundle id",
          TerminalDelivery.Target.forApp(terminal) != nil)
}
check("an unknown bundle id resolves to nothing",
      Discovery.appPath(bundleId: "com.example.definitely-not-installed") == nil)

// MARK: - Sending

section("sending")

Actions.sharingTargetApp = { _ in 1 }
var outcomes: [String] = []
Actions.onResult = { outcomes.append($0) }
func settle(_ seconds: TimeInterval = 2) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

let started = Date()
let queued = Actions.send("first message", to: agent(.codex))
// This froze the app twice by waiting on osascript from the main thread.
check("send returns without blocking", Date().timeIntervalSince(started) < 0.05)
check("and reports that it is in flight", queued.contains("Sending"))
settle()
check("the outcome arrives on the callback", !outcomes.isEmpty)

check("an empty message is refused", Actions.send("   ", to: agent(.codex)) == "Nothing to send")

_ = Actions.send("repeated message", to: agent(.codex))
check("the same message twice is a double-fire, not an intent",
      Actions.send("repeated message", to: agent(.codex)) == "Already sending that")
check("a different message is not a duplicate",
      !Actions.send("another message", to: agent(.codex)).contains("Already"))

outcomes = []
_ = Actions.send("unattended", to: agent(.cursor), allowKeystrokes: false)
settle()
// `last` raced with an earlier send's callback arriving late.
check("nothing is typed unattended", outcomes.contains { $0.contains("by hand") })

Actions.sharingTargetApp = { _ in 3 }
outcomes = []
_ = Actions.send("ambiguous", to: agent(.claude))
settle()
check("it refuses rather than guess which tab",
      outcomes.contains { $0.contains("share") })
Actions.sharingTargetApp = { _ in 1 }

// MARK: - Auto-continue

section("auto-continue")

let armedKey = "armedResumes"

/// Records what the autopilot would have sent, instead of sending it.
final class Recorder {
    var sent: [String] = []
}
let recorder = Recorder()

func pilot() -> AutoPilot {
    UserDefaults.standard.removeObject(forKey: armedKey)
    recorder.sent = []
    let auto = AutoPilot()
    auto.sender = { text, target in
        recorder.sent.append(text)
        return "Sent \"\(text)\" to \(target.name)"
    }
    return auto
}

var auto = pilot()
let past = Date().addingTimeInterval(-120)
let future = Date().addingTimeInterval(3600)

_ = auto.tick(agents: [agent(.codex, state: .limited, resets: past)], autoResume: false)
check("a blocked agent is not resumed unless asked", recorder.sent.isEmpty)

auto = pilot()
_ = auto.tick(agents: [agent(.codex, state: .limited, resets: future)], autoResume: true)
check("AUTO queues a blocked agent without firing early", recorder.sent.isEmpty)
check("and the row shows what is queued",
      auto.scheduled("session-1")?.message == AutoPilot.defaultMessage)

auto = pilot()
_ = auto.tick(agents: [agent(.codex, state: .limited, resets: past)], autoResume: true)
check("AUTO resumes once the window has rolled over", recorder.sent == [AutoPilot.defaultMessage])
check("and disarms afterwards", auto.scheduled("session-1") == nil)
_ = auto.tick(agents: [agent(.codex, state: .limited, resets: past)], autoResume: true)
check("without firing twice for the same window", recorder.sent.count == 1)

auto = pilot()
_ = auto.toggleArmed(agent(.codex, state: .limited, resets: past), message: "custom text")
_ = auto.tick(agents: [agent(.codex, state: .limited, resets: past)], autoResume: false)
check("a scheduled message sends your words, not a canned one", recorder.sent == ["custom text"])

auto = pilot()
_ = auto.toggleArmed(agent(.codex, state: .limited, resets: past), message: "  ")
_ = auto.tick(agents: [agent(.codex, state: .limited, resets: past)], autoResume: false)
check("a blank scheduled message falls back to continue", recorder.sent == [AutoPilot.defaultMessage])

auto = pilot()
_ = auto.toggleArmed(agent(.codex, state: .limited, resets: future), message: "held")
_ = auto.reschedule(agent(.codex, state: .limited, resets: future), message: "replaced")
check("rescheduling replaces the message", auto.scheduled("session-1")?.message == "replaced")
check("and keeps the fire time",
      auto.scheduled("session-1")?.at.timeIntervalSince1970 == future.timeIntervalSince1970)

auto = pilot()
_ = auto.toggleArmed(agent(.codex, state: .limited, resets: future), message: "held")
auto.noteManualSend("session-1")
check("sending by hand cancels what was queued", auto.scheduled("session-1") == nil)

auto = pilot()
check("a row with no known reset cannot be armed",
      auto.toggleArmed(agent(.codex)).contains("No reset"))

auto = pilot()
_ = auto.toggleArmed(agent(.codex, state: .limited, resets: past), message: "gone")
_ = auto.tick(agents: [], autoResume: false)
check("an agent that disappears takes its queue with it",
      auto.scheduled("session-1") == nil && recorder.sent.isEmpty)

check("AUTO covers a blocked agent with a real API",
      auto.canAutoResume(agent(.codex, state: .limited, resets: future)))
check("AUTO will not type at a window unattended",
      !auto.canAutoResume(agent(.cursor, state: .limited, resets: future)))
check("and says such a row is blocked-but-manual",
      auto.blockedButManual(agent(.cursor, state: .limited, resets: future)))

UserDefaults.standard.set(
    ["stale-session": ["at": Date().addingTimeInterval(-6 * 3600).timeIntervalSince1970,
                       "message": "yesterday"]],
    forKey: armedKey)
check("a long-stale queue is dropped rather than fired on launch",
      AutoPilot().scheduled("stale-session") == nil)
UserDefaults.standard.set(
    ["fresh-session": ["at": Date().addingTimeInterval(-60).timeIntervalSince1970,
                       "message": "recent"]],
    forKey: armedKey)
check("a recent queue survives a restart",
      AutoPilot().scheduled("fresh-session")?.message == "recent")
UserDefaults.standard.removeObject(forKey: armedKey)

// MARK: - State

section("agent state")

check("a question outranks everything", AgentState.asking.urgency < AgentState.limited.urgency)
check("being blocked outranks working", AgentState.limited.urgency < AgentState.busy.urgency)
check("idle sorts after working", AgentState.busy.urgency < AgentState.idle.urgency)
check("a bare process carries no news at all", AgentState.idle.urgency < AgentState.live.urgency)
check("only Claude claims a real idle status", Source.claude.publishesIdleState)
check("Cursor does not", !Source.cursor.publishesIdleState)
check("Codex does not", !Source.codex.publishesIdleState)

check("a model id loses its vendor prefix", Discovery.shortModel("claude-opus-5") == "opus-5")
check("and its release date", Discovery.shortModel("claude-haiku-4-5-20251001") == "haiku-4-5")
check("a model id with neither is left alone", Discovery.shortModel("gpt-6-astra") == "gpt-6-astra")

check("shell quoting survives a quote", Actions.quoted("don't") == #"'don'\''t'"#)
check("and shell metacharacters",
      Actions.quoted("a && b") == "'a && b'")

check("an agent id is found in tab state",
      CursorAgents.firstAgentId(in: #"{"agentId":"bc-02bb99df-c62f-4a22-bef8-ed972a511e62"}"#)
        == "bc-02bb99df-c62f-4a22-bef8-ed972a511e62")
check("a plain uuid is not an agent id",
      CursorAgents.firstAgentId(in: #"{"id":"38b54486-e158-4eb4-b409-6635ce5ef05c"}"#) == nil)

// MARK: - Process parsing

section("process parsing")

check("etime in mm:ss", Discovery.parseEtime("01:30") == 90)
check("etime in hh:mm:ss", Discovery.parseEtime("02:00:00") == 7200)
check("etime with days", Discovery.parseEtime("1-00:00:00") == 86400)

var table: [pid_t: RunningProcess] = [:]
table[10] = RunningProcess(pid: 10, ppid: 11, age: 0, tty: nil, command: "a")
table[11] = RunningProcess(pid: 11, ppid: 10, age: 0, tty: nil, command: "b")
check("a cycle in the process table does not hang the walk",
      Discovery.owningApp(of: 10, in: table) == nil)
check("an unknown pid yields nothing", Discovery.owningApp(of: 9999, in: table) == nil)

var chain: [pid_t: RunningProcess] = [:]
chain[5] = RunningProcess(pid: 5, ppid: 6, age: 0, tty: "ttys001", command: "claude")
chain[6] = RunningProcess(pid: 6, ppid: 1, age: 0, tty: nil,
                          command: "/Applications/Example.app/Contents/MacOS/example --flag")
check("the owning bundle is found through the parent chain",
      Discovery.owningApp(of: 5, in: chain) == "/Applications/Example.app")
check("and its pid comes with it", Discovery.owningProcess(of: 5, in: chain)?.pid == 6)

var helpers: [pid_t: RunningProcess] = [:]
helpers[20] = RunningProcess(pid: 20, ppid: 1, age: 0, tty: nil,
                             command: "/Applications/E.app/Contents/MacOS/e --type=renderer")
helpers[21] = RunningProcess(pid: 21, ppid: 1, age: 0, tty: nil,
                             command: "/Applications/E.app/Contents/MacOS/e")
check("an Electron helper is not mistaken for the app",
      Discovery.mainAppPid(bundle: "/Applications/E.app", in: helpers) == 21)

check("a flag value with spaces is read whole",
      Discovery.flagValue("cmd --name my project @ host --other x", "--name")
        == "my project @ host")
check("a missing flag yields nil", Discovery.flagValue("cmd --a b", "--zzz") == nil)

check("a home path is abbreviated",
      Discovery.abbreviate(Discovery.home.appendingPathComponent("x").path) == "~/x")

// MARK: - Result

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
