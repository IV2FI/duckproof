import AudioToolbox
import CoreAudio
import Foundation

/// UID of the virtual device created by our driver (see scripts/build-driver.sh).
let unduckDeviceUID = "Unduck_UID"

struct AudioDevice: Identifiable, Hashable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let hasInput: Bool
    let hasOutput: Bool
    let transport: UInt32

    var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }
    var isBluetooth: Bool { transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE }
    var isUnduck: Bool { uid == unduckDeviceUID }
    /// Devices not to offer: ours, private aggregates, and other routing tools' devices.
    var isUserFacing: Bool { !isUnduck && transport != kAudioDeviceTransportTypeAggregate && !uid.hasPrefix("BlackHole") && !uid.hasPrefix("BGM") }
}

struct AudioProcess {
    let pid: pid_t
    let bundleID: String
    let isRunningInput: Bool
    let isRunningOutput: Bool
    let inputDevices: [AudioObjectID]
    let outputDevices: [AudioObjectID]
}

/// Thin layer over the Core Audio C API.
enum AudioSystem {
    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, default value: T) -> T {
        var address = address(selector, scope)
        var result = value
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &result) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        return status == noErr ? result : value
    }

    static func getString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String? {
        var address = address(selector, scope)
        var result: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr,
              let string = result?.takeRetainedValue() else { return nil }
        return string as String
    }

    static func getArray(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var address = address(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func hasStreams(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool {
        !getArray(device, kAudioDevicePropertyStreams, scope: scope).isEmpty
    }

    // MARK: Devices

    static func devices() -> [AudioDevice] {
        getArray(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices).compactMap(device)
    }

    static func device(_ id: AudioObjectID) -> AudioDevice? {
        guard let uid = getString(id, kAudioDevicePropertyDeviceUID) else { return nil }
        return AudioDevice(
            id: id,
            uid: uid,
            name: getString(id, kAudioObjectPropertyName) ?? uid,
            hasInput: hasStreams(id, scope: kAudioObjectPropertyScopeInput),
            hasOutput: hasStreams(id, scope: kAudioObjectPropertyScopeOutput),
            transport: get(id, kAudioDevicePropertyTransportType, default: UInt32(0))
        )
    }

    static func device(uid: String) -> AudioDevice? {
        devices().first { $0.uid == uid }
    }

    static func defaultDevice(input: Bool) -> AudioDevice? {
        let selector = input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice
        return device(get(AudioObjectID(kAudioObjectSystemObject), selector, default: AudioObjectID(0)))
    }

    @discardableResult
    static func setDefaultDevice(_ device: AudioObjectID, input: Bool) -> Bool {
        let selector = input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice
        var address = address(selector)
        var id = device
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                          UInt32(MemoryLayout<AudioObjectID>.size), &id) == noErr
    }

    // MARK: Volume

    private static func volumeScalar(_ device: AudioObjectID) -> Float32? {
        var address = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyScopeOutput)
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioHardwareServiceGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func setVolumeScalar(_ device: AudioObjectID, _ value: Float32) {
        var address = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyScopeOutput)
        var value = value
        AudioHardwareServiceSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }

    /// Scalar ↔ dB conversion along the device's own volume curve (main element, else channel 1).
    private static func translate(_ device: AudioObjectID, _ value: Float32, _ selector: AudioObjectPropertySelector) -> Float32? {
        for element in [kAudioObjectPropertyElementMain, 1] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeOutput, mElement: element)
            var result = value
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &result) == noErr { return result }
        }
        return nil
    }

    /// Moves the output volume by `delta` dB and returns the change actually applied
    /// (smaller when the volume hits its minimum or maximum, 0 without a volume control).
    @discardableResult
    static func adjustVolume(_ device: AudioObjectID, byDB delta: Float32) -> Float32 {
        guard let scalar = volumeScalar(device) else { return 0 }
        let clamp = { (value: Float32) in min(max(value, 0), 1) }
        if let current = translate(device, scalar, kAudioDevicePropertyVolumeScalarToDecibels),
           let target = translate(device, current + delta, kAudioDevicePropertyVolumeDecibelsToScalar) {
            let newScalar = clamp(target)
            setVolumeScalar(device, newScalar)
            return (translate(device, newScalar, kAudioDevicePropertyVolumeScalarToDecibels) ?? current + delta) - current
        }
        // No dB curve published: treat the slider as roughly linear over 64 dB.
        let newScalar = clamp(scalar + delta / 64)
        setVolumeScalar(device, newScalar)
        return (newScalar - scalar) * 64
    }

    // MARK: Processes (macOS 14+): who records or plays on which device

    static func processes() -> [AudioProcess] {
        getArray(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList).map { object in
            AudioProcess(
                pid: get(object, kAudioProcessPropertyPID, default: pid_t(-1)),
                bundleID: getString(object, kAudioProcessPropertyBundleID) ?? "",
                isRunningInput: get(object, kAudioProcessPropertyIsRunningInput, default: UInt32(0)) != 0,
                isRunningOutput: get(object, kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) != 0,
                inputDevices: getArray(object, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput),
                outputDevices: getArray(object, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput)
            )
        }
    }

    // MARK: Listeners

    final class Listener {
        private let object: AudioObjectID
        private var address: AudioObjectPropertyAddress
        private let block: AudioObjectPropertyListenerBlock

        init(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, handler: @escaping () -> Void) {
            self.object = object
            self.address = AudioSystem.address(selector)
            self.block = { _, _ in DispatchQueue.main.async(execute: handler) }
            AudioObjectAddPropertyListenerBlock(object, &address, nil, block)
        }

        deinit {
            AudioObjectRemovePropertyListenerBlock(object, &address, nil, block)
        }
    }

    static func listen(_ selector: AudioObjectPropertySelector, on object: AudioObjectID = AudioObjectID(kAudioObjectSystemObject),
                       handler: @escaping () -> Void) -> Listener {
        Listener(object, selector, handler: handler)
    }
}
