import AppKit
import SwiftUI

// Renders the real panel offscreen with sample agents, so the README image is
// the actual UI rather than a mockup — and contains nobody's real projects.
//
// Not part of the app: `build.sh` only compiles Sources/.

@MainActor
func showcaseAgents() -> [Agent] {
    func row(_ name: String, _ source: Source, _ state: AgentState,
             age: Double, path: String, model: String, message: String,
             question: String? = nil, resets: Date? = nil,
             percent: Double? = nil, detail: String? = nil) -> Agent {
        Agent(id: "showcase-\(name)", source: source, name: name, cwd: path, pid: 4242,
              state: state, age: age, sessionId: "showcase-\(name)",
              detail: detail ?? path, message: message, question: question,
              limitResetsAt: resets, limitUsedPercent: percent,
              limitReadAt: resets != nil ? Date().addingTimeInterval(-900) : nil,
              model: model, executable: nil, isInteractive: true,
              ownerApp: nil, ownerPid: nil, tty: "ttys004")
    }

    return [
        row("api-server", .claude, .asking, age: 142, path: "~/code/api-server",
            model: "opus-5", message: "",
            question: "Two migrations touch the same table — apply them in sequence or squash?"),
        row("billing-worker", .codex, .limited, age: 1_840, path: "~/code/billing-worker",
            model: "gpt-6-astra",
            message: "Retrying after the window resets.",
            resets: Date().addingTimeInterval(2 * 3600 + 14 * 60), percent: 97,
            detail: "97% of 5h window · invoice retries"),
        row("web-app", .claude, .busy, age: 37, path: "~/code/web-app",
            model: "opus-5", message: "Running the test suite — 214 of 300 done."),
        row("docs-site", .claude, .idle, age: 420, path: "~/code/docs-site",
            model: "haiku-4-5", message: "Done. All 41 checks pass."),
        row("~/code/mobile-app", .cursor, .busy, age: 61, path: "~/code/mobile-app",
            model: "Opus 4.6 Thinking", message: "",
            detail: "agent running through this worker"),
        row("~/code/design-system", .cursor, .idle, age: 3_600, path: "~/code/design-system",
            model: "Opus 4.6 Thinking", message: "",
            detail: "connected · no agent running"),
    ].sorted { l, r in
        l.state.urgency != r.state.urgency
            ? l.state.urgency < r.state.urgency
            : l.age > r.age
    }
}

@MainActor
func render() {
    let model = FleetModel()
    model.agents = showcaseAgents()
    model.expanded = true
    model.autoContinue = true
    model.scheduledMessages = ["showcase-billing-worker": "continue"]
    model.armedSessions = ["showcase-billing-worker"]
    model.autoCovers = { $0.source == .codex }

    // The panel on its own, on the black the notch tab sits against.
    let view = VStack(spacing: 0) {
        CollapsedTab(model: model, notchWidth: 200)
        Panel(model: model, preview: true)
    }
    .padding(24)
    .background(Color(red: 0.05, green: 0.05, blue: 0.07))
    .environment(\.colorScheme, .dark)

    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    guard let image = renderer.nsImage,
          let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        print("render failed")
        exit(1)
    }
    let out = URL(fileURLWithPath: "docs/screenshot.png")
    try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try? png.write(to: out)
    print("wrote \(out.path) — \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
}

// ImageRenderer is main-actor bound, so hop there before rendering.
MainActor.assumeIsolated { render() }

// ImageRenderer is main-actor bound, so hop there before rendering.
MainActor.assumeIsolated { render() }
