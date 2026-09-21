import Foundation

/// Picks agents back up when their usage window rolls over.
///
/// This used to also nudge idle sessions, which conflated two different things
/// under one switch and only ever worked for Claude. "Auto-continue" now means
/// one thing: an agent stopped because it hit a limit gets "continue" the
/// moment that limit resets — whichever tool it belongs to.
///
/// The guards still matter more than the feature:
///
/// - only agents that actually report a limit, and only ones that can be
///   delivered to without a person present. Anything reached by typing at a
///   window is excluded, because unattended keystrokes land wherever the user
///   happens to be looking.
/// - it fires on the clock, not on the block clearing: a blocked reading only
///   refreshes when the agent next writes, so waiting for it would wait
///   forever.
/// - a margin past the reset, so the first request is not racing the rollover.
/// - anything you send by hand cancels what was queued — you handled it.
final class AutoPilot {
    private struct Record {
        var lastSent: Date
    }

    private var records: [String: Record] = [:]
    /// What to send when a window rolls over, per session. Opt-in per row on
    /// purpose: a blocked agent may be blocked on work you deliberately
    /// abandoned, and quota should not be spent restarting it unless you said
    /// so — with the message you chose, not a canned one.
    struct Scheduled: Equatable {
        let at: Date
        let message: String
    }

    private var armed: [String: Scheduled] = [:] {
        didSet { persistArmed() }
    }
    /// A small margin past the reset, so the first request is not racing the
    /// window rolling over.
    var resumeBuffer: TimeInterval = 30

    /// Injectable so the guards can be tested without launching agents.
    var sender: (String, Agent) -> String = {
        Actions.send($0, to: $1, allowKeystrokes: false)
    }

    private static let armedKey = "armedResumes"
    static let defaultMessage = "continue"
    /// How far past a reset a restored arming is still honoured. Without this,
    /// relaunching the app the next morning would fire a resume the moment it
    /// started, for a window that rolled over hours ago.
    private static let staleAfter: TimeInterval = 30 * 60

    init() {
        guard let stored = UserDefaults.standard.dictionary(forKey: Self.armedKey) else { return }
        let cutoff = Date().addingTimeInterval(-Self.staleAfter)
        armed = stored.compactMapValues { entry -> Scheduled? in
            guard let fields = entry as? [String: Any],
                  let stamp = fields["at"] as? Double else { return nil }
            let at = Date(timeIntervalSince1970: stamp)
            guard at > cutoff else { return nil }
            return Scheduled(at: at, message: fields["message"] as? String ?? Self.defaultMessage)
        }
    }

    private func persistArmed() {
        let payload = armed.mapValues { ["at": $0.at.timeIntervalSince1970, "message": $0.message] }
        UserDefaults.standard.set(payload, forKey: Self.armedKey)
    }

    /// Called for every poll. Returns a line to flash in the header, if it
    /// acted. `autoResume` is the global AUTO switch; rows you armed by hand
    /// fire either way, because arming one is already an explicit instruction.
    func tick(agents: [Agent], autoResume: Bool) -> String? {
        // Forget sessions that are gone, so ids cannot leak for a whole uptime.
        let live = Set(agents.compactMap(\.sessionId))
        records = records.filter { live.contains($0.key) }
        armed = armed.filter { live.contains($0.key) }

        if autoResume {
            // Whatever is blocked and reachable gets queued, so the row shows
            // what will happen before it happens.
            for agent in agents where canAutoResume(agent) {
                guard let session = agent.sessionId, let resets = agent.limitResetsAt else { continue }
                guard armed[session] == nil else { continue }
                armed[session] = Scheduled(at: resets, message: Self.defaultMessage)
            }
        }

        return resumeArmed(agents)
    }

    /// Blocked by a limit, and deliverable with nobody watching.
    func canAutoResume(_ agent: Agent) -> Bool {
        agent.limitResetsAt != nil && agent.canMessage && !Actions.needsKeystrokes(agent)
    }

    /// Blocked, but only reachable by typing at a window — so AUTO cannot
    /// take it, and the row should say why rather than look ignored.
    func blockedButManual(_ agent: Agent) -> Bool {
        agent.limitResetsAt != nil && agent.canMessage && Actions.needsKeystrokes(agent)
    }

    /// Sends "continue" to an armed session once its window has rolled over.
    ///
    /// This fires on the clock rather than on the block clearing: the blocked
    /// reading itself only refreshes when the agent next writes, so waiting for
    /// it to clear would wait forever.
    private func resumeArmed(_ agents: [Agent]) -> String? {
        for agent in agents {
            guard let session = agent.sessionId, let scheduled = armed[session] else { continue }
            guard Date() >= scheduled.at.addingTimeInterval(resumeBuffer) else { continue }
            guard agent.canMessage else {
                armed[session] = nil
                return "Cannot resume \(agent.name) — nothing to message"
            }
            let result = sender(scheduled.message, agent)
            armed[session] = nil
            records[session] = Record(lastSent: Date())
            return result.hasPrefix("Sent")
                ? "Window reset — sent \"\(scheduled.message)\" to \(agent.name)"
                : result
        }
        return nil
    }

    /// Arms or disarms a row. An empty message falls back to "continue".
    func toggleArmed(_ agent: Agent, message: String = defaultMessage) -> String {
        guard let session = agent.sessionId else { return "Nothing to arm here" }
        if armed[session] != nil {
            armed[session] = nil
            return "Cancelled the scheduled message for \(agent.name)"
        }
        guard let resets = agent.limitResetsAt else { return "No reset time known yet" }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = text.isEmpty ? Self.defaultMessage : text
        armed[session] = Scheduled(at: resets, message: body)
        return "\(clockTime(resets)) → \"\(body)\" to \(agent.name)"
    }

    /// Replaces the message on an already-armed row.
    func reschedule(_ agent: Agent, message: String) -> String {
        guard let session = agent.sessionId, let existing = armed[session] else {
            return toggleArmed(agent, message: message)
        }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "Nothing to schedule" }
        armed[session] = Scheduled(at: existing.at, message: text)
        return "\(clockTime(existing.at)) → \"\(text)\" to \(agent.name)"
    }

    /// What is queued for a session, for the row and details to show.
    func scheduled(_ sessionId: String?) -> Scheduled? {
        guard let sessionId else { return nil }
        return armed[sessionId]
    }

    func isArmed(_ sessionId: String?) -> Bool {
        guard let sessionId else { return false }
        return armed[sessionId] != nil
    }

    var armedSessions: Set<String> { Set(armed.keys) }

    /// Anything you type by hand means you are back, so the caps reset.
    func noteManualSend(_ sessionId: String?) {
        guard let sessionId else { return }
        records[sessionId] = nil
        // You handled it yourself, so the pending resume is moot.
        armed[sessionId] = nil
    }

    /// Whether AUTO would act on this agent at all — what the row badge means.
    func covers(_ agent: Agent) -> Bool { canAutoResume(agent) }
}
