import AppKit
import SwiftUI

// MARK: - Window

/// Borderless panel that can take keyboard focus without activating the app,
/// so typing a message never yanks you out of your terminal.
final class FleetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// AppKit routes ⌘V and friends through the application's main menu, and an
    /// accessory app with no menu bar has no Edit menu to route them to — so
    /// paste silently did nothing in the composer. Dispatching them to the
    /// first responder here restores the standard editing keys without
    /// building a menu the user would never see.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), !flags.contains(.control), !flags.contains(.option),
              let key = event.charactersIgnoringModifiers?.lowercased()
        else { return super.performKeyEquivalent(with: event) }

        let withShift = flags.contains(.shift)
        let action: Selector?
        switch key {
        case "v": action = #selector(NSText.paste(_:))
        case "c": action = #selector(NSText.copy(_:))
        case "x": action = #selector(NSText.cut(_:))
        case "a": action = #selector(NSText.selectAll(_:))
        // undo:/redo: are not declared on a concrete AppKit class, so these
        // two have to be named by string.
        case "z": action = withShift ? Selector(("redo:")) : Selector(("undo:"))
        default: action = nil
        }

        if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// Hosts the SwiftUI tree but refuses clicks in the menu bar strip, so the real
/// menu bar keeps working underneath us.
final class PassthroughView: NSView {
    var menuBarHeight: CGFloat = 0
    var onHover: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if local.y > bounds.height - menuBarHeight { return nil }
        return super.hitTest(point)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = tracking { removeTrackingArea(existing) }
        let live = NSRect(x: 0, y: 0,
                          width: bounds.width,
                          height: max(0, bounds.height - menuBarHeight))
        let area = NSTrackingArea(rect: live,
                                  options: [.mouseEnteredAndExited, .activeAlways],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = FleetModel()
    private var panel: FleetPanel!
    private var container: PassthroughView!
    private var timer: Timer?
    private var observers: [Any] = []
    private let autopilot = AutoPilot()
    private let notifier = Notifier()
    /// Polling is cheap but not free. Three seconds matters while something is
    /// working; when the whole fleet is quiet it is just battery.
    private var pollInterval: TimeInterval = 3

    private var menuBarHeight: CGFloat = 24
    private var notchWidth: CGFloat = 180

    private let collapsedWidth: CGFloat = 210
    private let panelWidth: CGFloat = 470

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        measureScreen()
        buildPanel()

        // Typing to an agent by hand means you are back at the keyboard, so
        // auto-continue starts counting from zero again for that session.
        model.onManualSend = { [weak self] session in self?.autopilot.noteManualSend(session) }
        model.autoCovers = { [weak self] agent in self?.autopilot.covers(agent) ?? false }
        model.autoBlockedManual = { [weak self] agent in
            self?.autopilot.blockedButManual(agent) ?? false
        }
        model.onHeightChange = { [weak self] in self?.layout() }

        // Only the fleet knows whether two agents live in the same app, which
        // decides whether a posted keystroke can be aimed safely.
        // send() returns before it knows what happened, so the result arrives
        // here and replaces the optimistic toast.
        Actions.onResult = { [weak self] outcome in self?.model.flash(outcome) }

        Actions.sharingTargetApp = { [weak self] agent in
            guard let self, let app = agent.ownerApp else { return 1 }
            return self.model.agents.filter { $0.ownerApp == app }.count
        }
        model.onReleaseFocus = { [weak self] in self?.panel.makeFirstResponder(nil) }
        model.onToggleArmed = { [weak self] agent, message in
            guard let self else { return "" }
            let note = self.autopilot.toggleArmed(agent, message: message)
            self.syncScheduled()
            return note
        }
        model.onReschedule = { [weak self] agent, message in
            guard let self else { return "" }
            let note = self.autopilot.reschedule(agent, message: message)
            self.syncScheduled()
            return note
        }

        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.measureScreen()
            self?.layout()
        })

        // Handy for eyeballing the panel without having to hover it.
        if ProcessInfo.processInfo.environment["FLEET_OPEN"] == "1" {
            model.pinned = true
            model.expanded = true
        }

        // macOS caches the Accessibility decision per process, so a grant made
        // while this was running is not visible until relaunch. Recorded at
        // startup so "it is allowed but the warning is still there" can be
        // answered from the log instead of guessed at.
        Actions.trace("START ax_trusted=\(Actions.accessibilityTrusted) pid=\(getpid())")
        notifier.start()

        refresh()
        schedulePoll(3)
    }

    /// Restarts the timer only when the cadence actually changes.
    private func schedulePoll(_ interval: TimeInterval) {
        guard timer == nil || interval != pollInterval else { return }
        pollInterval = interval
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    // MARK: Geometry

    private var targetScreen: NSScreen {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func measureScreen() {
        let screen = targetScreen
        menuBarHeight = max(screen.safeAreaInsets.top, NSStatusBar.system.thickness)

        // On notched displays the two auxiliary areas flank the camera housing;
        // what is left between them is the notch itself.
        let left = screen.auxiliaryTopLeftArea?.width ?? 0
        let right = screen.auxiliaryTopRightArea?.width ?? 0
        notchWidth = left > 0 ? max(120, screen.frame.width - left - right) : 180
    }

    private func buildPanel() {
        panel = FleetPanel(contentRect: .zero,
                           styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered,
                           defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let host = NSHostingView(rootView: NotchRoot(model: model,
                                                     notchHeight: menuBarHeight,
                                                     notchWidth: notchWidth))
        host.translatesAutoresizingMaskIntoConstraints = false

        container = PassthroughView()
        container.menuBarHeight = menuBarHeight
        container.onHover = { [weak self] inside in self?.hover(inside) }
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        panel.contentView = container
        layout()
    }

    /// The window is transparent, so it can jump to its new size instantly while
    /// SwiftUI animates the visible content into place.
    private func layout() {
        let screen = targetScreen
        let expanded = model.expanded || model.pinned

        // Never grow past the bottom of the screen; extra agents scroll instead.
        let chromeHeight = menuBarHeight + 26 + Metrics.headerHeight
            + Metrics.detailsHeight + Metrics.composerHeight
        let roomForRows = screen.visibleFrame.height - chromeHeight - 24
        let maxRows = max(3, Int(roomForRows / Metrics.rowHeight))
        if model.maxRows != maxRows { model.maxRows = maxRows }

        let rows = max(min(model.agents.count, maxRows), 1)
        let details = model.selectedRow == nil ? 0 : Metrics.detailsHeight
        let panelHeight = Metrics.headerHeight + CGFloat(rows) * Metrics.rowHeight
            + details + Metrics.composerHeight
        let height = menuBarHeight + 26 + (expanded ? panelHeight : 0)
        let width = expanded ? panelWidth : collapsedWidth

        let frame = NSRect(x: screen.frame.midX - width / 2,
                           y: screen.frame.maxY - height,
                           width: width,
                           height: height)
        panel.setFrame(frame, display: true)
        container.menuBarHeight = menuBarHeight
        container.updateTrackingAreas()
    }

    /// Mirrors the autopilot's queue into the model for the views to read.
    private func syncScheduled() {
        let armed = autopilot.armedSessions
        if model.armedSessions != armed { model.armedSessions = armed }
        var messages: [String: String] = [:]
        for session in armed {
            if let scheduled = autopilot.scheduled(session) { messages[session] = scheduled.message }
        }
        if model.scheduledMessages != messages { model.scheduledMessages = messages }
    }

    // MARK: Behaviour

    private func hover(_ inside: Bool) {
        if inside {
            guard !model.expanded else { return }
            model.expanded = true
            layout()
        } else {
            collapseIfIdle(pointerInside: false)
        }
    }

    /// True only while the user is actually typing here. `isKeyWindow` on its
    /// own is not enough: a non-activating panel keeps that status after you
    /// click into another app, which is what left the panel open for good.
    private var holdsKeyboard: Bool { panel.isKeyWindow && NSApp.isActive }

    private func collapseIfIdle(pointerInside: Bool) {
        guard FleetModel.shouldCollapse(expanded: model.expanded,
                                        pinned: model.pinned,
                                        pointerInside: pointerInside,
                                        holdsKeyboard: holdsKeyboard) else { return }
        model.expanded = false
        model.select(nil)
        // Let the collapse animation finish before shrinking the window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) { [weak self] in
            guard let self, !self.model.expanded else { return }
            self.layout()
        }
    }

    /// The pointer, in the panel's own coordinate space.
    private var pointerIsOverPanel: Bool {
        panel.frame.contains(NSEvent.mouseLocation)
    }

    /// FLEET_DEMO=1 shows a sample fleet covering every state, so the colours
    /// can be checked without hitting a real limit. Auto-continue is left
    /// alone here: nothing should be sent to agents that do not exist.
    private func demoRefresh() {
        if !model.demo { model.demo = true }
        let found = Discovery.demoAgents()
        let countChanged = found.count != model.agents.count
        model.agents = found
        model.limit = LimitStatus(windowEnd: Date().addingTimeInterval(2 * 3600 + 14 * 60),
                                  origin: .estimated, exhausted: false)
        if !panel.isVisible { panel.orderFront(nil) }
        if countChanged { layout() }
        if model.pinned, !panel.isKeyWindow {
            panel.makeKeyAndOrderFront(nil)
            layout()
        }
    }

    private func refresh() {
        if ProcessInfo.processInfo.environment["FLEET_DEMO"] == "1" {
            demoRefresh()
            return
        }

        DispatchQueue.global(qos: .utility).async {
            let found = Discovery.scan()
            // No Claude session means no window worth scanning for, and the
            // panel is hidden anyway. Otherwise this is cached inside Limits.
            let limit = found.contains { $0.source == .claude } ? Limits.current() : nil
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let countChanged = found.count != self.model.agents.count
                    || found.filter({ $0.state == .busy }).count
                        != self.model.agents.filter({ $0.state == .busy }).count
                self.model.agents = found
                self.model.limit = limit

                // Hand-armed rows fire even with the global switch off, so this
                // is called on every poll rather than only when AUTO is on.
                if let note = self.autopilot.tick(agents: found,
                                                  autoResume: self.model.autoContinue) {
                    self.model.flash(note)
                    self.notifier.announce("Agent Fleet", note)
                }
                self.syncScheduled()
                self.notifier.observe(found)

                // Anything mid-turn or waiting on you deserves a live view;
                // a fleet of idle workers does not.
                let lively = found.contains { $0.state == .busy || $0.state == .asking }
                self.schedulePoll(lively ? 3 : 15)

                // mouseExited is not guaranteed — switching Spaces, a fast
                // exit, or the window resizing under the pointer all lose it.
                // This closes the panel that those cases leave open.
                self.collapseIfIdle(pointerInside: self.pointerIsOverPanel)

                // Cheap, and it can change while the app runs — the point is
                // that the panel stops claiming it will type when it cannot.
                let trusted = Actions.accessibilityTrusted
                if self.model.needsAccessibility == trusted {
                    self.model.needsAccessibility = !trusted
                }

                if found.isEmpty {
                    // Chosen behaviour: invisible unless something is actually running.
                    self.model.pinned = false
                    self.model.expanded = false
                    self.panel.makeFirstResponder(nil)
                    self.panel.orderOut(nil)
                } else {
                    if !self.panel.isVisible { self.panel.orderFront(nil) }
                    if countChanged { self.layout() }
                }

                // Pinning takes the keyboard. Nothing here may *drop* it: this
                // runs every 3s, and clearing the first responder because the
                // panel was not pinned pulled the cursor out of the composer
                // mid-sentence. Focus is released when the panel actually
                // closes, not on a timer.
                if self.model.pinned, !self.panel.isKeyWindow {
                    self.panel.makeKeyAndOrderFront(nil)
                    self.layout()
                }
            }
        }
    }
}

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.run()
