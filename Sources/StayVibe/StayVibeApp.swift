import SwiftUI

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--hook") {
            HookMode.run(agent: args.indices.contains(i + 1) ? args[i + 1] : "claude")
        }
        #if DEBUG
        if let i = args.firstIndex(of: "--snapshot") { Snapshot.render(to: args[i + 1]) }
        #endif
        StayVibeApp.main()
    }
}

struct StayVibeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra { PanelView() } label: { MenuBarIcon() }
            .menuBarExtraStyle(.window)
        Window("StayVibe", id: "welcome") { WelcomeView() }
            .windowResizability(.contentSize)
            .defaultLaunchBehavior(AppModel.shared.onboarded ? .suppressed : .presented)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.shared.start()
        if !AppModel.shared.onboarded { NSApp.activate() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.stop()
    }
}
