import Foundation

public struct Quota: Sendable, Equatable {
    public enum Window: String, Sendable { case fiveHour = "5h", weekly = "7d" }

    public var window: Window
    /// Fraction used, 0...1.
    public var used: Double
    public var resetsAt: Date?

    /// Orange from `warning`, red from `critical`, as on Claude's usage settings page.
    public static let warning = 0.75, critical = 0.9

    public init(window: Window, used: Double, resetsAt: Date?) {
        self.window = window
        self.used = min(max(used, 0), 1)
        self.resetsAt = resetsAt
    }

    /// A quota whose reset time has passed is back to zero, even if no fresher data arrived.
    public func current(at now: Date) -> Quota {
        guard let resetsAt, resetsAt <= now else { return self }
        return Quota(window: window, used: 0, resetsAt: nil)
    }
}

public struct AgentUsage: Sendable, Equatable {
    public var agent: Agent
    public var fiveHour: Quota
    public var weekly: Quota
    /// When this data was read; old Claude data is shown as stale.
    public var updated: Date

    public init(agent: Agent, fiveHour: Quota, weekly: Quota, updated: Date) {
        self.agent = agent
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.updated = updated
    }

    public var quotas: [Quota] { [fiveHour, weekly] }

    public func current(at now: Date) -> AgentUsage {
        var u = self
        u.fiveHour = fiveHour.current(at: now)
        u.weekly = weekly.current(at: now)
        return u
    }
}

public enum UsageParser {
    /// `GET https://api.anthropic.com/api/oauth/usage`:
    /// `{"five_hour": {"utilization": 42.0, "resets_at": "…"}, "seven_day": {…}, …}`.
    public static func claude(_ data: Data, at now: Date = .now) -> AgentUsage? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let five = quota(.fiveHour, json["five_hour"]),
              let week = quota(.weekly, json["seven_day"]) else { return nil }
        return AgentUsage(agent: .claude, fiveHour: five, weekly: week, updated: now)
    }

    /// What StayVibe's Claude Code plugin saves after each turn (`session.measure`'s `rateLimits`):
    /// `[{"kind": "five_hour", "percentUsed": 23.5, "resetsAt": "…"}, {"kind": "seven_day", …}]`.
    /// Claude Code leaves out a window whose reset has passed, so a missing one is unused.
    public static func claudePushed(_ data: Data, updated: Date) -> AgentUsage? {
        guard let windows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        func quota(_ window: Quota.Window, _ kind: String) -> Quota? {
            guard let w = windows.first(where: { $0["kind"] as? String == kind }),
                  let used = (w["percentUsed"] as? NSNumber)?.doubleValue else { return nil }
            return Quota(window: window, used: used / 100, resetsAt: (w["resetsAt"] as? String).flatMap { Date(iso: $0) })
        }
        let five = quota(.fiveHour, "five_hour"), week = quota(.weekly, "seven_day")
        guard five != nil || week != nil else { return nil }
        return AgentUsage(agent: .claude, fiveHour: five ?? Quota(window: .fiveHour, used: 0, resetsAt: nil),
                          weekly: week ?? Quota(window: .weekly, used: 0, resetsAt: nil), updated: updated)
    }

    private static func quota(_ window: Quota.Window, _ value: Any?) -> Quota? {
        guard let q = value as? [String: Any], let utilization = (q["utilization"] as? NSNumber)?.doubleValue else { return nil }
        return Quota(window: window, used: utilization / 100, resetsAt: (q["resets_at"] as? String).flatMap { Date(iso: $0) })
    }

    /// Codex writes `rate_limits` into its session log (`~/.codex/sessions/…/rollout-*.jsonl`) after
    /// each turn. Paid plans have a 5-hour (300 min) and a weekly (10080 min) window.
    public static func codex(logTail: String, updated: Date) -> AgentUsage? {
        for line in logTail.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let limits = (json["payload"] as? [String: Any])?["rate_limits"] as? [String: Any] else { continue }
            var byWindow: [Int: Quota] = [:]
            for key in ["primary", "secondary"] {
                guard let w = limits[key] as? [String: Any],
                      let minutes = (w["window_minutes"] as? NSNumber)?.intValue,
                      let used = (w["used_percent"] as? NSNumber)?.doubleValue else { continue }
                let reset = (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                byWindow[minutes] = Quota(window: minutes == 300 ? .fiveHour : .weekly, used: used / 100, resetsAt: reset)
            }
            guard let five = byWindow[300], let week = byWindow[10080] else { return nil }
            return AgentUsage(agent: .codex, fiveHour: five, weekly: week, updated: updated)
        }
        return nil
    }
}

public extension [AgentUsage] {
    /// Menu bar arc: the lowest 5-hour quota, i.e. the agent you can still work with.
    var arc: AgentUsage? { self.min { $0.fiveHour.used < $1.fiveHour.used } }
    /// What the arc draws: its 5-hour quota, or, with a single subscription, the weekly one once that is
    /// critical and the 5-hour one isn't in warning.
    var arcQuota: Quota? {
        guard let arc else { return nil }
        let weekly = count == 1 && arc.weekly.used >= Quota.critical && arc.fiveHour.used < Quota.warning
        return weekly ? arc.weekly : arc.fiveHour
    }
    /// The icon turns red only once every weekly quota is used up.
    var weeklyExhausted: Bool { !isEmpty && allSatisfy { $0.weekly.used >= 1 } }
}
