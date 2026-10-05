import AppKit
import AVFoundation
import ServiceManagement
import UserNotifications
import DuckproofAudio

/// Orchestration: while FaceTime plays into the Duckproof driver, copy that audio to the chosen
/// output device. FaceTime no longer plays on the headphones, so macOS no longer ducks other apps there.
final class Controller: ObservableObject {
    enum Phase: Equatable {
        case driverMissing, micDenied, disabled, waiting, ready, inCall
        case failed(String)
    }

    static let faceTimeBundleID = "com.apple.FaceTime"
    /// Apps that duck everything else during a call, matched by bundle ID prefix, with where to pick Duckproof.
    /// FaceTime calls run in avconferenced.
    private struct CallApp { let prefix: String; let name: String; let hint: String }
    private static let callApps = [
        CallApp(prefix: "com.apple.avconferenced", name: "FaceTime", hint: "In FaceTime: Video menu › Audio Output › Duckproof."),
        CallApp(prefix: "com.apple.FaceTime", name: "FaceTime", hint: "In FaceTime: Video menu › Audio Output › Duckproof."),
        CallApp(prefix: "us.zoom.", name: "Zoom", hint: "In Zoom: Settings › Audio › Speaker › Duckproof."),
        CallApp(prefix: "com.microsoft.teams", name: "Microsoft Teams", hint: "In Teams: Settings › Devices › Speaker › Duckproof."),
        CallApp(prefix: "com.hnc.Discord", name: "Discord", hint: "In Discord: User Settings › Voice & Video › Output Device › Duckproof."),
        CallApp(prefix: "com.tinyspeck.slackmacgap", name: "Slack", hint: "In your Slack huddle: Settings › Speaker › Duckproof."),
        CallApp(prefix: "net.whatsapp.WhatsApp", name: "WhatsApp", hint: "In WhatsApp's call settings, choose Duckproof as the speaker."),
        CallApp(prefix: "Cisco-Systems.Spark", name: "Webex", hint: "In Webex: Settings › Audio › Speaker › Duckproof."),
        CallApp(prefix: "com.google.Chrome", name: "your browser call", hint: "In the call's audio settings (Google Meet: Settings › Audio › Speakers), choose Duckproof."),
        CallApp(prefix: "com.microsoft.edgemac", name: "your browser call", hint: "In the call's audio settings (Google Meet: Settings › Audio › Speakers), choose Duckproof."),
        CallApp(prefix: "company.thebrowser.Browser", name: "your browser call", hint: "In the call's audio settings (Google Meet: Settings › Audio › Speakers), choose Duckproof."),
        CallApp(prefix: "com.brave.Browser", name: "your browser call", hint: "In the call's audio settings (Google Meet: Settings › Audio › Speakers), choose Duckproof."),
    ]
    private static func callApp(_ bundleID: String) -> CallApp? { callApps.first { bundleID.hasPrefix($0.prefix) } }

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
    @Published var notificationsEnabled: Bool {
        didSet {
            defaults.set(notificationsEnabled, forKey: "notifications")
            if notificationsEnabled { Notifier.shared.requestAuthorization() }
        }
    }
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
    private var warnedThisCall = Set<String>()
    /// Call apps already told to use Duckproof, until their call ends.
    private var warnedApps = Set<String>()
    private var listeners: [AudioSystem.Listener] = []
    private var duckproofListeners: [AudioSystem.Listener] = []
    private var duckproofID: AudioObjectID = 0
    /// No polling, ever: macOS tells us when a mic starts or stops (every call uses one), when an app
    /// starts using audio, when a call app changes output, and when something starts or stops playing
    /// into the Duckproof output (we read its hidden twin, so only the call app keeps it running).
    private var micListeners: [AudioObjectID: AudioSystem.Listener] = [:]
    private var processListeners: [AudioObjectID: [AudioSystem.Listener]] = [:]
    private var followUp: DispatchWorkItem?

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
            AudioSystem.listen(kAudioHardwarePropertyProcessObjectList, on: system) { [weak self] in self?.changed() },
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
        defer { updateWatchers() }
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
        checkCallApps(processes, duckproof: duckproof.id)

        guard faceTimeRunning || feedingDuckproof || forced else {
            stopRouting()
            endCall()
            phase = .waiting
            return
        }

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

        let callProcesses = processes.filter { Self.callApp($0.bundleID)?.name == "FaceTime" }
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
        // The duck from the launch film, so the test sounds like Duckproof.
        let sound = Bundle.main.url(forResource: "Quack", withExtension: "wav")
            .flatMap { NSSound(contentsOf: $0, byReference: true) } ?? NSSound(named: "Glass")
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
        guard let output = targetOutput() else { return L("No audio output available") }
        // Read the hidden input-only twin: it receives whatever is played into the visible output.
        guard let reader = AudioSystem.deviceID(uid: duckproofReaderUID) else { return L("⚠️ Audio driver not installed") }
        let rate = AudioSystem.get(reader, kAudioDevicePropertyNominalSampleRate, default: Float64(48000))
        if let route, route.input == reader, route.output == output.id, route.rate == rate { return nil }

        let status = ud_passthrough_start(passthrough, reader, output.id)
        guard status == noErr else {
            route = nil
            return L("Can't open %@ (error %d)", output.name, Int(status))
        }
        route = (reader, output.id, rate)
        updateGain()
        routeDescription = L("Call audio → %@", output.name)
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
        if let app = Self.callApp(process.bundleID), app.name == "FaceTime" { return app.name }
        return NSRunningApplication(processIdentifier: process.pid)?.localizedName ?? process.bundleID
    }

    /// Announced once per call, when the call audio actually reaches Duckproof: apps open the mic
    /// a moment before they start playing, so the call is often detected before there is a feeder.
    private func beginCall(feeder: AudioProcess?, callProcesses: [AudioProcess]) {
        guard let feeder else { return }
        let others = appliedDuck.map { L("other apps %d dB", Int($0.db.rounded())) } ?? L("other apps at full volume")
        notify(L("Call without ducking 🦆"), L("%@ audio → %@ · %@", appName(feeder), targetOutput()?.name ?? "—", others),
               key: "start", sound: Notifier.quack)
    }

    /// A call app that records and plays at the same time is in a call. If it plays anywhere but
    /// Duckproof, macOS will duck everything else: say once per call where to change it.
    private func checkCallApps(_ processes: [AudioProcess], duckproof: AudioObjectID) {
        var inCall = Set<String>()
        for process in processes where process.isRunningInput && process.isRunningOutput {
            guard let app = Self.callApp(process.bundleID) else { continue }
            inCall.insert(app.name)
            if process.outputDevices.contains(duckproof) || process.outputDevices.isEmpty { continue }
            guard notificationsEnabled, enabled, !warnedApps.contains(app.name) else { continue }
            warnedApps.insert(app.name)
            let name = L(app.name)
            Notifier.shared.post(L("%@ is lowering your other apps", name.prefix(1).uppercased() + name.dropFirst()),
                                 L(app.hint), id: "duckproof.output.\(app.name)", sound: .default)
        }
        warnedApps.formIntersection(inCall)
    }

    private func endCall() {
        releaseDucking()
        warnedThisCall.removeAll()
    }

    private func notify(_ title: String, _ body: String, key: String, sound: UNNotificationSound? = nil) {
        guard notificationsEnabled, warnedThisCall.insert(key).inserted else { return }
        Notifier.shared.post(title, body, id: "duckproof.\(key)", sound: sound)
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
            AudioSystem.listen(kAudioDevicePropertyDeviceIsRunningSomewhere, on: id) { [weak self] in self?.changed() },
            AudioSystem.listen(kAudioDevicePropertyNominalSampleRate, on: id) { [weak self] in self?.evaluate() },
        ]
    }

    /// Something changed: check now, and once more 2 s later (apps often open the mic before their output).
    private func changed() {
        evaluate()
        followUp?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.evaluate() }
        followUp = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    /// Keeps the event listeners in sync with the mics and call apps currently present.
    private func updateWatchers() {
        let mics = AudioSystem.devices().filter { $0.hasInput && !$0.isDuckproof }
        for mic in mics where micListeners[mic.id] == nil {
            micListeners[mic.id] = AudioSystem.listen(kAudioDevicePropertyDeviceIsRunningSomewhere, on: mic.id) { [weak self] in self?.changed() }
        }
        let liveMics = Set(mics.map(\.id))
        micListeners = micListeners.filter { liveMics.contains($0.key) }

        // Call apps: macOS doesn't notify "is running" changes, but it does notify the list of devices a
        // process uses, which changes whenever it starts, stops or switches its output or input.
        let callProcesses = AudioSystem.processObjects().filter { $0.pid != getpid() && Self.callApp($0.bundleID) != nil }
        for process in callProcesses where processListeners[process.id] == nil {
            processListeners[process.id] = [kAudioObjectPropertyScopeOutput, kAudioObjectPropertyScopeInput].map { scope in
                AudioSystem.listen(kAudioProcessPropertyDevices, on: process.id, scope: scope) { [weak self] in self?.changed() }
            }
        }
        let liveProcesses = Set(callProcesses.map(\.id))
        processListeners = processListeners.filter { liveProcesses.contains($0.key) }
    }

    // MARK: Diagnostics

    var underruns: UInt64 { ud_passthrough_underruns(passthrough) }
}
