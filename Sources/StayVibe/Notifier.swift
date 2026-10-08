import AppKit
import UserNotifications

/// System notifications. Sounds are played with NSSound so any of the built-in sounds can be chosen.
@MainActor final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    // Looked up on use: the notification center needs an app bundle (not there in debug snapshots).
    private var center: UNUserNotificationCenter { .current() }

    func activate() { center.delegate = self }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert])) ?? false
    }

    var isAuthorized: Bool {
        get async { await center.notificationSettings().authorizationStatus == .authorized }
    }

    /// `thread` groups notifications per project; `host`/`cwd` say where a click should go.
    func post(title: String, body: String, sound: String?, thread: String, host: String? = nil, cwd: String = "") {
        if let sound { NSSound(named: sound)?.play() }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = thread
        content.userInfo = ["host": host ?? "", "cwd": cwd]
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .list] }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let host = (info["host"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let cwd = info["cwd"] as? String ?? ""
        await MainActor.run { HostApp.jump(to: host, cwd: cwd) }
    }
}
