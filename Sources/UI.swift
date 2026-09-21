import SwiftUI

final class FleetModel: ObservableObject {
    @Published var agents: [Agent] = []
    @Published var expanded = false
    @Published var pinned = false
    @Published var selection: String?
    @Published var draft = ""
    @Published var toast: String?
    /// How many rows fit above the bottom of the screen; the rest scroll.
    @Published var maxRows = 10
    /// Next usage-window rollover, nil when no window is open.
    @Published var limit: LimitStatus?
    @Published var autoContinue = UserDefaults.standard.bool(forKey: "autoContinue") {
        didSet { UserDefaults.standard.set(autoContinue, forKey: "autoContinue") }
    }

    /// Showing fabricated rows. Must be impossible to miss.
    @Published var demo = false
    /// Keystroke delivery is unavailable until macOS grants Accessibility.
    /// Surfaced in the panel because a toast that scrolls away left the real
    /// blocker invisible for hours.
    @Published var needsAccessibility = false

    /// Whether auto-continue would act on a given agent at all.
    var autoCovers: (Agent) -> Bool = { _ in false }
    /// Rows armed to resume once their window rolls over, and the message each
    /// one is holding.
    @Published var armedSessions: Set<String> = []
    @Published var scheduledMessages: [String: String] = [:]
    var onToggleArmed: ((Agent, String) -> String)?
    var onReschedule: ((Agent, String) -> String)?

    func armed(for agent: Agent) -> Bool {
        guard let session = agent.sessionId else { return false }
        return armedSessions.contains(session)
    }

    func scheduledMessage(for agent: Agent) -> String? {
        guard let session = agent.sessionId else { return nil }
        return scheduledMessages[session]
    }

    var busy: [Agent] { agents.filter { $0.state == .busy } }
    /// Up, but the source tells us nothing about whether it is working.
    var running: [Agent] { agents.filter { $0.state == .live } }
    var waiting: [Agent] { agents.filter { $0.state == .idle } }
    var asking: [Agent] { agents.filter { $0.state == .asking } }
    var limited: [Agent] { agents.filter { $0.state == .limited } }



    /// True when auto-continue is armed and this row is one it would act on.
    func autoArmed(for agent: Agent) -> Bool { autoContinue && autoCovers(agent) }
    /// Blocked, but only reachable by typing — AUTO cannot take this one.
    var autoBlockedManual: (Agent) -> Bool = { _ in false }

    var selected: Agent? {
        agents.first { $0.id == selection } ?? agents.first(where: \.canMessage)
    }

    /// Only a row you actually clicked, unlike `selected`.
    var selectedRow: Agent? {
        guard let selection else { return nil }
        return agents.first { $0.id == selection }
    }

    /// Set by the app delegate so a hand-typed message resets auto-continue caps.
    var onManualSend: ((String?) -> Void)?
    /// The details block changes the panel height, so AppKit has to re-measure.
    var onHeightChange: (() -> Void)?
    /// Hands the keyboard back to whatever you were using before.
    var onReleaseFocus: (() -> Void)?

    func select(_ id: String?) {
        guard selection != id else { return }
        selection = id
        onHeightChange?()
    }

    func flash(_ message: String) {
        toast = message
        let token = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.toast == token { self?.toast = nil }
        }
    }
}

enum Palette {
    static let busy = Color(red: 0.18, green: 0.82, blue: 0.35)
    static let waiting = Color(red: 1.00, green: 0.84, blue: 0.04)
    static let asking = Color(red: 0.40, green: 0.68, blue: 1.00)
    static let limited = Color(red: 1.00, green: 0.35, blue: 0.33)
    /// Process is up but the source does not publish a turn status.
    static let running = Color(red: 0.55, green: 0.60, blue: 0.68)

    static func tint(_ source: Source) -> Color {
        switch source {
        case .claude: return Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex: return Color(red: 0.06, green: 0.64, blue: 0.50)
        case .cursor: return Color(red: 0.55, green: 0.50, blue: 0.96)
        }
    }

    static func dot(_ state: AgentState) -> Color {
        switch state {
        case .busy: return busy
        case .live: return running
        case .idle: return waiting
        case .asking: return asking
        case .limited: return limited
        }
    }
}

/// The window is sized in AppKit and the rows are laid out in SwiftUI, so both
/// sides have to measure from the same numbers.
enum Metrics {
    static let rowHeight: CGFloat = 54
    static let headerHeight: CGFloat = 38
    static let composerHeight: CGFloat = 96
    static let detailsHeight: CGFloat = 132
}

// MARK: - Root

struct NotchRoot: View {
    @ObservedObject var model: FleetModel
    let notchHeight: CGFloat
    let notchWidth: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            // Leaves the real menu bar untouched; clicks pass through here.
            Color.clear.frame(height: notchHeight)

            CollapsedTab(model: model, notchWidth: notchWidth)

            if model.expanded {
                Panel(model: model)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity
                    ))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: model.expanded)
    }
}

// MARK: - Collapsed tab

struct CollapsedTab: View {
    @ObservedObject var model: FleetModel
    let notchWidth: CGFloat

    var body: some View {
        HStack(spacing: 10) {
            if !model.limited.isEmpty {
                Counter(color: Palette.limited, count: model.limited.count)
            }
            if !model.asking.isEmpty {
                Counter(color: Palette.asking, count: model.asking.count)
            }
            if !model.busy.isEmpty {
                Counter(color: Palette.busy, count: model.busy.count)
            }
            if !model.waiting.isEmpty {
                Counter(color: Palette.waiting, count: model.waiting.count)
            }
            if !model.running.isEmpty {
                Counter(color: Palette.running, count: model.running.count)
            }
            if model.autoContinue {
                // Worth knowing at a glance that something is nudging agents
                // while the panel is shut.
                Image(systemName: "bolt.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(Palette.busy.opacity(0.9))
            }
            if model.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: model.expanded ? 22 : 18)
        .frame(minWidth: max(notchWidth * 0.6, 84))
        .background(
            UnevenRoundedRectangle(bottomLeadingRadius: 11, bottomTrailingRadius: 11)
                .fill(.black)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            model.pinned.toggle()
            // Unpinning is the deliberate "I'm done here", so release the
            // keyboard then — never on a poll.
            if !model.pinned { model.onReleaseFocus?() }
        }
        .help(model.pinned ? "Click to unpin" : "Click to keep open")
    }
}

struct Counter: View {
    let color: Color
    let count: Int

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(count)")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
    }
}

// MARK: - Expanded panel

struct Panel: View {
    @ObservedObject var model: FleetModel
    /// Lays the rows out statically and draws the composer field as plain
    /// text. `ImageRenderer` renders neither a `ScrollView`'s content nor a
    /// `TextField`, so this is what lets the README image be the real panel
    /// rather than a mockup. Never set by the app.
    var preview = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(.white.opacity(0.08))

            if model.agents.isEmpty {
                Text("No agents running")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                let rows = VStack(spacing: 2) {
                    ForEach(model.agents) { agent in
                        AgentRow(model: model, agent: agent)
                    }
                }
                .padding(.vertical, 6)

                if preview {
                    rows
                } else {
                    ScrollView(.vertical) { rows }
                        .scrollIndicators(.never)
                        .frame(maxHeight: CGFloat(model.maxRows) * Metrics.rowHeight + 12)
                }
            }

            if let target = model.selectedRow {
                Divider().overlay(.white.opacity(0.08))
                Details(model: model, agent: target)
            }

            Divider().overlay(.white.opacity(0.08))
            composer
        }
        .frame(width: 452)
        .background(RoundedRectangle(cornerRadius: 16).fill(.black.opacity(0.92)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.10)))
        .shadow(color: .black.opacity(0.5), radius: 22, y: 10)
        .padding(.top, 5)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("AGENT FLEET")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.1)
                .foregroundStyle(.white.opacity(0.5))

            if model.demo {
                // Fake rows that look real are worse than no rows at all.
                Text("DEMO DATA · NOT YOUR AGENTS")
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .tracking(0.4)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Palette.limited))
            }

            if !model.asking.isEmpty {
                Text("\(model.asking.count) need\(model.asking.count == 1 ? "s" : "") you")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Palette.asking))
            }

            if model.needsAccessibility {
                Button {
                    Actions.openAccessibilitySettings()
                    model.flash("Add \"Agent Fleet\" under Accessibility, then try Send again")
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 8, weight: .bold))
                        Text("ALLOW TYPING")
                            .font(.system(size: 9, weight: .heavy, design: .rounded))
                            .tracking(0.4)
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Palette.waiting))
                }
                .buttonStyle(.plain)
                .help("Claude and Cursor are messaged by typing into their window, which macOS gates behind Accessibility. Click to open the setting.")
            }

            if !model.limited.isEmpty {
                Text("\(model.limited.count) blocked")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Palette.limited))
            }

            Spacer()

            if let toast = model.toast {
                Text(toast)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.busy)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Button {
                model.autoContinue.toggle()
                model.flash(model.autoContinue
                    ? autoOnNote
                    : "Auto-continue off")
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: model.autoContinue ? "bolt.fill" : "bolt.slash")
                        .font(.system(size: 8.5, weight: .bold))
                    Text("AUTO")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(0.6)
                }
                .foregroundStyle(model.autoContinue ? .black : .white.opacity(0.5))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(model.autoContinue ? Palette.busy : Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help(model.autoContinue
                ? "Auto-continue is on. Any agent blocked by its usage window gets \"continue\" when that window resets."
                : "Auto-continue is off. Turn it on and agents blocked by a usage limit resume by themselves once it resets.")

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .buttonStyle(.plain)
            .help("Quit Agent Fleet")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Names what it will actually cover, so the switch is not a mystery.
    private var autoOnNote: String {
        let covered = model.agents.filter { model.autoCovers($0) }
        if covered.isEmpty {
            return "Auto-continue on — nothing is limit-blocked right now"
        }
        return "Auto-continue on — will resume \(covered.map(\.name).joined(separator: ", ")) at reset"
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(["continue", "keep going", "stop"], id: \.self) { phrase in
                    Button(phrase) { send(phrase) }
                        .buttonStyle(ChipStyle())
                }
                Spacer()
            }

            HStack(spacing: 8) {
                if preview {
                    Text("Message \(model.selected?.name ?? "an agent")…")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.4))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.07)))
                } else {
                    TextField("Message \(model.selected?.name ?? "an agent")…", text: $model.draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.07)))
                        .onSubmit { send(model.draft) }
                }

                // A blocked agent cannot receive anything now, so Send *is*
                // Schedule — same button, same return key, label says which.
                Button(sendLabel) { send(model.draft) }
                    .buttonStyle(ChipStyle(prominent: true))
                    .disabled(model.draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if let target = model.selected {
                if !target.canMessage {
                    Text("Nothing to message here — Stop and Quit still work.")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.35))
                } else if let note = routeNote(target) {
                    Text(note)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    /// Codex and Cursor cannot be aimed at one exact conversation, so say what
    /// the message will actually reach.
    private func routeNote(_ agent: Agent) -> String? {
        if let resets = agent.limitResetsAt {
            if let queued = model.scheduledMessage(for: agent) {
                return "Queued for \(clockTime(resets)): \"\(queued)\" — Schedule replaces it."
            }
            return "Blocked until \(clockTime(resets)). Schedule holds your message until then."
        }
        switch agent.source {
        case .claude:
            guard agent.isInteractive else { return "Background session — delivered directly." }
            return model.needsAccessibility
                ? "Send will only copy it: typing into \(agent.ownerAppName ?? "the terminal") needs Accessibility."
                : "Send focuses \(agent.ownerAppName ?? "the terminal"), pastes and hits return."
        case .codex: return "Goes to the Codex thread that moved last."
        case .cursor:
            return model.needsAccessibility
                ? "Send will only copy it: typing into Cursor's chat needs Accessibility."
                : "Send focuses Cursor, opens its chat with ⌘L, pastes and hits return."
        }
    }

    /// What the button and the return key will do with the current target.
    private var sendLabel: String {
        guard let target = model.selected, let resets = target.limitResetsAt,
              target.canMessage else { return "Send" }
        return "Schedule \(clockTime(resets))"
    }

    private func send(_ text: String) {
        guard let target = model.selected else {
            model.flash("Pick an agent first")
            return
        }
        // Cleared first: a second dispatch of the same keypress then has
        // nothing to send, which is the other half of the double-send fix.
        model.draft = ""

        // Blocked by its usage window? Then the only useful thing is to hold
        // the message until that window rolls over — no separate button to
        // remember, and the return key behaves the same way.
        if target.limitResetsAt != nil, target.canMessage {
            let note = model.armed(for: target)
                ? model.onReschedule?(target, text)
                : model.onToggleArmed?(target, text)
            model.flash(note ?? "")
            return
        }

        model.flash(Actions.send(text, to: target))
        model.onManualSend?(target.sessionId)
    }
}

// MARK: - Details

/// Everything about one agent that does not fit in a row.
struct Details: View {
    @ObservedObject var model: FleetModel
    let agent: Agent

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let queued = model.scheduledMessage(for: agent), let resets = agent.limitResetsAt {
                line("queued", "\(clockTime(resets)) → \"\(queued)\"", tint: Palette.busy)
            }
            if let question = agent.question {
                line("asking", question, tint: Palette.asking)
            } else if !agent.message.isEmpty {
                line("latest", agent.message)
            }

            HStack(alignment: .top, spacing: 14) {
                field("model", agent.model.isEmpty ? "unknown" : agent.model)
                field("state", agent.state.label)
                if let pct = agent.limitUsedPercent {
                    field("window", "\(Int(pct))% used", tint: Palette.limited)
                }
                if let read = agent.limitReadAt {
                    field("as of", clockTime(read))
                }
                if let resets = agent.limitResetsAt {
                    field("back in", shortDuration(resets.timeIntervalSinceNow), tint: Palette.limited)
                } else {
                    field("for", shortAge(agent.age))
                }
                field("pid", "\(agent.pid)")
            }

            if !agent.source.publishesIdleState {
                line("status", agent.source == .cursor
                    ? "Worker status is real (READY / CLAIMED), but a Cursor agent waiting on your answer runs nothing locally, so \"asking\" cannot be seen from here"
                    : "Codex publishes no local turn state; only its usage window is readable")
            }
            line("path", Discovery.abbreviate(agent.cwd))
            if let session = agent.sessionId, agent.source != .cursor {
                line(agent.source == .codex ? "thread" : "session", session)
            }

            HStack(spacing: 6) {
                Button(agent.ownerAppName.map { "Open \($0)" } ?? "Open app") {
                    model.flash(Actions.reveal(agent))
                }
                .buttonStyle(ChipStyle(prominent: true))

                if let resets = agent.limitResetsAt, agent.canMessage {
                    let isArmed = model.armed(for: agent)
                    Button(isArmed ? "Cancel \(clockTime(resets))" : "Schedule \(clockTime(resets))") {
                        model.flash(model.onToggleArmed?(agent, model.draft) ?? "")
                    }
                    .buttonStyle(ChipStyle(tint: isArmed ? Palette.busy : .white.opacity(0.75)))
                }
                if agent.source == .claude {
                    Button("Transcript") { model.flash(Actions.revealTranscript(agent)) }
                        .buttonStyle(ChipStyle())
                }
                Button("Log") { model.flash(Actions.openLog(agent)) }
                    .buttonStyle(ChipStyle())
                Spacer()
                Button("Close") { model.select(nil) }
                    .buttonStyle(ChipStyle())
            }
            .padding(.top, 1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func line(_ label: String, _ value: String, tint: Color = .white.opacity(0.62)) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Text(label.uppercased())
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .tracking(0.5)
                .foregroundStyle(.white.opacity(0.3))
                .frame(width: 44, alignment: .leading)
                .padding(.top, 1)
            Text(value)
                .font(.system(size: 10.5))
                .foregroundStyle(tint)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private func field(_ label: String, _ value: String, tint: Color = .white.opacity(0.7)) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .tracking(0.5)
                .foregroundStyle(.white.opacity(0.3))
            Text(value)
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(tint)
                .lineLimit(1)
        }
    }
}

// MARK: - Row

struct AgentRow: View {
    @ObservedObject var model: FleetModel
    let agent: Agent
    @State private var hovering = false

    private var isSelected: Bool { model.selection == agent.id }

    /// For Claude the age is how long the agent has been in this state, which
    /// is meaningful. For a Cursor worker it is only process uptime, and
    /// showing "running · 7h" made an idle worker look like an agent that had
    /// been grinding for seven hours. So the sources without a turn status get
    /// no clock at all.
    private var stateText: String {
        guard agent.state == .live else {
            return "\(agent.state.label) · \(shortAge(agent.age))"
        }
        switch agent.source {
        case .cursor: return "attached"
        case .codex: return "daemon up"
        case .claude: return agent.state.label
        }
    }

    /// The window is only worth a row badge when it is nearly gone. Full
    /// numbers always live in the details block.
    private var windowWarning: String? {
        if let pct = agent.limitUsedPercent, pct >= 90, agent.state != .limited {
            return "\(Int(pct))% of window used"
        }
        // The Claude window is account-wide, so it applies to every Claude row.
        if agent.source == .claude, agent.state != .limited, let limit = model.limit {
            if limit.exhausted { return "window spent · \(clockTime(limit.windowEnd))" }
            if limit.remaining < 15 * 60 { return "window ends in \(shortDuration(limit.remaining))" }
        }
        return nil
    }

    /// A wash of colour for the two states you need to spot without reading.
    private var rowTint: Color {
        switch agent.state {
        case .limited: return Palette.limited.opacity(0.11)
        case .asking: return Palette.asking.opacity(0.09)
        default: return .clear
        }
    }

    private var rowBorder: Color {
        switch agent.state {
        case .limited: return Palette.limited.opacity(0.32)
        case .asking: return Palette.asking.opacity(0.26)
        default: return .clear
        }
    }

    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(Palette.dot(agent.state))
                .frame(width: 7, height: 7)

            Text(agent.source.label)
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .tracking(0.5)
                .foregroundStyle(Palette.tint(agent.source))
                .frame(width: 44, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(agent.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    // Per row: whether AUTO will pick this one up when its
                    // window resets, or whether it cannot.
                    if model.autoContinue, model.autoArmed(for: agent) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(Palette.busy)
                            .help("Auto-continue will send \"continue\" when this window resets")
                    } else if model.autoContinue, model.autoBlockedManual(agent) {
                        Image(systemName: "bolt.slash")
                            .font(.system(size: 8))
                            .foregroundStyle(.white.opacity(0.35))
                            .help("Blocked, but this one is only reachable by typing into its window, so auto-continue leaves it alone")
                    }
                }
                HStack(spacing: 5) {
                    if !agent.model.isEmpty {
                        Text(agent.model)
                            .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(Palette.tint(agent.source).opacity(0.95))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Palette.tint(agent.source).opacity(0.14))
                            )
                            .lineLimit(1)
                            .fixedSize()
                    }
                    Text(agent.detail)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.white.opacity(0.38))
                        .lineLimit(1)
                        .truncationMode(.head)
                }

                // The latest thing it said, always on screen. A pending
                // question replaces it, since that is what you need to read.
                if let queued = model.scheduledMessage(for: agent) {
                    HStack(spacing: 4) {
                        Image(systemName: "clock.badge.checkmark")
                            .font(.system(size: 8))
                            .foregroundStyle(Palette.busy)
                        Text("queued: \(queued)")
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.busy.opacity(0.9))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .padding(.top, 1)
                } else if let line = agent.question ?? (agent.message.isEmpty ? nil : agent.message) {
                    HStack(spacing: 4) {
                        if agent.question != nil {
                            Image(systemName: "questionmark.bubble.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(Palette.asking)
                        }
                        Text(line)
                            .font(.system(size: 10))
                            .foregroundStyle(agent.question != nil
                                ? Palette.asking.opacity(0.95)
                                : .white.opacity(0.5))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .padding(.top, 1)
                }
            }

            Spacer(minLength: 6)

            if hovering {
                HStack(spacing: 4) {
                    if agent.canMessage, agent.state != .limited {
                        if agent.state == .asking {
                            // It wants an answer, not a nudge — put the cursor
                            // in the composer aimed at this row.
                            RowButton("Answer", tint: Palette.asking) {
                                model.select(agent.id)
                            }
                        } else {
                            RowButton("Continue", tint: Palette.busy) {
                                model.flash(Actions.send("continue", to: agent))
                                model.onManualSend?(agent.sessionId)
                            }
                        }
                    }
                    RowButton("Stop") { model.flash(Actions.interrupt(agent)) }
                    RowButton("Quit", tint: .red.opacity(0.85)) { model.flash(Actions.quit(agent)) }
                }
            } else if let resets = agent.limitResetsAt {
                // How long until it can work again is the only useful number
                // here. Where the source gives a percentage rather than a
                // rejection, show the percentage — it is the honest version.
                let isArmed = model.armed(for: agent)
                VStack(alignment: .trailing, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(agent.limitUsedPercent.map { "\(Int($0))% used" } ?? "limit reached")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(Palette.limited)

                        if agent.canMessage {
                            Button {
                                // The bolt is the quick path: whatever is in
                                // the composer, else "continue".
                                model.flash(model.onToggleArmed?(agent, model.draft) ?? "")
                            } label: {
                                Image(systemName: isArmed ? "bolt.fill" : "bolt")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(isArmed ? .black : .white.opacity(0.5))
                                    .padding(3)
                                    .background(Circle().fill(isArmed ? Palette.busy : .white.opacity(0.1)))
                            }
                            .buttonStyle(.plain)
                            .help(isArmed
                                ? "Scheduled for \(clockTime(resets)): \"\(model.scheduledMessage(for: agent) ?? "")\". Click to cancel."
                                : "Schedule a message for \(clockTime(resets)), when the window resets. Type it in the composer first, or leave empty for \"continue\".")
                        }
                    }
                    Text(isArmed
                        ? "resumes \(clockTime(resets))"
                        : "back in \(shortDuration(resets.timeIntervalSinceNow))")
                        .font(.system(size: 9, design: .rounded))
                        .foregroundStyle(isArmed ? Palette.busy : Palette.limited.opacity(0.7))
                }
                .fixedSize()
            } else if let warning = windowWarning {
                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(agent.state.label) · \(shortAge(agent.age))")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.white.opacity(0.45))
                    Text(warning)
                        .font(.system(size: 9, design: .rounded))
                        .foregroundStyle(Palette.waiting.opacity(0.85))
                }
                .fixedSize()
            } else if agent.source == .cursor {
                Text(agent.state == .busy ? "working" : agent.state == .idle ? "ready" : "attached")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.white.opacity(agent.state == .busy ? 0.55 : 0.32))
            } else {
                Text(stateText)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.white.opacity(agent.state == .live ? 0.3 : 0.45))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(isSelected ? .white.opacity(0.11) : (hovering ? .white.opacity(0.05) : .clear))
        )
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(rowTint)
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(rowBorder, lineWidth: 1)
                )
        )
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture { model.select(isSelected ? nil : agent.id) }
        .onHover { hovering = $0 }
    }
}

struct RowButton: View {
    let title: String
    var tint: Color = .white.opacity(0.75)
    let action: () -> Void

    init(_ title: String, tint: Color = .white.opacity(0.75), action: @escaping () -> Void) {
        self.title = title
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(title, action: action).buttonStyle(ChipStyle(tint: tint))
    }
}

struct ChipStyle: ButtonStyle {
    var prominent = false
    var tint: Color = .white.opacity(0.75)

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(prominent ? .black : tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(prominent ? Color.white.opacity(0.9) : Color.white.opacity(0.09))
            )
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
