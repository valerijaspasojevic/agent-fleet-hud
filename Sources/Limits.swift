import Foundation

/// When the current usage window rolls over.
///
/// Two sources, in order of trust:
///
/// - `.reported` — Claude Code writes the real `quotaLimits.resetsAt` into the
///   transcript whenever the API rejects or warns on a request. Authoritative,
///   but it only exists once you have actually bumped into the limit.
/// - `.estimated` — derived from message timestamps. A window is anchored to
///   its first request floored to ten minutes and runs five hours; the next
///   request after it expires opens a fresh one. Checked against a recorded
///   `resetsAt` and it lands on the same minute.
struct LimitStatus: Equatable {
    enum Origin: Equatable { case reported, estimated }

    let windowEnd: Date
    let origin: Origin
    /// The limit was actually hit in this window, so nothing will run until reset.
    let exhausted: Bool

    var remaining: TimeInterval { max(0, windowEnd.timeIntervalSinceNow) }
    var isLive: Bool { windowEnd > Date() }
}

enum Limits {
    static let windowLength: TimeInterval = 5 * 3600
    /// Windows are anchored to a ten-minute boundary.
    static let anchorStep: TimeInterval = 600

    private static let projects = Discovery.home.appendingPathComponent(".claude/projects")
    /// A full scan reads every transcript touched in the last six hours, which
    /// costs about a second. The answer only moves when a window expires or a
    /// new one opens, so it is cached hard.
    private static let refreshInterval: TimeInterval = 60
    private static var cached: LimitStatus?
    private static var cachedAt = Date.distantPast

    static func current() -> LimitStatus? {
        // `cached?.isLive != false` keeps a cached *absence* of a window too —
        // reading it as a miss meant rescanning on every single poll whenever
        // no window was open, which is the common idle case.
        if Date().timeIntervalSince(cachedAt) < refreshInterval, cached?.isLive != false {
            return cached
        }
        cached = compute()
        cachedAt = Date()
        return cached
    }

    private static func compute() -> LimitStatus? {
        // A window is anchored by a message inside it, so nothing older than
        // five hours can describe the window we are in now.
        let horizon = Date().addingTimeInterval(-windowLength - 3600)
        var stamps: [TimeInterval] = []
        var reported: (end: Date, rejected: Bool)?

        for file in transcripts(modifiedAfter: horizon) {
            guard let text = stampSource(file) else { continue }
            for line in text.split(separator: "\n") {
                if let t = firstTimestamp(in: line) { stamps.append(t) }
                guard line.contains("\"resetsAt\"") else { continue }
                if let quota = quotaLimits(in: line),
                   let secs = quota["resetsAt"] as? NSNumber {
                    let end = Date(timeIntervalSince1970: secs.doubleValue)
                    if end > Date(), reported.map({ end > $0.end }) ?? true {
                        let status = (quota["status"] as? String ?? "").lowercased()
                        reported = (end, status == "rejected")
                    }
                }
            }
        }

        if let hit = reported {
            return LimitStatus(windowEnd: hit.end, origin: .reported, exhausted: hit.rejected)
        }

        guard let end = estimatedWindowEnd(stamps: stamps) else { return nil }
        return LimitStatus(windowEnd: end, origin: .estimated, exhausted: false)
    }

    /// Replays the timestamps into consecutive five-hour windows and returns the
    /// end of the last one, if it is still open.
    static func estimatedWindowEnd(stamps: [TimeInterval]) -> Date? {
        var end: TimeInterval = 0
        for stamp in stamps.sorted() where stamp >= end {
            end = (stamp / anchorStep).rounded(.down) * anchorStep + windowLength
        }
        let now = Date().timeIntervalSince1970
        return end > now ? Date(timeIntervalSince1970: end) : nil
    }

    /// The window is anchored by the *earliest* qualifying message, so reading
    /// only a tail biases the estimate late — a 512K tail of a 670K session
    /// file silently drops the message that opened the window. Recent
    /// transcripts are small, so read them whole and only fall back to a
    /// generous tail for a runaway file.
    private static let wholeFileCap: UInt64 = 12 * 1024 * 1024

    private static func stampSource(_ file: URL) -> String? {
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if UInt64(size) <= wholeFileCap, let data = try? Data(contentsOf: file, options: .mappedIfSafe) {
            return String(decoding: data, as: UTF8.self)
        }
        return Discovery.tail(file, bytes: 8 * 1024 * 1024)
    }

    private static func transcripts(modifiedAfter cutoff: Date) -> [URL] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil) else {
            return []
        }
        var out: [URL] = []
        for dir in dirs {
            guard let files = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                if modified > cutoff { out.append(file) }
            }
        }
        return out
    }

    private static func quotaLimits(in line: Substring) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["quotaLimits"] as? [String: Any]
    }

    // MARK: Timestamps

    /// Pulls the epoch seconds out of `"timestamp":"2026-09-21T13:56:24.629Z"`.
    /// Hand-rolled because a DateFormatter across thousands of lines is the
    /// most expensive thing this app would otherwise do.
    static func firstTimestamp(in line: Substring) -> TimeInterval? {
        guard let key = line.range(of: "\"timestamp\":\"") else { return nil }
        let digits = line[key.upperBound...].prefix(19)
        guard digits.count == 19 else { return nil }
        let n = digits.compactMap { $0.isNumber ? Int(String($0)) : nil }
        guard n.count == 14 else { return nil }
        let year = n[0] * 1000 + n[1] * 100 + n[2] * 10 + n[3]
        let month = n[4] * 10 + n[5]
        let day = n[6] * 10 + n[7]
        let hour = n[8] * 10 + n[9]
        let minute = n[10] * 10 + n[11]
        let second = n[12] * 10 + n[13]
        guard month >= 1, month <= 12, day >= 1, day <= 31 else { return nil }
        return TimeInterval(daysFromEpoch(year: year, month: month, day: day) * 86400
            + hour * 3600 + minute * 60 + second)
    }

    /// Howard Hinnant's days_from_civil. Transcript stamps are UTC.
    static func daysFromEpoch(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }
}

// MARK: - Formatting

func shortAge(_ seconds: Double) -> String {
    if seconds < 60 { return "\(Int(seconds))s" }
    if seconds < 3600 { return "\(Int(seconds / 60))m" }
    if seconds < 86400 { return "\(Int(seconds / 3600))h" }
    return "\(Int(seconds / 86400))d"
}

func shortDuration(_ seconds: TimeInterval) -> String {
    let total = Int(seconds.rounded())
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
    if minutes > 0 { return "\(minutes)m" }
    return "<1m"
}

func clockTime(_ date: Date) -> String {
    let fmt = DateFormatter()
    fmt.locale = .current
    fmt.setLocalizedDateFormatFromTemplate("jmm")
    return fmt.string(from: date)
}
