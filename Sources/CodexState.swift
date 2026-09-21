import Foundation

/// Codex's usage window, as Codex itself last saw it.
///
/// Codex records the server's own numbers into the rollout it is writing, under
/// `payload.rate_limits`: a percentage, the window length, and the exact reset
/// timestamp. That is a real reading from the API, not a guess — unlike the
/// Claude-side estimate, which has to be derived when no rejection has happened.
struct CodexUsage: Equatable {
    let usedPercent: Double
    let windowMinutes: Int
    let resetsAt: Date
    /// When Codex recorded this. The percentage only moves when Codex writes,
    /// so a reading can be hours old and showing it as current would mislead.
    let recordedAt: Date

    /// The threshold is a judgement call, so the exact percentage is always
    /// shown alongside it rather than being rounded into a claim. Codex does
    /// not write a "rejected" flag the way Claude Code does, so there is no
    /// hard signal to key on.
    static let blockedThreshold = 95.0

    var isBlocked: Bool { usedPercent >= Self.blockedThreshold }
    var isLive: Bool { resetsAt > Date() }
    var windowLabel: String {
        windowMinutes % 60 == 0 ? "\(windowMinutes / 60)h window" : "\(windowMinutes)m window"
    }
}

struct CodexThread {
    let id: String
    let name: String
    let updated: Date
}

/// Everything read out of ~/.codex, cached together because it all comes from
/// the same directory walk.
enum CodexState {
    struct Snapshot {
        var threads: [CodexThread] = []
        var usage: CodexUsage?
    }

    private static let root = Discovery.home.appendingPathComponent(".codex")
    private static let refreshInterval: TimeInterval = 30
    private static var cached = Snapshot()
    private static var cachedAt = Date.distantPast

    static func snapshot() -> Snapshot {
        if Date().timeIntervalSince(cachedAt) < refreshInterval { return cached }
        cached = compute()
        cachedAt = Date()
        return cached
    }

    private static func compute() -> Snapshot {
        var snapshot = Snapshot()
        let rollouts = recentRollouts(limit: 6)
        let names = threadNames()

        snapshot.threads = rollouts.map { rollout in
            CodexThread(id: rollout.threadId,
                        name: names[rollout.threadId] ?? "untitled",
                        updated: rollout.modified)
        }

        // The newest reading wins, whichever thread wrote it.
        var newest: (stamp: TimeInterval, usage: CodexUsage)?
        for rollout in rollouts {
            guard let found = usage(in: rollout.url) else { continue }
            if newest.map({ found.stamp > $0.stamp }) ?? true { newest = found }
        }
        if let usage = newest?.usage, usage.isLive { snapshot.usage = usage }
        return snapshot
    }

    // MARK: Rollouts

    private struct Rollout {
        let url: URL
        let threadId: String
        let modified: Date
    }

    /// Rollout files are named
    /// `rollout-<iso>-<thread-uuid>[_<turn-uuid>].jsonl`, so the thread id and
    /// the last-activity time come from the directory listing alone — no need
    /// to open anything. Only filenames and dates are read here, which matters
    /// because these files reach hundreds of megabytes.
    private static func recentRollouts(limit: Int) -> [Rollout] {
        let sessions = root.appendingPathComponent("sessions")
        let fm = FileManager.default
        guard let walk = fm.enumerator(at: sessions,
                                       includingPropertiesForKeys: [.contentModificationDateKey],
                                       options: [.skipsHiddenFiles]) else { return [] }

        var found: [Rollout] = []
        for case let url as URL in walk {
            let name = url.lastPathComponent
            guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") else { continue }
            guard let id = threadId(fromRollout: name) else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            found.append(Rollout(url: url, threadId: id, modified: modified))
        }
        return found.sorted { $0.modified > $1.modified }.prefix(limit).map { $0 }
    }

    /// The thread uuid is the last 36 characters before any `_<turn-uuid>`.
    static func threadId(fromRollout filename: String) -> String? {
        var stem = (filename as NSString).deletingPathExtension
        if let underscore = stem.firstIndex(of: "_") { stem = String(stem[..<underscore]) }
        guard stem.count >= 36 else { return nil }
        let id = String(stem.suffix(36))
        // 8-4-4-4-12
        let dashes = [8, 13, 18, 23]
        for offset in dashes {
            guard id[id.index(id.startIndex, offsetBy: offset)] == "-" else { return nil }
        }
        return id
    }

    /// Reads the tail for the newest populated `rate_limits`. The record is
    /// appended every turn, so it sits at the end.
    private static func usage(in url: URL) -> (stamp: TimeInterval, usage: CodexUsage)? {
        guard let text = Discovery.tail(url, bytes: 512 * 1024) else { return nil }
        var newest: (TimeInterval, CodexUsage)?

        for line in text.split(separator: "\n") {
            guard line.contains("\"rate_limits\"") else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any],
                  let limits = payload["rate_limits"] as? [String: Any],
                  let primary = limits["primary"] as? [String: Any],
                  let used = primary["used_percent"] as? NSNumber,
                  let resets = primary["resets_at"] as? NSNumber else { continue }

            let window = (primary["window_minutes"] as? NSNumber)?.intValue ?? 0
            let stamp = Limits.firstTimestamp(in: line) ?? 0
            let found = CodexUsage(usedPercent: used.doubleValue,
                                   windowMinutes: window,
                                   resetsAt: Date(timeIntervalSince1970: resets.doubleValue),
                                   recordedAt: Date(timeIntervalSince1970: stamp))
            if newest.map({ stamp > $0.0 }) ?? true { newest = (stamp, found) }
        }
        return newest
    }

    // MARK: Names

    /// `session_index.jsonl` still holds readable thread titles, even though it
    /// lags behind the rollouts, so it is used for names only — never recency.
    private static func threadNames() -> [String: String] {
        let url = root.appendingPathComponent("session_index.jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var names: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = obj["id"] as? String else { continue }
            if let name = obj["thread_name"] as? String, !name.isEmpty { names[id] = name }
        }
        return names
    }
}
