import AppKit
import Observation
import os
import ServiceManagement
import Sparkle
import StayVibeCore

enum NotificationKind: String, Codable, CaseIterable, Identifiable {
    case finished, needsYou, quotaReset
    var id: Self { self }

    var label: String {
        switch self {
        case .finished: tr("Finished")
        case .needsYou: tr("Needs you")
        case .quotaReset: tr("Quota reset")
        }
    }

    var defaultSound: String {
        switch self {
        case .finished: "Hero"
        case .needsYou: "Glass"
        case .quotaReset: "Ping"
        }
    }
}

struct Settings: Codable, Equatable {
    struct Alert: Codable, Equatable { var enabled = true; var sound: String }

    var keepAwake = true
    /// Minutes to stay awake after the last session stops or starts waiting for you, so the phone can still
    /// reach the Mac (Remote Control) with the lid closed; 0 is off.
    var awakeAfter = 15
    var batteryFloor = 20
    var launchAtLogin = true
    var autoUpdate = true
    var language = Language.system
    var alerts = Dictionary(uniqueKeysWithValues: NotificationKind.allCases.map { ($0, Alert(sound: $0.defaultSound)) })

    static let key = "settings"
    static func load() -> Settings {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } ?? Settings()
    }
    func save() { UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.key) }
}

/// Why the Mac is allowed to sleep even though sessions are running (shown in the panel title).
enum SleepBlocker: Equatable {
    case disabled, battery(Int), hot

    var text: String {
        switch self {
        case .disabled: tr("Keep-awake off")
        case .battery(let level): tr("Battery %d%%, sleep allowed", level)
        case .hot: tr("Too hot, sleep allowed")
        }
    }
}

/// Sessions, keep-awake and usage decisions, visible in Console.app (subsystem io.github.dvdsanyi.stayvibe).
let log = Logger(subsystem: "io.github.dvdsanyi.stayvibe", category: "app")

@MainActor @Observable final class AppModel {
    static let shared = AppModel()

    private(set) var store = SessionStore()
    private(set) var usage: [AgentUsage] = []
    private(set) var now = Date.now
    private(set) var blocker: SleepBlocker?
    /// First agent whose hooks are missing from its config file, if any.
    private(set) var missingHooks: Agent?
    var settings = Settings.load() { didSet { settingsChanged(from: oldValue) } }
    /// Codex ignores new hooks until the user trusts them; the first Codex event proves they did.
    var codexTrusted = UserDefaults.standard.bool(forKey: "codexTrusted") {
        didSet { UserDefaults.standard.set(codexTrusted, forKey: "codexTrusted") }
    }
    var onboarded = UserDefaults.standard.bool(forKey: "onboarded") {
        didSet { UserDefaults.standard.set(onboarded, forKey: "onboarded") }
    }

    @ObservationIgnored let notifier = Notifier()
    @ObservationIgnored let updater = SPUStandardUpdaterController(
        startingUpdater: Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil,
        updaterDelegate: nil, userDriverDelegate: nil)
    @ObservationIgnored private let power = Power()
    @ObservationIgnored private var listener: EventSocket.Listener?
    @ObservationIgnored private var timers: [Timer] = []
    @ObservationIgnored private var releaseTask: Task<Void, Never>?
    @ObservationIgnored private var lastWorking = Date.distantPast
    @ObservationIgnored private var resetAlerts: [String: Date] = [:]
    #if DEBUG
    @ObservationIgnored private var isSample = false
    #endif

    var hookConfigs: [HookConfig] {
        Agent.allCases.map { HookConfig(agent: $0, executable: Bundle.main.executablePath ?? "") }.filter(\.agentInstalled)
    }
    var currentUsage: [AgentUsage] { usage.map { $0.current(at: now) } }

    func start() {
        L10n.use(settings.language)
        notifier.activate()
        listener = EventSocket.Listener { event in MainActor.assumeIsolated { AppModel.shared.handle(event) } }
        refreshHookStatus()
        applyUpdaterSettings()
        if settings.launchAtLogin { setLaunchAtLogin(true) }
        timers = [
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in MainActor.assumeIsolated { AppModel.shared.tick() } },
            Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in MainActor.assumeIsolated { AppModel.shared.refreshUsage() } },
        ]
        refreshUsage()
    }

    /// Called on quit: never leave the clamshell switch on.
    func stop() { power.set(active: false) }

    // MARK: - Events

    func handle(_ event: HookEvent) {
        log.notice("event \(event.agent.rawValue, privacy: .public) \(event.kind.rawValue, privacy: .public) \(event.sessionID.prefix(8), privacy: .public) host=\(event.hostBundleID ?? "-", privacy: .public)")
        if event.agent == .codex { codexTrusted = true }
        switch store.apply(event) {
        case .finished(let s):
            alert(.finished, session: s, body: tr("%@ finished", s.agent.displayName))
        case .needsAttention(let s):
            alert(.needsYou, session: s, body: tr("%@ needs you", s.agent.displayName))
        case .none: break
        }
        updatePower()
    }

    private func tick() {
        now = .now
        let before = Set(store.sessions.keys)
        store.expire(now: now) { kill($0, 0) == 0 || errno == EPERM }
        for id in before.subtracting(store.sessions.keys) { log.notice("expired \(id.prefix(15), privacy: .public)") }
        for s in store.sessions.values {
            guard let path = s.transcriptPath, let tail = Transcript.tail(of: path, bytes: 16 * 1024),
                  let at = Transcript.interruption(s.agent, tail: tail), at >= s.lastEvent.addingTimeInterval(-1) else { continue }
            store.remove(s.id)
            log.notice("interrupted \(s.id.prefix(15), privacy: .public)")
        }
        for s in store.sessions.values where s.needsYou {
            guard let pid = s.agentPID, startedShell(under: pid, after: s.lastEvent) else { continue }
            store.resume(s.id, at: now)
            log.notice("approved \(s.id.prefix(15), privacy: .public)")
        }
        nameSessions()
        let previous = blocker
        if !settings.keepAwake { blocker = .disabled }
        else if let level = Power.batteryLevel, level < settings.batteryFloor { blocker = .battery(level) }
        else if Power.tooHot { blocker = .hot }
        else { blocker = nil }
        // Tell the user once when a safeguard kicks in while sessions are running.
        switch (previous, blocker) {
        case (.battery, .battery), (.hot, .hot): break
        case (_, .battery) where store.hasWorking:
            notifier.post(title: "StayVibe", body: tr("Battery below %d%%, Mac is allowed to sleep", settings.batteryFloor), sound: nil, thread: "StayVibe")
        case (_, .hot) where store.hasWorking:
            notifier.post(title: "StayVibe", body: tr("Too hot, Mac is allowed to sleep"), sound: nil, thread: "StayVibe")
        default: break
        }
        showNewestClaude(UsageService.claudePushed())
        checkQuotaResets()
        updatePower()
        power.tick()
    }

    /// Whether the agent started a shell after it began waiting: the command the user just approved.
    /// (Claude Code and Codex run each command in a shell that is their direct child.)
    private func startedShell(under pid: Int32, after date: Date) -> Bool {
        var children = [pid_t](repeating: 0, count: 256)
        let count = proc_listchildpids(pid, &children, Int32(children.count * MemoryLayout<pid_t>.size))
        return children.prefix(Int(max(count, 0))).contains { child in
            var info = proc_bsdinfo()
            guard proc_pidinfo(child, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return false }
            let name = withUnsafeBytes(of: info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            return ["zsh", "bash", "sh", "fish"].contains(name) && TimeInterval(info.pbi_start_tvsec) > date.timeIntervalSince1970
        }
    }

    /// Sessions in a meaningless folder take the conversation's title once the agent has written one.
    private func nameSessions() {
        let codexIndex = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/session_index.jsonl").path
        for s in store.sessions.values where s.namedByTitle && s.title == nil {
            let title = s.agent == .claude
                ? s.transcriptPath.flatMap { Transcript.tail(of: $0) }.flatMap(Transcript.claudeTitle)
                : Transcript.tail(of: codexIndex).flatMap { Transcript.codexTitle(index: $0, sessionID: s.sessionID) }
            if let title { store.setTitle(title, for: s.id) }
        }
    }

    /// Hold the Mac awake while any session works and for `awakeAfter` minutes after the last one stopped or
    /// began waiting for you; let go 3 s after that so the sound can play.
    private func updatePower() {
        if store.hasWorking { lastWorking = .now }
        let wanted = Date.now < lastWorking + TimeInterval(settings.awakeAfter * 60) || store.hasWorking
        if settings.keepAwake && wanted && blocker == nil {
            releaseTask?.cancel()
            releaseTask = nil
            power.set(active: true)
        } else if power.isActive, releaseTask == nil {
            releaseTask = Task {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                power.set(active: false)
                releaseTask = nil
            }
        }
    }

    private func alert(_ kind: NotificationKind, session s: Session, body: String) {
        guard let pref = settings.alerts[kind], pref.enabled else { return }
        notifier.post(title: s.project, body: body, sound: pref.sound, thread: s.project, host: s.hostBundleID, cwd: s.cwd)
    }

    // MARK: - Usage

    func refreshUsage() {
        Task {
            showNewestClaude(UsageService.claudePushed())
            // Claude Code pushes Claude's numbers after every turn; the rate-limited endpoint only fills in stale ones.
            if usage.first(where: { $0.agent == .claude }).map(isStale) ?? true { showNewestClaude(await UsageService.claude()) }
            let codex = UsageService.codex()
            usage = usage.filter { $0.agent == .claude } + [codex].compactMap { $0 }
            codex.map(logUsage)
        }
    }

    /// Newest Claude numbers win: pushed by Claude Code, fetched, or the ones already shown.
    private func showNewestClaude(_ candidate: AgentUsage?) {
        guard let candidate, candidate.updated > usage.first(where: { $0.agent == .claude })?.updated ?? .distantPast else { return }
        usage = [candidate] + usage.filter { $0.agent != .claude }
        logUsage(candidate)
    }

    private func logUsage(_ u: AgentUsage) {
        log.notice("usage \(u.agent.rawValue, privacy: .public) 5h=\(Int(u.fiveHour.used * 100))% 7d=\(Int(u.weekly.used * 100))%")
    }

    func isStale(_ u: AgentUsage) -> Bool { u.agent == .claude && now.timeIntervalSince(u.updated) > 60 * 60 }

    /// "Quota reset" only matters for quotas that were nearly used up: remember those, announce when they reset.
    private func checkQuotaResets() {
        for u in usage {
            for q in u.quotas {
                let key = "\(u.agent.rawValue)-\(q.window.rawValue)"
                if q.used >= Quota.warning, let reset = q.resetsAt, reset > now { resetAlerts[key] = reset }
                guard let reset = resetAlerts[key], reset <= now else { continue }
                resetAlerts[key] = nil
                guard let pref = settings.alerts[.quotaReset], pref.enabled else { continue }
                notifier.post(title: u.agent.planName,
                              body: q.window == .fiveHour ? tr("5-hour limit reset") : tr("Weekly limit reset"),
                              sound: pref.sound, thread: "quota")
            }
        }
    }

    // MARK: - Settings side effects

    private func settingsChanged(from old: Settings) {
        settings.save()
        if settings.language != old.language { L10n.use(settings.language) }
        if settings.launchAtLogin != old.launchAtLogin { setLaunchAtLogin(settings.launchAtLogin) }
        if settings.autoUpdate != old.autoUpdate { applyUpdaterSettings() }
        if settings.keepAwake != old.keepAwake || settings.awakeAfter != old.awakeAfter { tick() }
    }

    func restoreDefaults() { settings = Settings() }

    private func applyUpdaterSettings() {
        updater.updater.automaticallyChecksForUpdates = settings.autoUpdate
        updater.updater.automaticallyDownloadsUpdates = settings.autoUpdate
    }

    /// A login item for the app itself. (Not a LaunchAgent: without a Team ID macOS pins an agent to
    /// the exact build that registered it, so it stops launching after every update.)
    private func setLaunchAtLogin(_ on: Bool) {
        guard Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }  // not for dev builds
        _ = on ? try? SMAppService.mainApp.register() : try? SMAppService.mainApp.unregister()
    }

    // MARK: - Hooks

    var hooksInstalled: Bool { missingHooks == nil }

    var canCheckForUpdates: Bool {
        #if DEBUG
        if isSample { return true }
        #endif
        return updater.updater.canCheckForUpdates
    }

    func refreshHookStatus() {
        #if DEBUG
        if isSample { return }
        #endif
        let configs = hookConfigs
        missingHooks = configs.isEmpty ? .claude : configs.first { !$0.isInstalled }?.agent
    }

    func installHooks() {
        for config in hookConfigs where !config.isInstalled {
            try? config.install()
            if config.agent == .codex { codexTrusted = false }  // changed hooks need Codex's trust again
        }
        refreshHookStatus()
    }

    var needsCodexTrust: Bool { hooksInstalled && !codexTrusted && hookConfigs.contains { $0.agent == .codex } }
}

#if DEBUG
extension AppModel {
    /// Sample sessions and quotas for README screenshots (see Snapshot.swift).
    func loadSample() {
        let now = Date.now
        let hour = Calendar.current.dateInterval(of: .hour, for: now)!.start
        func sample(_ agent: Agent, _ five: Double, _ fiveReset: TimeInterval, _ week: Double, _ weekReset: TimeInterval) -> AgentUsage {
            AgentUsage(agent: agent, fiveHour: Quota(window: .fiveHour, used: five, resetsAt: now + fiveReset),
                       weekly: Quota(window: .weekly, used: week, resetsAt: hour + weekReset), updated: now)
        }
        usage = [sample(.claude, 0.97, 2 * 3600 + 14 * 60, 0.31, 3 * 86400), sample(.codex, 0.88, 47 * 60, 0.86, 5 * 86400)]
        // One example showing as many states as possible: needs you, a merged row, every host, a long name.
        let sessions: [(String, Agent, String, Int, Bool)] = [
            ("orbit-api", .claude, "com.apple.Terminal", 1, true),
            ("pixel-garden", .claude, "com.microsoft.VSCode", 3, false),
            ("weather-widget", .codex, "com.openai.codex", 1, false),
            ("design-tokens-v2-migration-playground-experiments", .codex, "com.microsoft.VSCode", 1, false),
        ]
        for (i, (project, agent, host, count, needsYou)) in sessions.enumerated() {
            for n in 0..<count {
                let id = "\(project)-\(n)", cwd = "/Users/me/Projects/\(project)", date = now - TimeInterval(i * 60)
                store.apply(HookEvent(agent: agent, kind: .prompt, sessionID: id, cwd: cwd, hostBundleID: host, date: date))
                if needsYou { store.apply(HookEvent(agent: agent, kind: .needsYou, sessionID: id, cwd: cwd, hostBundleID: host, date: date)) }
            }
        }
        blocker = .battery(18)
        missingHooks = nil
        codexTrusted = true
        isSample = true
    }
}
#endif
