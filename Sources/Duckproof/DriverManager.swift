import AppKit
import Security

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

    /// The driver is copied from the app bundle, which a user may own: something could swap it just
    /// before the copy. So the *installed* copy (root-owned, nobody else can write it) is checked
    /// before Core Audio loads it: it must be signed by the same team as this app, or, for builds
    /// from source (ad hoc), at least intact. Otherwise it is deleted.
    static func install() throws {
        guard let source = bundledURL else { throw Failure.script("Driver not found inside the app.") }
        let destination = shellQuote(installedURL.path)
        let verify = teamRequirement.map { "/usr/bin/codesign --verify --strict -R=\(shellQuote($0)) \(destination)" }
            ?? "/usr/bin/codesign --verify --strict \(destination)"
        try runAsAdministrator("""
            /bin/rm -rf \(destination); \(removeLegacyDriver); \
            /bin/mkdir -p /Library/Audio/Plug-Ins/HAL && \
            /usr/bin/ditto \(shellQuote(source.path)) \(destination) && \
            /usr/sbin/chown -R root:wheel \(destination) && \
            /bin/chmod -R go-w \(destination) && \
            { \(verify) || { /bin/rm -rf \(destination); echo "The audio driver's signature is invalid." >&2; exit 1; }; } && \
            /usr/bin/killall coreaudiod
            """, prompt: L("Duckproof is installing its virtual audio device."))
        try waitForDevice(present: true)
    }

    /// "Signed by the same Apple developer team as this app", or nil for an ad-hoc build.
    private static var teamRequirement: String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String else { return nil }
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }

    /// Duckproof used to be called Unduck: remove its driver, but only if it really is ours.
    private static let removeLegacyDriver = """
        [ "$(/usr/bin/defaults read /Library/Audio/Plug-Ins/HAL/Unduck.driver/Contents/Info CFBundleIdentifier 2>/dev/null)" = app.unduck.driver ] \
        && /bin/rm -rf /Library/Audio/Plug-Ins/HAL/Unduck.driver
        """

    /// Removes the driver, the app itself and the install receipt in one password prompt, then waits
    /// for Core Audio to be back so the app never talks to it mid-restart.
    static func uninstall() throws {
        let app = Bundle.main.bundleURL.path
        try runAsAdministrator("""
            /bin/rm -rf \(shellQuote(installedURL.path)) \(shellQuote(app)); \(removeLegacyDriver); \
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
