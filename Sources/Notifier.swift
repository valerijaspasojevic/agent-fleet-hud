import Foundation
import UserNotifications

/// Tells you when something changed, because a HUD only works while you are
/// looking at it — and "an agent needs you" is precisely the case where you are
/// not.
///
/// Only transitions are announced, never states: a blocked agent stays blocked
/// for hours, and repeating that every three seconds would be unusable.
final class Notifier {
    private var previous: [String: AgentState] = [:]
    private var authorized = false

    func start() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
                DispatchQueue.main.async { self?.authorized = granted }
            }
    }

    /// Compares this poll against the last one and announces what changed.
    func observe(_ agents: [Agent]) {
        var current: [String: AgentState] = [:]
        for agent in agents {
            current[agent.id] = agent.state
            let before = previous[agent.id]

            // A first sighting is not a change — otherwise every launch would
            // announce the whole fleet.
            guard let before, before != agent.state else { continue }

            switch agent.state {
            case .asking:
                post(title: "\(agent.name) needs you",
                     body: agent.question ?? "It is waiting on an answer.")
            case .limited:
                let when = agent.limitResetsAt.map { " · back at \(clockTime($0))" } ?? ""
                post(title: "\(agent.name) hit its limit",
                     body: "\(agent.source.label)\(when)")
            case .idle where before == .limited, .busy where before == .limited,
                 .live where before == .limited:
                post(title: "\(agent.name) can work again",
                     body: "Its usage window reset.")
            default:
                break
            }
        }
        previous = current
    }

    /// For things that are not a state change, like a scheduled message firing.
    func announce(_ title: String, _ body: String) {
        post(title: title, body: body)
    }

    private func post(title: String, body: String) {
        guard authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
