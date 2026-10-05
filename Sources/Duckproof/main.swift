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

DuckproofApp.main()
