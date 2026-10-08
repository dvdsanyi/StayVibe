import Foundation
import Testing
@testable import StayVibeCore

private func payload(_ name: String, session: String = "s1", tool: String? = nil, cwd: String = "/tmp/app") -> Data {
    var json: [String: Any] = ["hook_event_name": name, "session_id": session, "cwd": cwd, "transcript_path": "/tmp/t.jsonl"]
    json["tool_name"] = tool
    return try! JSONSerialization.data(withJSONObject: json)
}

private func event(_ kind: HookEvent.Kind, session: String = "s1", cwd: String = "/tmp/app",
                   host: String? = "com.microsoft.VSCode", pid: Int32? = nil, at t: TimeInterval = 0) -> HookEvent {
    HookEvent(agent: .claude, kind: kind, sessionID: session, cwd: cwd, hostBundleID: host, agentPID: pid,
              date: Date(timeIntervalSince1970: t))
}

@Suite struct HookEventTests {
    @Test func parsesClaudeAndCodexNames() {
        #expect(HookEvent(agent: .claude, payload: payload("PreToolUse", tool: "Bash"))?.kind == .toolStart)
        #expect(HookEvent(agent: .claude, payload: payload("PreToolUse", tool: "AskUserQuestion"))?.kind == .needsYou)
        #expect(HookEvent(agent: .codex, payload: payload("permission_request"))?.kind == .needsYou)
        #expect(HookEvent(agent: .codex, payload: payload("Stop"))?.cwd == "/tmp/app")
        #expect(HookEvent(agent: .claude, payload: payload("Notification")) == nil)
        #expect(HookEvent(agent: .claude, payload: Data("not json".utf8)) == nil)
    }
}

@Suite struct SessionStoreTests {
    @Test func lifecycleAndOutcomes() {
        var store = SessionStore()
        #expect(store.apply(event(.prompt)) == .none)
        #expect(store.hasWorking)
        guard case .needsAttention = store.apply(event(.needsYou)) else { Issue.record("expected attention"); return }
        #expect(!store.hasWorking)
        #expect(store.apply(event(.needsYou)) == .none)  // already waiting: no second notification
        store.apply(event(.toolEnd))
        #expect(store.hasWorking)
        guard case .finished(let s) = store.apply(event(.stop)) else { Issue.record("expected finished"); return }
        #expect(s.project == "app")
        #expect(store.sessions.isEmpty)
        #expect(store.apply(event(.stop)) == .none)
    }

    @Test func approvedCommandResumesWork() {
        var store = SessionStore()
        store.apply(event(.needsYou))
        #expect(!store.hasWorking)
        store.resume("claude:s1", at: Date(timeIntervalSince1970: 5))
        #expect(store.hasWorking && store.sessions["claude:s1"]?.toolRunning == true)
        guard case .finished = store.apply(event(.stop)) else { Issue.record("expected finished"); return }
    }

    @Test func rowsMergePerWindowWaitingFirst() {
        var store = SessionStore()
        store.apply(event(.prompt, session: "a", at: 1))
        store.apply(event(.prompt, session: "b", at: 2))
        store.apply(event(.prompt, session: "c", cwd: "/tmp/other", host: "com.apple.Terminal", at: 3))
        store.apply(event(.needsYou, session: "c", cwd: "/tmp/other", host: "com.apple.Terminal", at: 4))
        let rows = store.rows
        #expect(rows.count == 2)
        #expect(rows[0].project == "other" && rows[0].needsYou)
        #expect(rows[1].count == 2)
    }

    @Test func expiry() {
        var store = SessionStore()
        store.apply(event(.prompt, session: "idle", at: 0))
        store.apply(event(.toolStart, session: "tool", at: 0))
        store.apply(event(.needsYou, session: "wait", at: 0))
        store.apply(event(.prompt, session: "dead", pid: 42, at: 0))
        store.expire(now: Date(timeIntervalSince1970: 11 * 60)) { $0 != 42 }
        #expect(Set(store.sessions.keys) == ["claude:tool", "claude:wait"])
        store.expire(now: Date(timeIntervalSince1970: 61 * 60)) { _ in true }
        #expect(Set(store.sessions.keys) == ["claude:wait"])
    }
}

@Suite struct HookConfigTests {
    @Test func installReplacesNotifierAndKeepsOtherHooks() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let file = home.appending(path: ".claude/settings.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original: [String: Any] = [
            "model": "opus",
            "env": ["CLAUDE_CODE_PLUGIN_DIRS": "/opt/my-plugin"],
            "hooks": [
                "Stop": [["hooks": [["type": "command", "command": "node ~/.claude/hooks/claude-notifier-on-stop.js"]]]],
                "PreToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": "my-linter"]]]],
            ],
        ]
        try JSONSerialization.data(withJSONObject: original).write(to: file)

        let config = HookConfig(agent: .claude, home: home, executable: "/Applications/StayVibe.app/Contents/MacOS/StayVibe")
        #expect(!config.isInstalled)
        try config.install()
        try config.install()  // idempotent
        #expect(config.isInstalled)

        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        let hooks = json["hooks"] as! [String: Any]
        #expect(json["model"] as? String == "opus")
        #expect((hooks["Stop"] as! [Any]).count == 1)
        #expect((hooks["PreToolUse"] as! [Any]).count == 2)
        #expect(!String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("claude-notifier"))
        // The usage plugin is written and loaded next to the user's own plugin folders.
        let plugin = home.appending(path: "Library/Application Support/StayVibe/ClaudePlugin")
        #expect(json["env"] as? [String: String] == ["CLAUDE_CODE_PLUGIN_DIRS": "/opt/my-plugin:\(plugin.path)", "CLAUDE_CODE_ENABLE_FUNCTION_HOOKS": "1"])
        #expect(FileManager.default.fileExists(atPath: plugin.appending(path: "hooks/register.ts").path))
        try FileManager.default.removeItem(at: plugin.appending(path: "hooks/register.ts"))
        #expect(!config.isInstalled)
        // An older StayVibe entry (different path or command) is replaced, not duplicated.
        try HookConfig(agent: .claude, home: home, executable: "/old/StayVibe").install()
        try config.install()
        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        #expect(((after["hooks"] as! [String: Any])["Stop"] as! [Any]).count == 1)
    }
}

@Suite struct UsageTests {
    @Test func claude() throws {
        let body = #"{"five_hour":{"utilization":72.0,"resets_at":"2026-10-03T05:00:00.123456+00:00"},"seven_day":{"utilization":31,"resets_at":"2026-10-06T09:00:00Z"},"seven_day_opus":null}"#
        let u = try #require(UsageParser.claude(Data(body.utf8)))
        #expect(u.fiveHour.used == 0.72 && u.weekly.used == 0.31)
        #expect(u.fiveHour.resetsAt == Date(timeIntervalSince1970: 1_791_003_600))
    }

    @Test func claudePushed() throws {
        let both = #"[{"kind":"five_hour","percentUsed":23.5,"resetsAt":"2026-10-03T05:00:00.000Z"},{"kind":"seven_day","percentUsed":65,"resetsAt":"2026-10-08T22:00:00Z"}]"#
        let u = try #require(UsageParser.claudePushed(Data(both.utf8), updated: .now))
        #expect(u.fiveHour.used == 0.235 && u.weekly.used == 0.65)
        #expect(u.fiveHour.resetsAt == Date(timeIntervalSince1970: 1_791_003_600))
        // A window whose reset passed is left out: unused until the next response reports it.
        let weekOnly = #"[{"kind":"seven_day","percentUsed":65}]"#
        #expect(UsageParser.claudePushed(Data(weekOnly.utf8), updated: .now)?.fiveHour.used == 0)
        #expect(UsageParser.claudePushed(Data(#"[{"kind":"spend_limit","percentUsed":40}]"#.utf8), updated: .now) == nil)
    }

    @Test func codexPaidPlanOnly() {
        let paid = #"{"timestamp":"x","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":86.0,"window_minutes":300,"resets_at":1791000000},"secondary":{"used_percent":12.0,"window_minutes":10080,"resets_at":1791500000}}}}"#
        let free = #"{"type":"event_msg","payload":{"rate_limits":{"primary":{"used_percent":45.0,"window_minutes":43200,"resets_at":1793518319},"secondary":null}}}"#
        let u = UsageParser.codex(logTail: "garbage\n" + paid, updated: .now)
        #expect(u?.fiveHour.used == 0.86 && u?.weekly.used == 0.12)
        #expect(UsageParser.codex(logTail: free, updated: .now) == nil)
    }

    @Test func arcAndWeeklyExhaustion() {
        func usage(_ agent: Agent, _ five: Double, _ week: Double) -> AgentUsage {
            AgentUsage(agent: agent, fiveHour: Quota(window: .fiveHour, used: five, resetsAt: nil),
                       weekly: Quota(window: .weekly, used: week, resetsAt: nil), updated: .now)
        }
        let both = [usage(.claude, 1.0, 0.6), usage(.codex, 0.55, 1.0)]
        #expect(both.arc?.agent == .codex)
        #expect(!both.weeklyExhausted)
        #expect([usage(.claude, 0.3, 1.0), usage(.codex, 0.2, 1.0)].weeklyExhausted)
        #expect(![AgentUsage]().weeklyExhausted)
        // Only a single subscription's critical weekly quota takes over, and only while the 5-hour one is fine.
        #expect([usage(.claude, 0.74, 0.9)].arcQuota?.window == .weekly)
        #expect([usage(.claude, 0.3, 0.89)].arcQuota?.window == .fiveHour)
        #expect([usage(.claude, 0.75, 0.95)].arcQuota?.window == .fiveHour)
        #expect([usage(.claude, 0.3, 0.95), usage(.codex, 0.5, 0.2)].arcQuota?.window == .fiveHour)
        #expect([AgentUsage]().arcQuota == nil)
    }

    @Test func passedResetMeansZero() {
        let q = Quota(window: .fiveHour, used: 0.9, resetsAt: Date(timeIntervalSince1970: 100))
        #expect(q.current(at: Date(timeIntervalSince1970: 101)).used == 0)
        #expect(q.current(at: Date(timeIntervalSince1970: 99)).used == 0.9)
    }
}

@Suite struct TranscriptTests {
    @Test func claudeInterrupt() {
        let interrupted = """
        {"type":"assistant","timestamp":"2026-10-03T03:00:00.000Z"}
        {"type":"user","timestamp":"2026-10-03T03:00:05.000Z","message":{"content":[{"type":"text","text":"[Request interrupted by user]"}]}}
        """
        #expect(Transcript.interruption(.claude, tail: interrupted) == Date(timeIntervalSince1970: 1_790_996_405))
        #expect(Transcript.interruption(.claude, tail: interrupted + "\n{\"type\":\"user\",\"message\":\"next\"}") == nil)
    }

    @Test func codexAbort() {
        let aborted = """
        {"timestamp":"2026-10-03T03:00:00Z","type":"event_msg","payload":{"type":"task_started"}}
        {"timestamp":"2026-10-03T03:00:09Z","type":"event_msg","payload":{"type":"turn_aborted","reason":"interrupted"}}
        """
        #expect(Transcript.interruption(.codex, tail: aborted) != nil)
        #expect(Transcript.interruption(.codex, tail: "{\"type\":\"task_started\"}") == nil)
    }
}

@Suite struct SocketTests {
    @Test func roundTrip() async throws {
        let path = "/tmp/sv-\(UUID().uuidString.prefix(8)).sock"
        let received = AsyncStream<HookEvent>.makeStream()
        let listener = EventSocket.Listener(path: path) { received.continuation.yield($0) }
        #expect(listener != nil)
        let sent = event(.toolStart, pid: 7)
        #expect(EventSocket.send(sent, to: path))
        var iterator = received.stream.makeAsyncIterator()
        #expect(await iterator.next() == sent)
        #expect(!EventSocket.send(sent, to: "/tmp/nobody-listens.sock"))
        _ = listener
    }
}

@Suite struct EditorWindowsTests {
    @Test func picksTheOpenFolderContainingTheSession() {
        let storage = Data(#"{"windowsState":{"lastActiveWindow":{"folder":"file:///Users/me/app"},"openedWindows":[{"backupPath":"/x"},{"folder":"file:///Users/me"},{"folder":"file:///Users/me/app"}]}}"#.utf8)
        #expect(EditorWindows.folder(containing: "/Users/me/app/src", storage: storage)?.path == "/Users/me/app")
        #expect(EditorWindows.folder(containing: "/Users/me/other", storage: storage)?.path == "/Users/me")
        #expect(EditorWindows.folder(containing: "/Users/me/application", storage: Data(#"{"windowsState":{"openedWindows":[{"folder":"file:///Users/me/app"}]}}"#.utf8)) == nil)
        #expect(EditorWindows.folder(containing: "/tmp", storage: storage) == nil)
    }
}

@Suite struct TitleTests {
    @Test func claudePrefersCustomTitle() {
        let tail = """
        {"type":"ai-title","aiTitle":"Fix login page","sessionId":"a"}
        {"type":"user","message":"hi"}
        {"type":"custom-title","customTitle":"Dark mode","sessionId":"a"}
        {"type":"ai-title","aiTitle":"Fix login page v2","sessionId":"a"}
        """
        #expect(Transcript.claudeTitle(tail: tail) == "Dark mode")
        #expect(Transcript.claudeTitle(tail: #"{"type":"ai-title","aiTitle":"Only AI"}"#) == "Only AI")
        #expect(Transcript.claudeTitle(tail: #"{"type":"user"}"#) == nil)
    }

    @Test func codexIndex() {
        let index = """
        {"id":"01a1-x","thread_name":"Old name","updated_at":"1"}
        {"id":"01a1-y","thread_name":"Other","updated_at":"2"}
        {"id":"01a1-x","thread_name":"Weekly report","updated_at":"3"}
        """
        #expect(Transcript.codexTitle(index: index, sessionID: "01a1-x") == "Weekly report")
        #expect(Transcript.codexTitle(index: index, sessionID: "nope") == nil)
    }

    @Test func meaninglessFoldersUseTheTitleAndStaySeparate() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var store = SessionStore()
        store.apply(event(.prompt, session: "a", cwd: home))
        store.apply(event(.prompt, session: "b", cwd: home))
        store.apply(event(.prompt, session: "c", cwd: home + "/Documents/Codex/2026-10-03/1"))
        store.apply(event(.prompt, session: "d", cwd: home + "/Library/Application Support/Claude/scratch-workspaces/x/y/scratch-2026-10-05-ab12cd"))
        store.setTitle("Dark mode", for: "claude:a")
        #expect(store.sessions["claude:a"]?.project == "Dark mode")
        #expect(store.sessions["claude:b"]?.project == "Claude Code")  // no title yet
        #expect(store.sessions["claude:c"]?.namedByTitle == true)
        #expect(store.sessions["claude:d"]?.namedByTitle == true)
        #expect(store.rows.count == 4)
    }
}
