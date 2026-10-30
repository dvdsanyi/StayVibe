import Foundation

public struct Session: Identifiable, Sendable, Equatable {
    public let id: String
    public let sessionID: String
    public let agent: Agent
    public var cwd: String
    public var hostBundleID: String?
    public var agentPID: Int32?
    public var transcriptPath: String?
    /// The agent stopped for the user: a permission prompt or a question.
    public var needsYou = false
    public var started: Date
    public var lastEvent: Date
    public var toolRunning = false
    /// The conversation's own title, used when the folder name says nothing (see `namedByTitle`).
    public var title: String?

    /// Folders whose name says nothing: the home folder (a VS Code window with no folder open), the
    /// per-chat folders Codex creates (`~/Documents/Codex/<date>/<slug>`) and the Claude app's scratch
    /// workspaces for sessions without a folder (`…/Claude/scratch-workspaces/…/scratch-<date>-<id>`).
    public var namedByTitle: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return cwd.isEmpty || cwd == home || cwd.hasPrefix(home + "/Documents/Codex/")
            || cwd.hasPrefix(home + "/Library/Application Support/Claude/scratch-workspaces/")
    }

    public var project: String {
        namedByTitle ? title ?? agent.displayName : URL(fileURLWithPath: cwd).lastPathComponent
    }
}

/// One line in the panel: all sessions that live in the same window (project + agent + host app).
public struct SessionRow: Identifiable, Sendable, Equatable {
    public let id: String
    public let agent: Agent
    public let project: String
    public let cwd: String
    public let hostBundleID: String?
    public let needsYou: Bool
    public let count: Int
}

/// Pure state machine for agent sessions; the app feeds it hook events and periodic ticks.
public struct SessionStore: Sendable {
    /// What a hook event means for the user.
    public enum Outcome: Sendable, Equatable {
        case none
        case finished(Session)
        case needsAttention(Session)
    }

    public static let idleTimeout: TimeInterval = 10 * 60
    public static let toolTimeout: TimeInterval = 60 * 60

    public private(set) var sessions: [String: Session] = [:]

    public init() {}

    /// A session is working (prompt sent, turn not finished) unless it waits for the user.
    /// Drives both the menu bar dot and keeping the Mac awake.
    public var hasWorking: Bool { sessions.values.contains { !$0.needsYou } }

    @discardableResult
    public mutating func apply(_ e: HookEvent) -> Outcome {
        let id = "\(e.agent.rawValue):\(e.sessionID)"
        if e.kind == .stop || e.kind == .sessionEnd {
            guard let ended = sessions.removeValue(forKey: id) else { return .none }
            return e.kind == .stop ? .finished(ended) : .none
        }
        var s = sessions[id] ?? Session(id: id, sessionID: e.sessionID, agent: e.agent, cwd: e.cwd, started: e.date, lastEvent: e.date)
        if !e.cwd.isEmpty { s.cwd = e.cwd }
        s.hostBundleID = e.hostBundleID ?? s.hostBundleID
        s.agentPID = e.agentPID ?? s.agentPID
        s.transcriptPath = e.transcriptPath ?? s.transcriptPath
        s.lastEvent = e.date
        var outcome = Outcome.none
        switch e.kind {
        case .prompt: s.started = e.date; s.needsYou = false; s.toolRunning = false
        case .toolStart: s.needsYou = false; s.toolRunning = true
        case .toolEnd: s.needsYou = false; s.toolRunning = false
        case .needsYou: s.needsYou = true
        case .stop, .sessionEnd: break
        }
        if s.needsYou, sessions[id]?.needsYou != true { outcome = .needsAttention(s) }
        sessions[id] = s
        return outcome
    }

    public mutating func remove(_ id: String) { sessions[id] = nil }

    /// The user approved a command, which runs without any hook until it ends: the session works again.
    public mutating func resume(_ id: String, at date: Date) {
        sessions[id]?.needsYou = false
        sessions[id]?.toolRunning = true
        sessions[id]?.lastEvent = date
    }

    public mutating func setTitle(_ title: String, for id: String) { sessions[id]?.title = title }

    /// Drops sessions whose agent process is gone, and working sessions that went silent.
    /// Sessions waiting for the user never time out: the user may simply be away.
    public mutating func expire(now: Date, isAlive: (Int32) -> Bool) {
        sessions = sessions.filter { _, s in
            if let pid = s.agentPID, !isAlive(pid) { return false }
            guard !s.needsYou else { return true }
            return now.timeIntervalSince(s.lastEvent) < (s.toolRunning ? Self.toolTimeout : Self.idleTimeout)
        }
    }

    /// Panel rows: one per window (sessions named by title stay separate), those needing the user first,
    /// then newest first.
    public var rows: [SessionRow] {
        let groups = Dictionary(grouping: sessions.values) { (s: Session) -> String in
            s.namedByTitle ? s.id : "\(s.agent.rawValue)|\(s.cwd)|\(s.hostBundleID ?? "")"
        }
        let rows: [(started: Date, row: SessionRow)] = groups.map { key, group in
            let newest = group.max { $0.started < $1.started }!
            let row = SessionRow(id: key, agent: newest.agent, project: newest.project, cwd: newest.cwd,
                                 hostBundleID: newest.hostBundleID,
                                 needsYou: group.contains(where: \.needsYou), count: group.count)
            return (newest.started, row)
        }
        return rows.sorted { a, b in
            a.row.needsYou != b.row.needsYou ? a.row.needsYou : a.started > b.started
        }.map(\.row)
    }
}
