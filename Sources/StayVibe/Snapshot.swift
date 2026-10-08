#if DEBUG
import StayVibeCore
import SwiftUI

/// `--snapshot <dir>` renders the README screenshot (menu bar, panel, settings, a notification) with
/// sample data, in English and Chinese. Debug builds only; run it through scripts/screenshot.sh.
@MainActor enum Snapshot {
    static func render(to dir: String) -> Never {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApp.appearance = NSAppearance(named: .aqua)
        // Controls draw in their active colors only in the active app, and macOS may keep the app the user
        // is typing in active: keep asking for a while, then write nothing rather than gray screenshots.
        for _ in 0..<100 where !NSApp.isActive { NSApp.activate(); RunLoop.main.run(until: .now + 0.1) }
        guard NSApp.isActive else { exit(1) }
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../Resources")
        AppModel.shared.loadSample()
        for (language, suffix, clock) in [(Language.en, "en", "Sat Oct 3  15:20"), (Language.zhHans, "zh", "10月3日 周六  15:20")] {
            L10n.bundle = Bundle(url: resources.appending(path: "\(language.rawValue).lproj")) ?? .main
            L10n.locale = Locale(identifier: language.rawValue)
            shot(Screenshot(clock: clock, icon: lightIcon),
                 to: "\(dir)/screenshot-\(suffix).png")
        }
        exit(0)
    }

    /// The app's own icon follows the system's icon style, not the app's appearance, so
    /// scripts/screenshot.sh exports the light one.
    private static var lightIcon: NSImage? { Bundle.main.image(forResource: "SnapshotIcon") }

    /// Must be key, or switches and progress bars draw in their inactive gray.
    private final class KeyWindow: NSWindow { override var canBecomeKey: Bool { true } }

    private static func shot(_ view: some View, to path: String) {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: .aqua)
        let window = KeyWindow(contentRect: CGRect(origin: CGPoint(x: -10000, y: -10000), size: host.fittingSize),
                               styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        RunLoop.main.run(until: .now + 0.6)  // let SwiftUI lay out (and measure the settings form)
        window.setContentSize(host.fittingSize)
        RunLoop.main.run(until: .now + 0.3)
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

/// A slice of the menu bar with StayVibe's icon, its panel open below it, and the settings page.
private struct Screenshot: View {
    let clock: String
    let icon: NSImage?

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            HStack(spacing: 16) {
                Spacer()
                MenuBarIcon()
                Text(clock)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 14)
            .frame(height: 26)
            .background(Color(white: 0.97))
            HStack(alignment: .top, spacing: 20) {
                popover(PanelView(showSettings: true))
                VStack(spacing: 20) {
                    popover(PanelView())
                    VStack(spacing: 10) {
                        banner("pixel-garden", tr("%@ finished", Agent.claude.displayName))
                        banner("orbit-api", tr("%@ needs you", Agent.claude.displayName))
                        banner(Agent.codex.planName, tr("5-hour limit reset"))
                        banner("StayVibe", tr("Battery below %d%%, Mac is allowed to sleep", 20))
                    }
                }
            }
            .padding(.trailing, 70)
            .padding(.bottom, 28)
        }
        .frame(width: 820)
        .background(LinearGradient(colors: [Color(red: 0.80, green: 0.86, blue: 0.95), Color(red: 0.90, green: 0.88, blue: 0.95)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    /// One of StayVibe's notifications, as macOS shows it.
    private func banner(_ title: String, _ body: String) -> some View {
        HStack(spacing: 12) {
            if let icon { Image(nsImage: icon).resizable().frame(width: 38, height: 38) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(body).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .frame(width: 350)
        .background(Color(white: 0.98), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
    }

    private func popover(_ panel: PanelView) -> some View {
        panel
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
    }
}
#endif
