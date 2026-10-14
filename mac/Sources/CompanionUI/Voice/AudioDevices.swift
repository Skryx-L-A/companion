// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import AVFoundation
import Foundation

/// The devices of this machine, as `MicrophoneCapture` needs to see them.
///
/// Everything in `MicrophoneCapture` that decides something — which device to record from,
/// whether the voice-processing unit is to be believed, whether the microphone is delivering
/// anything at all — used to ask Core Audio directly, so none of it could be exercised without
/// a real microphone in a real room. `regeln/tests-und-eingriffe.md` forbids that, which meant
/// the half of the dictation fix carrying all the risk had no test at all (review, 2026-09-03).
///
/// The protocol is the seam: `SystemAudioDevices` is the one implementation that touches Core
/// Audio, and a test hands in a table of devices instead. Nothing here opens a stream or reads
/// a sample; these are the property reads that answer "what is out there".
@MainActor
public protocol AudioDeviceQuerying: AnyObject {
    /// What the system currently calls the input device. Whatever connected last, which is
    /// exactly why nothing trusts it without asking whether it lives.
    func defaultInputDevice() -> AudioObjectID?
    func allDevices() -> [AudioObjectID]
    /// Core Audio's own word (`kAudioDevicePropertyDeviceIsAlive`) plus at least one input
    /// stream. A Bluetooth device that went away keeps the throne and still calls itself
    /// alive, so both halves are asked.
    func isLiveInput(_ device: AudioObjectID) -> Bool
    func name(of device: AudioObjectID) -> String?
    /// The device's own identifier, stable across a reconnect and across a restart, unlike
    /// the `AudioObjectID`, which Core Audio hands out afresh. What a verdict about one
    /// piece of hardware is filed under.
    func uid(of device: AudioObjectID) -> String?
    func transportType(of device: AudioObjectID) -> UInt32
    /// The sample rate and input channel count the device says it has, which is what a
    /// correctly bound input node has to report back.
    func inputFormat(of device: AudioObjectID) -> DeviceFormat?
}

/// The two numbers that say whether an input node is really on the device.
///
/// Both, because either one alone lets a phantom through. Measured on the machine this was
/// built for: the leftovers of the voice-processing unit produce a node at the device's own
/// 48 kHz with THREE channels, which a rate-only test accepts and which never delivers a
/// sample; and the generic default a node falls back to is 44 100 Hz stereo, which a device
/// that really runs at 44 100 in stereo shares. Comparing the whole value is what compares
/// both.
public struct DeviceFormat: Equatable, Sendable {
    public var rate: Double
    public var channels: UInt32

    public init(rate: Double, channels: UInt32) {
        self.rate = rate
        self.channels = channels
    }
}

/// What `MicrophoneCapture.start()` decided to listen to.
public struct ResolvedInput: Equatable, Sendable {
    public let id: AudioObjectID
    public let name: String
    /// Nil for a device that publishes no UID. A verdict cannot be filed under one then, and
    /// nothing is remembered about it.
    public let uid: String?
    /// True when the system default was passed over for a device that actually lives.
    public let isFallback: Bool

    public init(id: AudioObjectID, name: String, uid: String?, isFallback: Bool) {
        self.id = id
        self.name = name
        self.uid = uid
        self.isFallback = isFallback
    }
}

extension AudioDeviceQuerying {
    /// The system default input if it truly lives, otherwise a device that does.
    ///
    /// The fallback prefers the built-in microphone: it is the one device that is always
    /// really there. Three real dictations went into a Bluetooth headset in a bag before
    /// anybody knew where the words had gone (2026-08-27).
    public func resolveLiveInput() -> ResolvedInput? {
        if let byDefault = defaultInputDevice(), isLiveInput(byDefault) {
            return ResolvedInput(
                id: byDefault, name: name(of: byDefault) ?? "unbenannt",
                uid: uid(of: byDefault), isFallback: false)
        }
        guard let chosen = builtInInput() ?? allDevices().first(where: isLiveInput) else {
            return nil
        }
        return ResolvedInput(
            id: chosen, name: name(of: chosen) ?? "unbenannt", uid: uid(of: chosen),
            isFallback: true)
    }

    /// The built-in microphone, if this machine has one that lives.
    public func builtInInput() -> AudioObjectID? {
        allDevices().filter(isLiveInput).first {
            transportType(of: $0) == kAudioDeviceTransportTypeBuiltIn
        }
    }
}

// MARK: - The verdict on the voice-processing unit

/// Whether the echo-cancelling audio unit is to be believed for one device.
///
/// Measured 2026-08-27 on the machine this was built for: the unit reported NINE channels,
/// and a voice that reached 0.49 peak on the raw microphone came out of it as 0.03 of floor
/// noise. A healthy unit publishes one channel, two at most.
public enum VoiceProcessingVerdict: Equatable, Sendable {
    case usable
    case broken(channels: UInt32)

    public static func reading(channels: UInt32) -> VoiceProcessingVerdict {
        channels > 2 ? .broken(channels: channels) : .usable
    }

    public var isBroken: Bool {
        if case .broken = self { return true }
        return false
    }
}

/// Which devices' voice-processing unit was caught eating the signal.
///
/// Per DEVICE, not per process. The verdict used to be one `static var` for the whole run,
/// with the argument that it says something about the system — but what is measured is the
/// channel count of one piece of hardware. First dictation on a built-in microphone that is
/// broken latched the flag; plugging in AirPods or an interface whose unit works then found
/// `hasEchoCancellation` forced false for that device too, and the companion stayed in half
/// duplex, with no barge-in, on hardware that never had the fault (review F6, 2026-09-03).
public struct VoiceProcessingHealth: Sendable {
    private var broken: Set<String> = []

    public init() {}

    /// A device with no UID is never remembered: there would be nothing to file the verdict
    /// under, and guessing one would mean answering for the wrong device later.
    public func isBroken(_ deviceUID: String?) -> Bool {
        guard let deviceUID else { return false }
        return broken.contains(deviceUID)
    }

    public mutating func markBroken(_ deviceUID: String?) {
        guard let deviceUID else { return }
        broken.insert(deviceUID)
    }

    /// Forgets one device's verdict — for the moment its hardware could have changed under
    /// the same name, which is what a default-input-device change can mean.
    public mutating func forget(_ deviceUID: String?) {
        guard let deviceUID else { return }
        broken.remove(deviceUID)
    }

    public mutating func forgetEverything() {
        broken.removeAll()
    }
}

// MARK: - The watch on a device that delivers nothing

/// Counts what arrives from the microphone and says when it is time to move to another one.
///
/// A dead device has two faces. It delivers blocks of exact digital zero — a real microphone
/// has a noise floor and never does that — or it delivers no callback at all while the engine
/// happily reports that it runs. Both are watched, because both happened.
public struct DeadDeviceWatch: Sendable {
    /// Eight blocks of 0.1 s. Long enough that a fade-in cannot trip it, short enough that
    /// nobody finishes a sentence into a device that is not there.
    public static let silentBlocksBeforeFailover = 8
    /// One second is ten missed blocks — far beyond the startup jitter of a working
    /// microphone.
    public static let firstBlockDeadline: TimeInterval = 1.0

    public private(set) var silentBlocks = 0
    public private(set) var buffersSeen = 0
    /// Whether this recording already moved to another microphone. Once is enough.
    public private(set) var hasFailedOver = false

    public init() {}

    /// A recording begins. `keepingFailover` is true for the restart the failover itself
    /// performs, so the same dead recording cannot fail over twice.
    public mutating func begin(keepingFailover: Bool = false) {
        silentBlocks = 0
        buffersSeen = 0
        if !keepingFailover { hasFailedOver = false }
    }

    /// One block arrived. True when this is the block that trips the failover.
    public mutating func received(_ pcm: Data) -> Bool {
        buffersSeen += 1
        guard !hasFailedOver else { return false }
        guard pcm.allSatisfy({ $0 == 0 }) else {
            silentBlocks = 0
            return false
        }
        silentBlocks += 1
        return silentBlocks >= Self.silentBlocksBeforeFailover
    }

    /// The first-block deadline passed. True when nothing has arrived at all and the failover
    /// is due.
    public mutating func firstBlockDeadlinePassed() -> Bool {
        !hasFailedOver && buffersSeen == 0
    }

    public mutating func markFailedOver() {
        hasFailedOver = true
    }
}

// MARK: - Binding an engine to a device

/// Builds engines until one really reports the device's format, or the deadline runs out.
///
/// A brand-new `AVAudioEngine` built right after the voice-processing unit has been touched
/// hands out an input node bound to nothing: it reports the generic 44 100 Hz stereo default
/// instead of the device, `start()` returns success in no time and not one buffer ever
/// arrives. Waiting on that node does not help — it stays wrong. What helps is building
/// another engine, once the unit has actually been let go. Measured 2026-08-28, sampling every
/// fifty milliseconds after the poisoned engine was released: a fresh engine reports the
/// generic format for the first 190 ms and the device's own 48 kHz mono from 254 ms on.
///
/// Generic over the engine and free of any clock of its own, so the retry rule can be
/// exercised with a fake engine and a fake clock rather than only on hardware.
///
/// If nothing ever matches, the last engine is handed back anyway: a microphone that delivers
/// nothing has `DeadDeviceWatch` behind it, and one that cannot be bound is not made better by
/// refusing to record at all.
public func engineBound<Engine>(
    to wanted: DeviceFormat?,
    deadline: TimeInterval,
    step: TimeInterval,
    build: () -> Engine,
    formatOf: (Engine) -> DeviceFormat,
    wait: (TimeInterval) -> Void,
    elapsed: () -> TimeInterval
) -> Engine {
    var engine = build()
    guard let wanted else { return engine }
    while formatOf(engine) != wanted, elapsed() < deadline {
        wait(step)
        engine = build()
    }
    return engine
}

// MARK: - Core Audio itself

/// The one implementation that talks to Core Audio. Everything else asks it through
/// `AudioDeviceQuerying`.
@MainActor
public final class SystemAudioDevices: AudioDeviceQuerying {
    public init() {}

    public func defaultInputDevice() -> AudioObjectID? {
        var deviceId = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceId
        ) == noErr, deviceId != kAudioObjectUnknown else { return nil }
        return deviceId
    }

    public func allDevices() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var devices = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr
        else { return [] }
        return devices
    }

    public func isLiveInput(_ device: AudioObjectID) -> Bool {
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var aliveAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &aliveAddress, 0, nil, &size, &alive) == noErr,
            alive == 1
        else { return false }
        var streamsAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var streamsSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &streamsAddress, 0, nil, &streamsSize) == noErr
        else { return false }
        return streamsSize >= UInt32(MemoryLayout<AudioObjectID>.size)
    }

    public func name(of device: AudioObjectID) -> String? {
        string(of: device, selector: kAudioObjectPropertyName)
    }

    public func uid(of device: AudioObjectID) -> String? {
        string(of: device, selector: kAudioDevicePropertyDeviceUID)
    }

    public func transportType(of device: AudioObjectID) -> UInt32 {
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr
        else { return 0 }
        return transport
    }

    public func inputFormat(of device: AudioObjectID) -> DeviceFormat? {
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr,
            rate > 0, let channels = inputChannelCount(device)
        else { return nil }
        return DeviceFormat(rate: rate, channels: channels)
    }

    /// How many input channels a device carries, out of its stream configuration.
    private func inputChannelCount(_ device: AudioObjectID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
            size >= UInt32(MemoryLayout<AudioBufferList>.size)
        else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr
        else { return nil }
        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self))
        let channels = list.reduce(UInt32(0)) { $0 + $1.mNumberChannels }
        return channels > 0 ? channels : nil
    }

    private func string(of device: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr
        else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
