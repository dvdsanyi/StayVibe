import Foundation

/// Reads the end of an agent's session log. Hooks don't fire when the user presses Esc,
/// but both agents record the interruption there.
public enum Transcript {
    public static func tail(of path: String, bytes: UInt64 = 64 * 1024) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > bytes ? size - bytes : 0)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// When the most recent turn in the log was cancelled by the user, the time it happened.
    /// Claude Code logs a user message `[Request interrupted by user…]`; Codex logs `turn_aborted`.
    public static func interruption(_ agent: Agent, tail: String) -> Date? {
        for line in tail.split(separator: "\n").reversed() {
            let isInterrupt = agent == .claude
                ? line.contains("[Request interrupted by user")
                : line.contains("\"type\":\"turn_aborted\"")
            if isInterrupt { return timestamp(line) ?? .distantPast }
            let isActivity = agent == .claude
                ? line.contains("\"type\":\"assistant\"") || line.contains("\"type\":\"user\"")
                : line.contains("\"type\":\"task_started\"")
            if isActivity { return nil }
        }
        return nil
    }

    /// Claude Code logs `custom-title` (renamed by the user) and `ai-title` records every few turns.
    public static func claudeTitle(tail: String) -> String? {
        var aiTitle: String?
        for line in tail.split(separator: "\n").reversed() where line.contains("-title\"") {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if let custom = json["customTitle"] as? String { return custom }
            aiTitle = aiTitle ?? json["aiTitle"] as? String
        }
        return aiTitle
    }

    /// Codex keeps one `{"id", "thread_name"}` line per conversation in `~/.codex/session_index.jsonl`.
    public static func codexTitle(index: String, sessionID: String) -> String? {
        for line in index.split(separator: "\n").reversed() where line.contains(sessionID) {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  json["id"] as? String == sessionID else { continue }
            return json["thread_name"] as? String
        }
        return nil
    }

    private static func timestamp(_ line: Substring) -> Date? {
        (line.firstMatch(of: /"timestamp":"([^"]+)"/)?.1).flatMap { Date(iso: String($0)) }
    }
}

extension Date {
    /// ISO 8601 with any number of fractional-second digits (`…05:00:00.123456+00:00`).
    init?(iso s: String) {
        guard let d = ISO8601DateFormatter().date(from: s.replacing(/\.\d+/, with: "")) else { return nil }
        self = d
    }
}
