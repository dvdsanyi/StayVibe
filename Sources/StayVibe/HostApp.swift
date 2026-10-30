import AppKit
import StayVibeCore

/// The GUI app an agent session runs inside, identified by bundle ID.
enum HostApp {
    static let terminals: Set = ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
                                 "net.kovidgoyal.kitty", "com.github.wez.wezterm", "io.alacritty", "co.zeit.hyper"]

    /// The agents' own apps: their name already says which agent runs ("Claude", not "Claude Code Claude").
    static let agentApps: Set = ["com.anthropic.claudefordesktop", "com.openai.codex"]

    static func name(_ id: String?) -> String? {
        guard let id else { return nil }
        switch id {
        case "com.microsoft.VSCode": return "VSCode"
        case "com.anthropic.claudefordesktop": return "Claude"
        case "com.openai.codex": return "ChatGPT"
        case _ where terminals.contains(id): return tr("Terminal")
        default:
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
        }
    }

    /// Codex runs new hooks only after the user approves them in Codex itself: a hook icon next to
    /// its message box (ChatGPT app and VS Code alike). StayVibe opens Codex and says where to click.
    enum CodexTrust {
        /// The ChatGPT app if installed, otherwise VS Code with the Codex extension.
        static var host: String {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") != nil ? "com.openai.codex" : "com.microsoft.VSCode"
        }
        static var hint: String {
            host == "com.openai.codex" ? tr("In ChatGPT, click the hook icon next to the message box, then Trust all")
                : tr("In VS Code's Codex panel, click the hook icon next to the message box, then Trust all")
        }
        static var buttonTitle: String { tr("Open %@", name(host) ?? "Codex") }
        @MainActor static func open() { jump(to: host, cwd: "") }
    }

    /// Brings the session's window forward: the project window in VS Code-like editors when one is
    /// open, otherwise just the app (never a new window).
    @MainActor static func jump(to id: String?, cwd: String) {
        guard let id, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        if let folder = EditorWindows.folder(containing: cwd, editor: id) {
            NSWorkspace.shared.open([folder], withApplicationAt: app, configuration: config)
        } else {
            NSWorkspace.shared.openApplication(at: app, configuration: config)
        }
    }
}
