import AppKit
import UserNotifications

final class Notifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// False when macOS blocks Duckproof's notifications (the permission banner is easy to miss).
    @Published private(set) var allowedBySystem = true

    private var center: UNUserNotificationCenter { .current() }

    func requestAuthorization() {
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in self.refresh() }
    }

    func refresh() {
        center.getNotificationSettings { settings in
            let allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            DispatchQueue.main.async { self.allowedBySystem = allowed }
        }
    }

    /// Asks again if macOS never got an answer, otherwise opens Duckproof's page in System Settings.
    func fixPermission() {
        center.getNotificationSettings { settings in
            DispatchQueue.main.async {
                if settings.authorizationStatus == .notDetermined {
                    self.requestAuthorization()
                } else {
                    let id = Bundle.main.bundleIdentifier ?? "app.duckproof.Duckproof"
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")!)
                }
            }
        }
    }

    /// The duck from the launch film (Resources/sounds/Quack.wav, made by scripts/make-quack.py).
    static let quack = UNNotificationSound(named: UNNotificationSoundName("Quack.wav"))

    /// `url` is opened when the notification is clicked.
    func post(_ title: String, _ body: String, id: String = UUID().uuidString, url: URL? = nil,
              sound: UNNotificationSound? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = sound
        if let url { content.userInfo["url"] = url.absoluteString }
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        refresh()   // keeps the "blocked by macOS" warning up to date
    }

    // A menu bar app always counts as frontmost: without this, nothing would show.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let link = response.notification.request.content.userInfo["url"] as? String, let url = URL(string: link) {
            NSWorkspace.shared.open(url)
        }
        completionHandler()
    }
}
