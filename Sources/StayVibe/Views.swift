import SwiftUI
import StayVibeCore

struct PanelView: View {
    @State var showSettings = false

    var body: some View {
        Group {
            if showSettings { SettingsView { showSettings = false } } else { MainView { showSettings = true } }
        }
        .frame(width: 350)
        .id(AppModel.shared.settings.language)  // rebuild all strings on a language switch
    }
}

// MARK: - Main panel

struct MainView: View {
    let openSettings: () -> Void

    var body: some View {
        let model = AppModel.shared
        let usage = model.currentUsage
        let rows = model.store.rows
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("StayVibe").font(.title3.weight(.bold))
                Spacer(minLength: 8)
                if let blocker = model.blocker {
                    Text(blocker.text).font(.subheadline.weight(.medium)).lineLimit(1)
                        .foregroundStyle(blocker == .disabled ? Color.secondary : .orange)
                }
                Button(action: openSettings) { Image(systemName: "gearshape") }
                    .buttonStyle(HoverButtonStyle()).foregroundStyle(.secondary).help(tr("Settings"))
            }
            .padding(.leading, 14).padding(.trailing, 8).padding(.top, 10)

            if usage.isEmpty {
                Text(rows.isEmpty ? tr("Usage and sessions appear here once you use Claude Code or Codex") : tr("No usage data yet"))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(14)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(usage, id: \.agent) { AgentBlock(usage: $0, stale: model.isStale($0), now: model.now) }
                }
                .padding(14)
            }

            if !rows.isEmpty {
                Divider()
                ScrollView {
                    VStack(spacing: 0) { ForEach(rows) { SessionRowView(row: $0) } }.padding(5)
                }
                .frame(height: min(CGFloat(rows.count), 6) * 26 + 10)
                .scrollBounceBehavior(.basedOnSize)
            }
        }
    }
}

struct AgentBlock: View {
    let usage: AgentUsage
    let stale: Bool
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(usage.agent.planName).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                if stale {
                    Text(tr("updated %@", updatedText)).font(.subheadline).foregroundStyle(.tertiary)
                }
            }
            HStack(spacing: 18) {
                ForEach(usage.quotas, id: \.window) { QuotaView(quota: $0, stale: stale, now: now) }
            }
        }
    }

    /// "20 hours ago" rather than "1243 min ago".
    private var updatedText: String {
        let format = RelativeDateTimeFormatter()
        format.locale = L10n.locale
        return format.localizedString(for: usage.updated, relativeTo: now)
    }
}

struct QuotaView: View {
    let quota: Quota
    let stale: Bool
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(quota.used, format: .percent.precision(.fractionLength(0)))
                    .font(.title2.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(stale ? .secondary : usageColor(quota.used))
                Spacer()
                Text(quota.window.rawValue).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            }
            ProgressView(value: quota.used)
                .progressViewStyle(.linear).controlSize(.small)
                .tint(!stale && quota.used >= Quota.warning ? usageColor(quota.used) : .secondary)
            Text(resetText).font(.caption).monospacedDigit().foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }

    private var resetText: String {
        guard let reset = quota.resetsAt else { return " " }
        if quota.window == .fiveHour {
            let minutes = max(Int(reset.timeIntervalSince(now) / 60), 1)
            let span = minutes >= 60 ? "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m" : "\(minutes)m"
            return tr("resets in %@", span)
        }
        let format = DateFormatter()
        format.locale = L10n.locale
        format.setLocalizedDateFormatFromTemplate("EEE HH:mm")
        return tr("resets %@", format.string(from: reset))
    }
}

/// Orange or red, see `Quota.warning`; nil means the normal color. Shared by the panel and the menu bar icon.
func usageTint(_ used: Double) -> Color? { used >= Quota.critical ? .red : used >= Quota.warning ? .orange : nil }
func usageColor(_ used: Double) -> Color { usageTint(used) ?? .primary }

struct SessionRowView: View {
    let row: SessionRow
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(row.needsYou ? .orange : .green).frame(width: 6, height: 6)
            // Full row if it fits; otherwise drop the source, then middle-truncate the name.
            // "Needs you" and the count badge are never truncated.
            ViewThatFits(in: .horizontal) {
                line(showSource: true).fixedSize()
                line(showSource: false)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, 9).frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6).fill(hover ? Color.primary.opacity(0.08) : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture {
            NSApp.keyWindow?.close()  // dismiss the menu bar panel, like choosing a menu item
            HostApp.jump(to: row.hostBundleID, cwd: row.cwd)
        }
    }

    private func line(showSource: Bool) -> some View {
        HStack(spacing: 8) {
            Text(row.project).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
            if row.needsYou {
                Text(tr("Needs you"))
                    .foregroundStyle(.orange).lineLimit(1).fixedSize()
            } else if showSource {
                let ownApp = HostApp.agentApps.contains(row.hostBundleID ?? "")
                HStack(spacing: 6) {
                    if !ownApp { Text(row.agent.displayName).foregroundStyle(.secondary) }
                    if let host = HostApp.name(row.hostBundleID) { Text(host).foregroundStyle(ownApp ? .secondary : .tertiary) }
                }
                .lineLimit(1)
            }
            if row.count > 1 {
                Text("\(row.count)").font(.caption2.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(.quaternary))
                    .fixedSize()
            }
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    let back: () -> Void
    @State private var formHeight: CGFloat = 560
    private static let sounds = ["Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero", "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"]
    private static let repo = URL(string: "https://github.com/dvdsanyi/StayVibe")!

    var body: some View {
        @Bindable var model = AppModel.shared
        VStack(spacing: 0) {
            HStack {
                Button(action: back) { Image(systemName: "chevron.left").font(.body.weight(.semibold)) }
                    .buttonStyle(HoverButtonStyle()).foregroundStyle(.secondary).help(tr("Back"))
                Spacer()
            }
            .padding(.leading, 8).padding(.top, 8)

            Form {
                Section(tr("Keep Awake")) {
                    Toggle(tr("Prevent sleep while sessions run"), isOn: $model.settings.keepAwake)
                    Picker(tr("Stay awake after sessions stop"), selection: $model.settings.awakeAfter) {
                        Text(tr("Off")).tag(0)
                        ForEach([5, 15, 30, 60], id: \.self) { Text(tr("%d min", $0)).tag($0) }
                    }
                    LabeledContent(tr("Allow sleep below battery")) {
                        HStack(spacing: 2) {
                            TextField("", value: Binding(get: { model.settings.batteryFloor },
                                                         set: { model.settings.batteryFloor = min(max($0, 5), 95) }),
                                      format: .number)
                                .labelsHidden().textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                                .monospacedDigit().frame(width: 44)
                            Text("%").foregroundStyle(.secondary)
                        }
                    }
                }
                Section(tr("Notifications")) {
                    ForEach(NotificationKind.allCases) { alertRow($0) }
                }
                Section(tr("General")) {
                    Toggle(tr("Launch at login"), isOn: $model.settings.launchAtLogin)
                    LabeledContent(tr("Automatic updates")) {
                        HStack(spacing: 10) {
                            Button(tr("Check Now")) { model.updater.checkForUpdates(nil) }
                                .controlSize(.small).disabled(!model.canCheckForUpdates)
                            Toggle(tr("Automatic updates"), isOn: $model.settings.autoUpdate).labelsHidden()
                        }
                    }
                    Picker(tr("Language"), selection: $model.settings.language) {
                        ForEach(Language.allCases) { Text($0.label).tag($0) }
                    }
                    LabeledContent("Hooks") { hooksStatus }
                }
            }
            .formStyle(.grouped)
            .toggleStyle(.switch)  // toggles sharing a row with another control would default to checkboxes
            .scrollDisabled(true)
            .frame(height: formHeight)
            .onScrollGeometryChange(for: CGFloat.self, of: \.contentSize.height) { _, height in formHeight = height }

            HStack {
                let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
                Link(destination: Self.repo) {
                    Label("v\(version)", systemImage: "arrow.up.right").labelStyle(TrailingIcon()).monospacedDigit()
                }
                .buttonStyle(HoverButtonStyle()).help("GitHub")
                Spacer()
                Button(tr("Restore Defaults")) { model.restoreDefaults() }.buttonStyle(HoverButtonStyle())
                Button(tr("Quit")) { NSApp.terminate(nil) }.buttonStyle(HoverButtonStyle())
            }
            .font(.callout).foregroundStyle(.secondary)
            .padding(.horizontal, 14).padding(.bottom, 10)
        }
        .onAppear { model.refreshHookStatus() }
    }

    private func alertRow(_ kind: NotificationKind) -> some View {
        let model = AppModel.shared
        let alert = Binding(get: { model.settings.alerts[kind] ?? .init(sound: kind.defaultSound) },
                            set: { model.settings.alerts[kind] = $0 })
        return LabeledContent(kind.label) {
            HStack(spacing: 10) {
                Picker(kind.label, selection: alert.sound) { ForEach(Self.sounds, id: \.self) { Text($0) } }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                    .onChange(of: alert.wrappedValue.sound) { _, sound in NSSound(named: sound)?.play() }
                Toggle(kind.label, isOn: alert.enabled).labelsHidden()
            }
        }
    }

    @ViewBuilder private var hooksStatus: some View {
        let model = AppModel.shared
        if let missing = model.missingHooks {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(tr("%@ missing", missing.displayName)).foregroundStyle(.secondary)
                Button(tr("Fix")) { model.installHooks() }.controlSize(.small)
            }
            .fixedSize()
        } else if model.needsCodexTrust {
            Button(action: HostApp.CodexTrust.open) {
                Label(tr("Codex needs approval"), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .buttonStyle(HoverButtonStyle())
            .help(HostApp.CodexTrust.hint)
        } else {
            Label { Text(tr("Ready")).foregroundStyle(.secondary) } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
    }
}

// MARK: - Welcome (first launch)

struct WelcomeView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var notificationsOn = false

    var body: some View {
        let model = AppModel.shared
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("StayVibe").font(.title2.weight(.bold))
                    Text(tr("A few steps to get started")).foregroundStyle(.secondary)
                }
            }
            Form {
                step(tr("Notifications"), tr("Sounds and banners when a task finishes or needs you"), button: tr("Allow"), done: notificationsOn) {
                    Task { notificationsOn = await model.notifier.requestAuthorization() }
                }
                step(tr("Connect Claude Code and Codex"), tr("Adds StayVibe's hooks and replaces Claude Notifier's"), button: tr("Install"), done: model.hooksInstalled) {
                    model.installHooks()
                }
                if model.hookConfigs.contains(where: { $0.agent == .codex }) {
                    LabeledContent {
                        if model.codexTrusted {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Button(HostApp.CodexTrust.buttonTitle, action: HostApp.CodexTrust.open)
                                .controlSize(.small).disabled(!model.hooksInstalled)
                        }
                    } label: {
                        Text(tr("Approve the hooks in Codex"))
                        Text(HostApp.CodexTrust.hint)
                    }
                }
            }
            .formStyle(.grouped).scrollDisabled(true).frame(height: 230)
            HStack {
                Spacer()
                Button(tr("Done")) {
                    model.onboarded = true
                    dismissWindow(id: "welcome")
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .task { notificationsOn = await model.notifier.isAuthorized }
    }

    private func step(_ title: String, _ detail: String, button: String, done: Bool, action: @escaping () -> Void) -> some View {
        LabeledContent {
            if done {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button(button, action: action).controlSize(.small)
            }
        } label: {
            Text(title)
            Text(detail)
        }
    }
}

// MARK: - Shared pieces

/// Hover-only highlight, like Control Center: no bezel at rest.
struct HoverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { HoverLabel(configuration: configuration) }

    struct HoverLabel: View {
        let configuration: Configuration
        @State private var hover = false

        var body: some View {
            configuration.label
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.16 : hover ? 0.09 : 0)))
                .contentShape(Rectangle())
                .onHover { hover = $0 }
                .animation(.easeOut(duration: 0.12), value: hover)
        }
    }
}

struct TrailingIcon: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) { configuration.title; configuration.icon.imageScale(.small) }
    }
}

/// The C-shaped quota gauge used by the menu bar icon and the app icon.
struct GaugeGlyph: View {
    let used: Double?
    let running: Bool
    let color: Color
    var line: CGFloat = 2.2
    var dot: CGFloat = 3.6

    var body: some View {
        ZStack {
            Circle().trim(from: 0, to: 0.75).stroke(color.opacity(0.35), style: .init(lineWidth: line, lineCap: .round))
            if let used, used > 0 {
                Circle().trim(from: 0, to: 0.75 * used).stroke(color, style: .init(lineWidth: line, lineCap: .round))
            }
        }
        .rotationEffect(.degrees(135))
        .overlay { if running { Circle().fill(color).frame(width: dot, height: dot) } }
    }
}

/// Arc: the lowest 5-hour quota (or a lone subscription's critical weekly one), tinted like the panel, and
/// red when every weekly quota is used up. Dot: an agent is working. Otherwise a template image.
struct MenuBarIcon: View {
    var body: some View {
        let model = AppModel.shared
        let usage = model.currentUsage
        let arc = usage.arc
        let quota = usage.arcQuota
        let tint = usage.weeklyExhausted ? .red : quota.flatMap { usageTint($0.used) }
        let glyph = GaugeGlyph(used: quota?.used, running: model.store.hasWorking, color: tint ?? .black)
            .frame(width: 14, height: 14).padding(2)
            .opacity(arc.map(model.isStale) == true ? 0.5 : 1)
        let renderer = ImageRenderer(content: glyph)
        renderer.scale = 2
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = tint == nil
        return Image(nsImage: image).help(tooltip(usage))
    }

    private func tooltip(_ usage: [AgentUsage]) -> String {
        usage.map { u in
            "\(u.agent.planName)    5h \(Int(u.fiveHour.used * 100))%    7d \(Int(u.weekly.used * 100))%"
        }.joined(separator: "\n")
    }
}
