import Foundation

/// Finds the cloud-agent id for a workspace, so `Open` can focus that exact
/// agent instead of just raising Cursor's window.
///
/// Cursor builds the link itself as
/// `cursor://anysphere.cursor-deeplink/background-agent?bcId=<id>`, so the
/// mechanism is theirs and reliable. The hard part is learning the id.
///
/// It comes from two of Cursor's own stores: `workspaceMetadata.entries` maps
/// a folder to a workspace hash, and `cursor/glass.tabs.v2/<hash>/…` records
/// per-agent tab state under keys that contain the agent id.
///
/// **This often finds nothing, and that is expected.** Only a minority of
/// workspaces have an id recorded at all — the current agent list lives on
/// Cursor's servers, and every local store that once held it
/// (`cloudAgentRepository.agents`, `glass.cloudAgentProjects.v1`,
/// `glass.localAgentProjects.v1`) stopped being written. When there is no id
/// the caller raises Cursor's existing window, which is the honest fallback.
enum CursorAgents {
    private static let db = Discovery.home
        .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    private static let refreshInterval: TimeInterval = 120
    private static var cache: [String: String?] = [:]
    private static var cachedAt = Date.distantPast

    /// The `bc-…` agent id for a workspace path, when Cursor recorded one.
    static func agentId(forWorkspace path: String) -> String? {
        if Date().timeIntervalSince(cachedAt) > refreshInterval {
            cache = [:]
            cachedAt = Date()
        }
        if let known = cache[path] { return known }
        let found = lookup(path)
        cache[path] = found
        return found
    }

    /// `cursor://…/background-agent?bcId=<id>`, exactly as Cursor writes it.
    static func deeplink(forWorkspace path: String) -> String? {
        guard let id = agentId(forWorkspace: path) else { return nil }
        let escaped = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id
        return "cursor://anysphere.cursor-deeplink/background-agent?bcId=\(escaped)"
    }

    private static func lookup(_ path: String) -> String? {
        guard FileManager.default.fileExists(atPath: db.path) else { return nil }
        guard let hash = workspaceHash(for: path) else { return nil }
        // A key-prefix query, so this touches a handful of rows rather than
        // scanning a database that reaches tens of gigabytes.
        let sql = "select value from ItemTable where key like 'cursor/glass.tabs.v2/\(hash)/%';"
        guard let out = query(sql) else { return nil }
        return firstAgentId(in: out)
    }

    private static func workspaceHash(for path: String) -> String? {
        guard let out = query("select value from ItemTable where key='workspaceMetadata.entries';"),
              let data = out.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        for entry in entries {
            let blob = (try? JSONSerialization.data(withJSONObject: entry))
                .map { String(decoding: $0, as: UTF8.self) } ?? ""
            guard blob.contains(path) else { continue }
            if let id = entry["id"] as? String { return id }
        }
        return nil
    }

    /// `bc-` followed by a uuid.
    static func firstAgentId(in text: String) -> String? {
        guard let range = text.range(of: "bc-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}",
                                     options: .regularExpression) else { return nil }
        return String(text[range])
    }

    /// Read-only, and never on the main thread — the caller already runs this
    /// on a background queue.
    private static func query(_ sql: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        proc.arguments = ["-readonly", db.path, sql]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        return text.isEmpty ? nil : text
    }
}
