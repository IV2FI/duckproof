import AppKit
import AVFoundation
import ServiceManagement
import SwiftUI

struct DuckproofApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: delegate.controller, updates: delegate.updates, delegate: delegate)
        } label: {
            MenuLabel(controller: delegate.controller)
        }
    }
}

extension Controller.Phase {
    var label: String {
        switch self {
        case .driverMissing: return L("⚠️ Audio driver not installed")
        case .micDenied: return L("⚠️ Microphone access denied")
        case .disabled: return L("Paused")
        case .waiting: return L("Ready · waiting for a call")
        case .ready: return L("FaceTime open · waiting for a call")
        case .inCall: return L("In a call · no ducking 🦆")
        case .failed(let message): return "⚠️ \(message)"
        }
    }
}

/// The three call settings, shared by the menu and the settings window.
private struct CallSettings: View {
    @ObservedObject var controller: Controller

    var body: some View {
        Picker("Duck Other Apps During Calls", selection: $controller.duckingDB) {
            Text("Off (full volume)").tag(0.0)
            Divider()
            Text("A little (−6 dB)").tag(6.0)
            Text("Medium (−12 dB)").tag(12.0)
            Text("A lot (−20 dB)").tag(20.0)
            Text("Almost silent (−30 dB)").tag(30.0)
        }
        Picker("FaceTime Volume", selection: $controller.faceTimeGain) {
            ForEach([1.0, 1.5, 2.0, 3.0], id: \.self) { gain in
                Text(verbatim: gain == 1 ? L("100% (unchanged)") : "\(Int(gain * 100))%").tag(gain)
            }
        }
        Picker("Send Call Audio To", selection: $controller.outputUID) {
            Text("System output (\(controller.systemOutputName))").tag("")
            Divider()
            ForEach(controller.outputs) { Text($0.name).tag($0.uid) }
        }
    }
}

/// Fix-it action for the current state: install the driver, grant access, or test.
private struct PrimaryAction: View {
    @ObservedObject var controller: Controller
    let delegate: AppDelegate

    var body: some View {
        switch controller.phase {
        case .driverMissing:
            Button("Install Audio Driver…") { delegate.installDriver() }
        case .micDenied:
            Button("Allow Microphone Access…") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            }
        default:
            Button("Test Forwarding") { controller.playTestSound() }
        }
    }
}

private struct MenuLabel: View {
    @ObservedObject var controller: Controller

    var body: some View {
        Image(nsImage: DuckArt.menuBarImage(active: controller.phase == .inCall))
    }
}

/// Shown when the Notifications switch is on but macOS blocks them.
private struct NotificationWarning: View {
    @ObservedObject var controller: Controller
    @ObservedObject var notifier = Notifier.shared

    var body: some View {
        if controller.notificationsEnabled && !notifier.allowedBySystem {
            Button("⚠️ Notifications blocked by macOS · Turn On…") { notifier.fixPermission() }
        }
    }
}

private struct MenuContent: View {
    @ObservedObject var controller: Controller
    @ObservedObject var updates: UpdateChecker
    let delegate: AppDelegate

    var body: some View {
        Text(controller.phase.label)
        if !controller.routeDescription.isEmpty {
            Text(controller.routeDescription)
        }
        Divider()

        Toggle("Enable Duckproof", isOn: $controller.enabled)
        CallSettings(controller: controller)
        NotificationWarning(controller: controller)
        Divider()

        PrimaryAction(controller: controller, delegate: delegate)
        Button("Set Up FaceTime…") { delegate.showFaceTimeGuide() }
        Button("Settings…") { delegate.showSettings() }
            .keyboardShortcut(",")
        if let release = updates.available {
            Button("Update Available: Duckproof \(release.version)…") { NSWorkspace.shared.open(release.url) }
        }
        Divider()
        Button("Quit Duckproof") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// Opened by double-clicking Duckproof in Applications, for when the menu bar icon is hidden
/// (notch, Bartender, Hidden Bar…). Closing it keeps Duckproof running in the background.
private struct SettingsView: View {
    @ObservedObject var controller: Controller
    @ObservedObject var updates: UpdateChecker
    let delegate: AppDelegate

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    VStack(alignment: .trailing) {
                        Text(controller.phase.label)
                        if !controller.routeDescription.isEmpty {
                            Text(controller.routeDescription).foregroundStyle(.secondary)
                        }
                    }
                }
                Toggle("Enable Duckproof", isOn: $controller.enabled)
            }
            Section("During Calls") {
                CallSettings(controller: controller)
                HStack {
                    PrimaryAction(controller: controller, delegate: delegate)
                    Button("Set Up FaceTime…") { delegate.showFaceTimeGuide() }
                }
            }
            Section("General") {
                Toggle("Notifications", isOn: $controller.notificationsEnabled)
                NotificationWarning(controller: controller)
                Toggle("Open at Login", isOn: $controller.launchAtLogin)
                LabeledContent("Version \(UpdateChecker.currentVersion)") {
                    if let release = updates.available {
                        Button("Download Duckproof \(release.version)") { NSWorkspace.shared.open(release.url) }
                    } else {
                        Button("Check for Updates") { delegate.checkForUpdates() }
                            .disabled(UpdateChecker.repository == nil)
                    }
                }
            }
            Section {
                HStack {
                    Button("Reinstall Audio Driver…") { delegate.installDriver() }
                    Button("Uninstall Duckproof…") { delegate.uninstall() }
                    Spacer()
                    Button("Quit Duckproof") { NSApp.terminate(nil) }
                }
            } footer: {
                Text("Duckproof lives in the menu bar. Closing this window doesn't quit it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = Controller()
    let updates = UpdateChecker()
    private var settingsWindow: NSWindow?

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdown()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let openedByUser = !launchedAtLogin
        forgetStaleCopies()
        Notifier.shared.requestAuthorization()
        updates.start()
        DispatchQueue.main.async {
            let firstRun = self.onboard()
            // Opened by hand (not at login): show the window, the menu bar icon may be hidden.
            if openedByUser && !firstRun { self.showSettings() }
        }
    }

    /// Double-clicking the app while it's already running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    /// Old copies left in the Trash by updates still answer to our bundle ID, and macOS may pick one of
    /// them when showing our notifications, which then silently disappear. Make macOS forget them and
    /// register this copy instead. Nothing is deleted.
    private func forgetStaleCopies() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let me = Bundle.main.bundleURL.standardizedFileURL
        let copies = LSCopyApplicationURLsForBundleIdentifier(id as CFString, nil)?.takeRetainedValue() as? [URL] ?? []
        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        for copy in copies where copy.standardizedFileURL != me && copy.path.contains("/.Trash/") {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: lsregister)
            task.arguments = ["-u", copy.path]
            try? task.run()
        }
        LSRegisterURL(me as CFURL, true)
    }

    private var launchedAtLogin: Bool {
        let event = NSAppleEventManager.shared().currentAppleEvent
        let loginItem = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        // Login items aren't always flagged as such: a launch right after boot counts too.
        return loginItem || ProcessInfo.processInfo.systemUptime < 180
    }

    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: SettingsView(controller: controller, updates: updates, delegate: self)))
            window.title = "Duckproof"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        Notifier.shared.refresh()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// First launch (or update): driver, access to read the Duckproof device, launch at login, FaceTime setup.
    /// Returns true on the very first run.
    @discardableResult
    private func onboard() -> Bool {
        if DriverManager.needsInstall {
            installDriver(explain: true)
        }

        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = alert(
                "Why does Duckproof need microphone access?",
                """
                To stop FaceTime from lowering your other apps, Duckproof gives it its own virtual \
                audio channel to play into. Duckproof then reads that channel and sends it to your \
                headphones. macOS counts reading any audio channel as "using the microphone", \
                even a virtual one, hence the permission.

                Duckproof never listens to your real microphone. The orange indicator only appears during calls.
                """,
                buttons: ["Continue"])
        }
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            DispatchQueue.main.async { self.controller.evaluate() }
        }

        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "onboarded") else { return false }
        defaults.set(true, forKey: "onboarded")
        controller.launchAtLogin = true
        showFaceTimeGuide()
        return true
    }

    func installDriver(explain: Bool = false) {
        if explain {
            let proceed = alert(
                "Duckproof needs to install its audio device",
                "It's a small virtual audio driver (based on BlackHole) that FaceTime will play into. macOS will ask for your password. Audio cuts out for a second during install; no restart needed.",
                buttons: ["Install", "Later"])
            guard proceed else { return }
        }
        do {
            try DriverManager.install()
        } catch DriverManager.Failure.cancelled {
            // The user dismissed the password prompt.
        } catch {
            _ = alert("Couldn't install the audio driver", error.localizedDescription, buttons: ["OK"])
        }
        controller.evaluate()
    }

    func showFaceTimeGuide() {
        let openFaceTime = alert(
            "Last step: set up FaceTime (once)",
            "In FaceTime, open the Video menu in the menu bar and choose Audio Output › Duckproof.\n\nFaceTime then plays into Duckproof, which forwards it to your headphones without macOS lowering other apps.\n\nAudio sounds muffled or like a phone call? You're probably using your headphones' microphone over Bluetooth. When an app uses the mic of Bluetooth headphones (AirPods included), they have to switch to a \"headset\" mode that uses a low-quality codec, and all your audio goes mono and compressed, not just the call.\n\nFix: in FaceTime, open the Video menu › Microphone and pick another mic, such as your Mac's built-in microphone or your iPhone. Your headphones then stay in high-quality mode. FaceTime remembers this choice.",
            buttons: ["Open FaceTime", "Later"])
        if openFaceTime, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Controller.faceTimeBundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    func checkForUpdates() {
        updates.check { result in
            switch result {
            case .success(let release?):
                if self.alert(L("Duckproof %@ is available", release.version),
                              L("You have version %@.", UpdateChecker.currentVersion), buttons: ["Download", "Later"]) {
                    NSWorkspace.shared.open(release.url)
                }
            case .success(nil):
                _ = self.alert("You're up to date", L("Duckproof %@ is the latest version.", UpdateChecker.currentVersion), buttons: ["OK"])
            case .failure(let error):
                _ = self.alert("Couldn't check for updates", error.localizedDescription, buttons: ["OK"])
            }
        }
    }

    func uninstall() {
        guard alert("Uninstall Duckproof?",
                    "Duckproof, its audio driver and its settings will be removed (password required). Remember to switch FaceTime's audio output back to your headphones.",
                    buttons: ["Uninstall", "Cancel"]) else { return }
        let openedAtLogin = controller.launchAtLogin
        controller.launchAtLogin = false
        controller.stopForUninstall()
        do {
            try DriverManager.uninstall()
        } catch {
            if case DriverManager.Failure.cancelled = error {} else {
                _ = alert("Uninstall incomplete", error.localizedDescription, buttons: ["OK"])
            }
            // Nothing was removed: put things back and relaunch fresh (all listeners were dropped).
            controller.launchAtLogin = openedAtLogin
            let relaunch = Process()
            relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
            relaunch.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundleURL.path]
            try? relaunch.run()
            NSApp.terminate(nil)
            return
        }
        UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier ?? "app.duckproof.Duckproof")
        _ = alert("Duckproof is uninstalled", "Thanks for trying it! 🦆", buttons: ["OK"])
        NSApp.terminate(nil)
    }

    /// Returns true if the first button was chosen.
    private func alert(_ title: String, _ message: String, buttons: [String]) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L(title)
        alert.informativeText = L(message)
        buttons.forEach { alert.addButton(withTitle: L($0)) }
        return alert.runModal() == .alertFirstButtonReturn
    }
}
