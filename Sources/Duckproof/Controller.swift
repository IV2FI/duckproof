import AppKit
import AVFoundation
import ServiceManagement
import DuckproofAudio

/// Orchestration: while FaceTime plays into the Duckproof driver, copy that audio to the chosen
/// output device. FaceTime no longer plays on the headphones, so macOS no longer ducks other apps there.
final class Controller: ObservableObject {
    enum Phase: Equatable {
        case driverMissing, micDenied, disabled, waiting, ready, inCall
        case failed(String)
    }

    static let faceTimeBundleID = "com.apple.FaceTime"
    /// Processes that carry the audio of a FaceTime / phone call.
    private static let callBundleIDs: Set<String> = ["com.apple.FaceTime", "com.apple.avconferenced"]

    @Published private(set) var phase: Phase = .waiting
    @Published private(set) var outputs: [AudioDevice] = []
    @Published private(set) var systemOutputName = ""
    @Published private(set) var routeDescription = ""

    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "enabled"); evaluate() } }
    /// UID of the output FaceTime is forwarded to; empty = follow the system output.
    @Published var outputUID: String { didSet { defaults.set(outputUID, forKey: "outputUID"); evaluate() } }
    /// Extra volume for FaceTime: without ducking, other apps stay loud and calls can feel quiet.
    @Published var faceTimeGain: Double {
        didSet { defaults.set(faceTimeGain, forKey: "faceTimeGain"); updateGain() }
    }
    /// How much other apps are lowered during a call, in dB. 0 (the default) = no ducking at all.
    @Published var duckingDB: Double {
        didSet { defaults.set(duckingDB, forKey: "duckingDB"); releaseDucking(); evaluate() }
    }
    @Published var notificationsEnabled: Bool { didSet { defaults.set(notificationsEnabled, forKey: "notifications") } }
    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Duckproof: launch at login: \(error)")
            }
        }
    }

    private let defaults = UserDefaults.standard
    private let passthrough = ud_passthrough_create()!
    private var route: (input: AudioObjectID, output: AudioObjectID, rate: Double)?
    private var faceTimeRunning = false
    private var forcedUntil: Date?
    private var callStarted = false
    private var warnedThisCall = Set<String>()
    private var listeners: [AudioSystem.Listener] = []
    private var duckproofListeners: [AudioSystem.Listener] = []
    private var duckproofID: AudioObjectID = 0
    private var pollTimer: Timer?

    /// Our own ducking while a call is on: the output volume is lowered by `db` (negative)
    /// and FaceTime is boosted by the same amount, so only the other apps get quieter.
    /// Persisted so the volume can be put back even if Duckproof quits mid-call.
    private var appliedDuck: (device: AudioObjectID, uid: String, db: Float32)? {
        didSet {
            defaults.set(appliedDuck?.uid, forKey: "pendingDuckUID")
            defaults.set(appliedDuck.map { Double($0.db) }, forKey: "pendingDuckDB")
            updateGain()
        }
    }

    init() {
        defaults.register(defaults: ["enabled": true, "notifications": true, "outputUID": "", "faceTimeGain": 1.0, "duckingDB": 0.0])
        enabled = defaults.bool(forKey: "enabled")
        outputUID = defaults.string(forKey: "outputUID") ?? ""
        notificationsEnabled = defaults.bool(forKey: "notifications")
        faceTimeGain = defaults.double(forKey: "faceTimeGain")
        duckingDB = defaults.double(forKey: "duckingDB")
        launchAtLogin = SMAppService.mainApp.status == .enabled
        updateGain()

        // Duckproof quit during a call last time: give the volume back.
        if let uid = defaults.string(forKey: "pendingDuckUID"), let device = AudioSystem.device(uid: uid) {
            AudioSystem.adjustVolume(device.id, byDB: -Float32(defaults.double(forKey: "pendingDuckDB")))
        }
        defaults.removeObject(forKey: "pendingDuckUID")
        defaults.removeObject(forKey: "pendingDuckDB")

        let system = AudioObjectID(kAudioObjectSystemObject)
        listeners = [
            AudioSystem.listen(kAudioHardwarePropertyDevices, on: system) { [weak self] in self?.evaluate() },
            AudioSystem.listen(kAudioHardwarePropertyDefaultOutputDevice, on: system) { [weak self] in self?.evaluate() },
        ]

        let workspace = NSWorkspace.shared
        faceTimeRunning = workspace.runningApplications.contains { $0.bundleIdentifier == Self.faceTimeBundleID }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspace.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == Self.faceTimeBundleID else { return }
                self?.faceTimeRunning = name == NSWorkspace.didLaunchApplicationNotification
                self?.evaluate()
            }
        }
        evaluate()
    }

    deinit {
        ud_passthrough_destroy(passthrough)
    }

    // MARK: Main logic

    func evaluate() {
        refreshDevices()

        guard let duckproof = AudioSystem.device(uid: duckproofDeviceUID) else {
            stopRouting()
            phase = .driverMissing
            return
        }
        watchDuckproof(duckproof.id)

        guard enabled else {
            stopRouting()
            phase = .disabled
            return
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .denied {
            stopRouting()
            phase = .micDenied
            return
        }

        let me = getpid()
        let processes = AudioSystem.processes().filter { $0.pid != me }
        let feeders = processes.filter { $0.isRunningOutput && $0.outputDevices.contains(duckproof.id) }
        let feedingDuckproof = !feeders.isEmpty
        let forced = forcedUntil.map { $0 > Date() } ?? false

        guard faceTimeRunning || feedingDuckproof || forced else {
            stopRouting()
            stopPolling()
            endCall()
            phase = .waiting
            return
        }

        if faceTimeRunning { startPolling() }
        // Only read Duckproof while something actually plays into it: reading an input device
        // turns on the orange mic indicator, which should not stay lit while FaceTime idles.
        if feedingDuckproof || forced {
            if let failure = startRouting(from: duckproof) {
                phase = .failed(failure)
                return
            }
        } else {
            stopRouting()
        }

        let callProcesses = processes.filter { Self.callBundleIDs.contains($0.bundleID) }
        let inCall = feedingDuckproof || callProcesses.contains { $0.isRunningInput }
        if inCall {
            if feedingDuckproof { applyDucking() }
            beginCall(feeder: feeders.first, callProcesses: callProcesses)
            phase = .inCall
        } else {
            endCall()
            phase = .ready
        }
    }

    /// Plays a sound into Duckproof to check the forwarding without making a call.
    func playTestSound() {
        forcedUntil = Date().addingTimeInterval(3)
        evaluate()
        let sound = NSSound(named: "Glass")
        sound?.playbackDeviceIdentifier = duckproofDeviceUID
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { sound?.play() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) { [weak self] in self?.evaluate() }
    }

    // MARK: Forwarding

    private func targetOutput() -> AudioDevice? {
        let usable = outputs
        if !outputUID.isEmpty, let chosen = usable.first(where: { $0.uid == outputUID }) { return chosen }
        if let system = AudioSystem.defaultDevice(input: false), system.isUserFacing { return system }
        return usable.first { $0.isBuiltIn } ?? usable.first   // never Duckproof into itself
    }

    private func startRouting(from duckproof: AudioDevice) -> String? {
        guard let output = targetOutput() else { return "No audio output available" }
        let rate = AudioSystem.get(duckproof.id, kAudioDevicePropertyNominalSampleRate, default: Float64(48000))
        if let route, route.input == duckproof.id, route.output == output.id, route.rate == rate { return nil }

        let status = ud_passthrough_start(passthrough, duckproof.id, output.id)
        guard status == noErr else {
            route = nil
            return "Can't open \(output.name) (error \(status))"
        }
        route = (duckproof.id, output.id, rate)
        updateGain()
        routeDescription = "Call audio → \(output.name)"
        startPolling()
        return nil
    }

    private func stopRouting() {
        releaseDucking()
        guard route != nil else { return }
        ud_passthrough_stop(passthrough)
        route = nil
        routeDescription = ""
    }

    // MARK: Gentle ducking

    private func applyDucking() {
        guard appliedDuck == nil, duckingDB > 0,
              let device = AudioSystem.defaultDevice(input: false), device.isUserFacing else { return }
        let applied = AudioSystem.adjustVolume(device.id, byDB: -Float32(duckingDB))
        if applied < 0 { appliedDuck = (device.id, device.uid, applied) }
    }

    /// Raises the volume back by what we took, relative to wherever the user has set it since.
    private func releaseDucking() {
        guard let duck = appliedDuck else { return }
        appliedDuck = nil
        AudioSystem.adjustVolume(duck.device, byDB: -duck.db)
    }

    private func updateGain() {
        var gain = faceTimeGain
        // FaceTime shares the lowered device with the other apps: compensate so it stays put.
        if let duck = appliedDuck, duck.device == route?.output { gain *= pow(10, Double(-duck.db) / 20) }
        ud_passthrough_set_gain(passthrough, Float(gain))
    }

    func shutdown() {
        releaseDucking()
        stopRouting()
    }

    // MARK: Ongoing call

    /// FaceTime calls run in avconferenced; any other app playing into Duckproof is named after itself.
    private func appName(_ process: AudioProcess) -> String {
        if Self.callBundleIDs.contains(process.bundleID) { return "FaceTime" }
        return NSRunningApplication(processIdentifier: process.pid)?.localizedName ?? process.bundleID
    }

    private func beginCall(feeder: AudioProcess?, callProcesses: [AudioProcess]) {
        let feedingDuckproof = feeder != nil
        if !callStarted {
            callStarted = true
            if let feeder {
                let others = appliedDuck.map { String(format: "other apps %.0f dB", $0.db) } ?? "other apps at full volume"
                notify("Call without ducking 🦆", "\(appName(feeder)) audio → \(targetOutput()?.name ?? "—") · \(others)", key: "start")
            }
        }

        // FaceTime isn't playing into Duckproof: it will duck other apps.
        let faceTimeOutputs = callProcesses.filter(\.isRunningOutput)
        if !feedingDuckproof, !faceTimeOutputs.isEmpty {
            notify("FaceTime isn't using Duckproof",
                   "In FaceTime: Video menu › Audio Output › Duckproof. Otherwise other apps will get quieter.",
                   key: "output")
        }
    }

    private func endCall() {
        releaseDucking()
        callStarted = false
        warnedThisCall.removeAll()
    }

    private func notify(_ title: String, _ body: String, key: String) {
        guard notificationsEnabled, warnedThisCall.insert(key).inserted else { return }
        Notifier.shared.post(title, body, id: "duckproof.\(key)")
    }

    // MARK: Monitoring

    private func refreshDevices() {
        outputs = AudioSystem.devices().filter { $0.isUserFacing && $0.hasOutput }
        systemOutputName = AudioSystem.defaultDevice(input: false)?.name ?? ""
    }

    /// React immediately when something starts playing into Duckproof, or its sample rate changes.
    private func watchDuckproof(_ id: AudioObjectID) {
        guard id != duckproofID else { return }
        duckproofID = id
        duckproofListeners = [
            AudioSystem.listen(kAudioDevicePropertyDeviceIsRunningSomewhere, on: id) { [weak self] in self?.evaluate() },
            AudioSystem.listen(kAudioDevicePropertyNominalSampleRate, on: id) { [weak self] in self?.evaluate() },
        ]
    }

    /// While FaceTime is open, check every second whether a call has started.
    private func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.evaluate() }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: Diagnostics

    var underruns: UInt64 { ud_passthrough_underruns(passthrough) }
}
