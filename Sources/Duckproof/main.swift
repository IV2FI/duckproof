import UserNotifications
import Foundation

// `Duckproof --diagnose`: the Mac's audio state, handy for debugging on someone else's machine.
if CommandLine.arguments.contains("--diagnose") {
    let defaultInput = AudioSystem.defaultDevice(input: true)?.uid
    let defaultOutput = AudioSystem.defaultDevice(input: false)?.uid
    print("Driver installed: \(DriverManager.isInstalled) · loaded: \(DriverManager.isDeviceLoaded)\n")
    print("Devices:")
    for device in AudioSystem.devices() {
        let flags = [device.hasInput ? "input" : nil, device.hasOutput ? "output" : nil,
                     device.isBuiltIn ? "built-in" : nil, device.isBluetooth ? "bluetooth" : nil,
                     device.uid == defaultInput ? "DEFAULT INPUT" : nil,
                     device.uid == defaultOutput ? "DEFAULT OUTPUT" : nil].compactMap { $0 }
        print("  [\(device.id)] \(device.name) — \(device.uid) (\(flags.joined(separator: ", ")))")
    }
    print("\nAudio processes:")
    for process in AudioSystem.processes() {
        let state = [process.isRunningInput ? "recording" : nil, process.isRunningOutput ? "playing" : nil].compactMap { $0 }
        print("  \(process.pid) \(process.bundleID.isEmpty ? "?" : process.bundleID) \(state.joined(separator: "+")) "
              + "in:\(process.inputDevices) out:\(process.outputDevices)")
    }
    exit(0)
}

// `Duckproof --notify-test`: what macOS has recorded for Duckproof's notifications, then a test banner.
if CommandLine.arguments.contains("--notify-test") {
    let center = UNUserNotificationCenter.current()
    let done = DispatchSemaphore(value: 0)
    center.getNotificationSettings { s in
        func name(_ v: UNNotificationSetting) -> String { [0: "not supported", 1: "OFF", 2: "on"][v.rawValue] ?? "?" }
        let auth = [0: "not determined", 1: "DENIED", 2: "authorized", 3: "provisional"][s.authorizationStatus.rawValue] ?? "?"
        let style = [0: "NONE", 1: "banners", 2: "alerts"][s.alertStyle.rawValue] ?? "?"
        print("authorization: \(auth)\nalert style: \(style)\nalerts: \(name(s.alertSetting))\n"
              + "notification center: \(name(s.notificationCenterSetting))\nsound: \(name(s.soundSetting))\n"
              + "lock screen: \(name(s.lockScreenSetting))")
        let content = UNMutableNotificationContent()
        content.title = "Duckproof"; content.body = "Test notification 🦆"; content.sound = .default
        center.add(UNNotificationRequest(identifier: "duckproof.test", content: content, trigger: nil)) { error in
            print(error.map { "post failed: \($0)" } ?? "test notification posted")
            done.signal()
        }
    }
    done.wait()
    Thread.sleep(forTimeInterval: 1)
    exit(0)
}

DuckproofApp.main()
