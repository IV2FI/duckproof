import AppKit

/// Installs / updates / removes the virtual audio driver bundled inside the app.
/// No Mac restart needed: relaunching coreaudiod is enough to load the driver.
enum DriverManager {
    static let installedURL = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL/Duckproof.driver")
    static var bundledURL: URL? { Bundle.main.url(forResource: "Duckproof", withExtension: "driver") }

    enum Failure: LocalizedError {
        case cancelled
        case script(String)
        case deviceNotLoaded

        var errorDescription: String? {
            switch self {
            case .cancelled: return L("Installation cancelled.")
            case .script(let message): return L(message)
            case .deviceNotLoaded: return L("The driver is installed but macOS hasn't loaded it yet. Restart your Mac if this persists.")
            }
        }
    }

    private static func version(at url: URL) -> String? {
        NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))?["CFBundleVersion"] as? String
    }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: installedURL.path) }

    /// Missing, or older than the one shipped with this version of the app.
    static var needsInstall: Bool {
        guard let bundled = bundledURL else { return false }
        return !isInstalled || version(at: installedURL) != version(at: bundled)
    }

    static var isDeviceLoaded: Bool { AudioSystem.device(uid: duckproofDeviceUID) != nil }

    static func install() throws {
        guard let source = bundledURL else { throw Failure.script("Driver not found inside the app.") }
        let destination = shellQuote(installedURL.path)
        try runAsAdministrator("""
            /bin/rm -rf \(destination) /Library/Audio/Plug-Ins/HAL/Unduck.driver && \
            /bin/mkdir -p /Library/Audio/Plug-Ins/HAL && \
            /usr/bin/ditto \(shellQuote(source.path)) \(destination) && \
            /usr/sbin/chown -R root:wheel \(destination) && \
            /usr/bin/killall coreaudiod
            """, prompt: L("Duckproof is installing its virtual audio device."))
        try waitForDevice(present: true)
    }

    /// Removes the driver, the app itself and the install receipt in one password prompt, then waits
    /// for Core Audio to be back so the app never talks to it mid-restart.
    static func uninstall() throws {
        let app = Bundle.main.bundleURL.path
        try runAsAdministrator("""
            /bin/rm -rf \(shellQuote(installedURL.path)) /Library/Audio/Plug-Ins/HAL/Unduck.driver \(shellQuote(app)); \
            /usr/sbin/pkgutil --forget app.duckproof.Duckproof.pkg >/dev/null 2>&1; \
            /usr/bin/killall coreaudiod; \
            for i in $(/usr/bin/seq 1 30); do /usr/sbin/system_profiler SPAudioDataType >/dev/null 2>&1 && break; /bin/sleep 0.5; done
            """, prompt: L("Duckproof is removing its virtual audio device."))
        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        let task = Process(); task.executableURL = URL(fileURLWithPath: lsregister); task.arguments = ["-u", app]
        try? task.run()
    }

    /// coreaudiod takes a second or two to come back after being relaunched.
    private static func waitForDevice(present: Bool) throws {
        for _ in 0..<40 {
            if isDeviceLoaded == present { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        throw Failure.deviceNotLoaded
    }

    private static func runAsAdministrator(_ command: String, prompt: String) throws {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with prompt \"\(prompt)\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard let error else { return }
        if (error[NSAppleScript.errorNumber] as? Int) == -128 { throw Failure.cancelled }
        throw Failure.script(error[NSAppleScript.errorMessage] as? String ?? "Unknown error.")
    }

    private static func shellQuote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
