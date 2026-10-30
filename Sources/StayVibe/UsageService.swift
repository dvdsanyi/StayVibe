import Foundation
import StayVibeCore

/// Reads plan quotas. Claude: what StayVibe's Claude Code plugin saves after each turn; when that is stale,
/// the endpoint behind Claude Code's `/usage`, using Claude Code's own login (read-only; StayVibe never
/// refreshes or writes the token). Codex: its app-server's live account limits, then local logs.
enum UsageService {
    @MainActor private static var pushed: AgentUsage?

    /// The numbers Claude Code read from its last API response, as of when the plugin saved them.
    @MainActor static func claudePushed() -> AgentUsage? {
        let file = HookConfig.claudeUsageFile
        guard let updated = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date else { return nil }
        if pushed?.updated == updated { return pushed }
        guard let data = try? Data(contentsOf: file) else { return nil }
        pushed = UsageParser.claudePushed(data, updated: updated)
        return pushed
    }

    /// Fallback for stale pushed numbers: live ones from the usage endpoint, else the copy Claude Code caches
    /// in `~/.claude.json` (only as fresh as its last usage fetch). The login in the keychain is only
    /// refreshed when the `claude` CLI runs, and the endpoint's rate limit is shared with Claude Code.
    static func claude() async -> AgentUsage? {
        await claudeLive() ?? claudeCached()
    }

    /// The usage endpoint is rate limited: at most one call per 5-minute refresh (with slack, so a timer
    /// tick that fires a moment early isn't skipped), and back off on 429.
    nonisolated(unsafe) private static var nextLiveFetch = Date.distantPast

    /// Waits for the network instead of failing: right after login or wake it isn't up yet, and a
    /// failed call would leave only the cached numbers until the next try 5 minutes later.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = true
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config)
    }()

    private static func claudeLive() async -> AgentUsage? {
        guard Date.now >= nextLiveFetch, let token = claudeToken() else { return nil }
        nextLiveFetch = .now + 290
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 15
        guard let (data, response) = try? await session.data(for: request) else {
            log.notice("claude usage: request failed")
            return nil
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            if status == 429 {
                let wait = ((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "retry-after")).flatMap(TimeInterval.init) ?? 600
                nextLiveFetch = .now + wait
            }
            log.notice("claude usage: HTTP \(status, privacy: .public)")
            return nil
        }
        return UsageParser.claude(data)
    }

    private static func claudeCached() -> AgentUsage? {
        let file = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude.json")
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cache = json["cachedUsageUtilization"] as? [String: Any],
              let fetched = (cache["fetchedAtMs"] as? NSNumber)?.doubleValue,
              let utilization = cache["utilization"],
              let body = try? JSONSerialization.data(withJSONObject: utilization) else { return nil }
        return UsageParser.claude(body, at: Date(timeIntervalSince1970: fetched / 1000))
    }

    /// Claude Code keeps its login in the keychain item "Claude Code-credentials" and reads and writes it
    /// with Apple's `security` tool, which is therefore always on the item's access list. Reading it the
    /// same way never shows a keychain prompt, before or after updates.
    private static func claudeToken() -> String? {
        let security = Process()
        security.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        security.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let output = Pipe()
        security.standardOutput = output
        security.standardError = FileHandle.nullDevice
        guard (try? security.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        security.waitUntilExit()
        guard security.terminationStatus == 0 else {
            log.notice("claude usage: no Claude Code login in the keychain")
            return nil
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        if let expires = (oauth["expiresAt"] as? NSNumber)?.doubleValue, expires / 1000 < Date.now.timeIntervalSince1970 {
            log.notice("claude usage: login expired, waiting for Claude Code to refresh it")
            return nil
        }
        return token
    }

    @MainActor static func codex() async -> AgentUsage? {
        if let live = await CodexUsageClient.fetch() { return live }
        let configured = ProcessInfo.processInfo.environment["CODEX_HOME"]
        let home = configured.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex")
        return await Task.detached(priority: .utility) {
            CodexUsageLogs.latest(in: home.appending(path: "sessions"))
        }.value
    }
}
