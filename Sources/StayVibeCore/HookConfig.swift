import Foundation

/// Reads and writes StayVibe's entries in `~/.claude/settings.json` and `~/.codex/hooks.json`.
/// Both files share the same `{"hooks": {Event: [{"hooks": [{"type", "command"}]}]}}` shape.
/// For Claude it also installs StayVibe's Claude Code plugin, which reports the plan's usage.
public struct HookConfig: Sendable {
    public static let events = ["UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop", "SessionEnd"]
    /// Hooks left behind by the Claude Notifier VS Code extension, which StayVibe replaces.
    static let replacedMarker = "claude-notifier"

    /// StayVibe's Claude Code plugin: after each turn Claude Code hands it the usage windows it read from the
    /// API response, and it saves them to `claudeUsageFile`. Claude Code loads it from `CLAUDE_CODE_PLUGIN_DIRS`;
    /// it lives outside the app bundle so a deleted StayVibe leaves no missing plugin folder behind.
    static let plugin = [
        ".claude-plugin/plugin.json": #"{"name": "stayvibe", "version": "1.0.0", "description": "Saves Claude plan usage for the StayVibe menu bar app", "author": {"name": "StayVibe"}}"#,
        "hooks/hooks.json": #"{"modules": ["./register.ts"]}"#,
        "hooks/register.ts": """
        import type { Register } from 'claude-code'

        export const register: Register = on => {
          on('session.measure', async ($, e, next) => {
            if (e.rateLimits.length > 0) await $.fs.write(`${$.plugin.root}/../claude-usage.json`, JSON.stringify(e.rateLimits))
            return next(e)
          })
        }
        """,
    ]
    /// Next to the plugin folder rather than in it: Claude Code reloads a plugin when its folder changes.
    public static let claudeUsageFile = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/StayVibe/claude-usage.json")
    static let pluginDirsKey = "CLAUDE_CODE_PLUGIN_DIRS"
    /// Plugin hooks modules are still rolling out in Claude Code; this turns them on.
    static let functionHooksKey = "CLAUDE_CODE_ENABLE_FUNCTION_HOOKS"

    public let agent: Agent
    public let file: URL
    /// Absolute path of the StayVibe executable the hooks call.
    public let executable: String
    let pluginDir: URL

    public init(agent: Agent, home: URL = FileManager.default.homeDirectoryForCurrentUser, executable: String) {
        self.agent = agent
        self.file = agent == .claude
            ? home.appending(path: ".claude/settings.json")
            : home.appending(path: ".codex/hooks.json")
        self.executable = executable
        self.pluginDir = home.appending(path: "Library/Application Support/StayVibe/ClaudePlugin")
    }

    /// Silent no-op once StayVibe is deleted, so leftover hooks never show errors in the agent.
    public var command: String { "\"\(executable)\" --hook \(agent.rawValue) 2>/dev/null || true" }

    /// Codex only reads hooks when it is installed; don't create `~/.codex` for people without it.
    public var agentInstalled: Bool {
        FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path)
    }

    public var isInstalled: Bool {
        guard let root = try? read(), let hooks = root["hooks"] as? [String: Any],
              Self.events.allSatisfy({ commands(in: hooks[$0]).contains(command) }) else { return false }
        guard agent == .claude else { return true }
        let env = root["env"] as? [String: Any] ?? [:]
        return env[Self.functionHooksKey] as? String == "1" && pluginDirs(in: env).contains(pluginDir.path)
            && Self.plugin.allSatisfy { (try? String(contentsOf: pluginDir.appending(path: $0.key), encoding: .utf8)) == $0.value }
    }

    /// Adds StayVibe's hooks (and for Claude its plugin), drops stale StayVibe and Claude Notifier entries,
    /// keeps everything else.
    public func install() throws {
        var root = try read() ?? [:]
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in Self.events {
            hooks[event] = (hooks[event] as? [[String: Any]] ?? []).compactMap(pruned)
                + [["hooks": [["type": "command", "command": command, "timeout": 5]]]]
        }
        root["hooks"] = hooks
        if agent == .claude {
            for (path, text) in Self.plugin {
                let url = pluginDir.appending(path: path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: url, options: .atomic)
            }
            var env = root["env"] as? [String: Any] ?? [:]
            env[Self.functionHooksKey] = "1"
            env[Self.pluginDirsKey] = (pluginDirs(in: env).filter { $0 != pluginDir.path } + [pluginDir.path]).joined(separator: ":")
            root["env"] = env
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: file, options: .atomic)
    }

    /// Removes StayVibe / Claude Notifier commands from a matcher group; drops the group if it empties.
    private func pruned(_ group: [String: Any]) -> [String: Any]? {
        guard let entries = group["hooks"] as? [[String: Any]] else { return group }
        let kept = entries.filter { entry in
            let cmd = entry["command"] as? String ?? ""
            return !cmd.contains(Self.replacedMarker) && !cmd.contains("--hook \(agent.rawValue)")
        }
        guard !kept.isEmpty else { return nil }
        var g = group
        g["hooks"] = kept
        return g
    }

    private func pluginDirs(in env: [String: Any]) -> [String] {
        (env[Self.pluginDirsKey] as? String ?? "").split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func commands(in value: Any?) -> [String] {
        (value as? [[String: Any]] ?? []).flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
    }

    private func read() throws -> [String: Any]? {
        guard let data = try? Data(contentsOf: file), !data.isEmpty else { return nil }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
