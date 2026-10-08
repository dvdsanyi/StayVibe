import Foundation

public enum Agent: String, Codable, Sendable, CaseIterable {
    case claude, codex

    /// Name of the coding agent, as shown next to a session.
    public var displayName: String { self == .claude ? "Claude Code" : "Codex" }
    /// Name of the subscription whose quota is shown.
    public var planName: String { self == .claude ? "Claude" : "Codex" }
}

/// One hook invocation, forwarded from `StayVibe --hook <agent>` to the running app.
public struct HookEvent: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// `needsYou`: a permission prompt or a question the agent waits on.
        case prompt, toolStart, toolEnd, needsYou, stop, sessionEnd
    }

    public var agent: Agent
    public var kind: Kind
    public var sessionID: String
    public var cwd: String
    public var transcriptPath: String?
    /// Bundle identifier of the GUI app the agent runs inside (VS Code, Claude, ChatGPT, a terminal).
    public var hostBundleID: String?
    /// The `claude` / `codex` process, used to notice sessions that died without a SessionEnd.
    public var agentPID: Int32?
    public var date: Date

    public init(agent: Agent, kind: Kind, sessionID: String, cwd: String, transcriptPath: String? = nil,
                hostBundleID: String? = nil, agentPID: Int32? = nil, date: Date = .now) {
        self.agent = agent
        self.kind = kind
        self.sessionID = sessionID
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.hostBundleID = hostBundleID
        self.agentPID = agentPID
        self.date = date
    }

    /// Parses the JSON a hook receives on stdin. Claude Code and Codex share the same field names;
    /// event names are compared case- and underscore-insensitively (`PreToolUse` == `pre_tool_use`).
    public init?(agent: Agent, payload: Data, date: Date = .now) {
        guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let name = json["hook_event_name"] as? String,
              let session = json["session_id"] as? String else { return nil }
        let kind: Kind
        switch name.lowercased().replacingOccurrences(of: "_", with: "") {
        case "userpromptsubmit": kind = .prompt
        case "pretooluse": kind = json["tool_name"] as? String == "AskUserQuestion" ? .needsYou : .toolStart
        case "posttooluse": kind = .toolEnd
        case "permissionrequest": kind = .needsYou
        case "stop": kind = .stop
        case "sessionend": kind = .sessionEnd
        default: return nil
        }
        self.init(agent: agent, kind: kind, sessionID: session, cwd: json["cwd"] as? String ?? "",
                  transcriptPath: json["transcript_path"] as? String, date: date)
    }
}
