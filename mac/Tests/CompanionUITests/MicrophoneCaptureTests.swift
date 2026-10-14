// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import AVFoundation
import XCTest

@testable import CompanionUI

/// The decisions the microphone path makes, without a microphone.
///
/// `regeln/tests-und-eingriffe.md`: no test here opens an input device. What used to make this
/// file impossible was that every decision asked Core Audio directly; they now go through
/// `AudioDeviceQuerying` and a handful of value types, and this is the table those answers
/// produce (review, 2026-09-03: `MicrophoneCapture` had no test at all, although it carries
/// the whole risk of the dictation fix).

/// A machine with whatever devices a test says it has.
@MainActor
final class FakeAudioDevices: AudioDeviceQuerying {
    struct Device {
        var id: AudioObjectID
        var name: String
        var uid: String?
        var isLive: Bool = true
        var transport: UInt32 = kAudioDeviceTransportTypeUSB
        var format: DeviceFormat? = DeviceFormat(rate: 48000, channels: 1)
    }

    var devices: [Device] = []
    var defaultInput: AudioObjectID?

    static func builtIn(id: AudioObjectID = 1, isLive: Bool = true) -> Device {
        Device(
            id: id, name: "MacBook Pro-Mikrofon", uid: "BuiltInMicrophoneDevice",
            isLive: isLive, transport: kAudioDeviceTransportTypeBuiltIn)
    }

    static func bluetooth(id: AudioObjectID = 2, isLive: Bool = true) -> Device {
        Device(
            id: id, name: "APLTF", uid: "APLTF-uid", isLive: isLive,
            transport: kAudioDeviceTransportTypeBluetooth)
    }

    private func device(_ id: AudioObjectID) -> Device? { devices.first { $0.id == id } }

    func defaultInputDevice() -> AudioObjectID? { defaultInput }
    func allDevices() -> [AudioObjectID] { devices.map(\.id) }
    func isLiveInput(_ device: AudioObjectID) -> Bool { self.device(device)?.isLive ?? false }
    func name(of device: AudioObjectID) -> String? { self.device(device)?.name }
    func uid(of device: AudioObjectID) -> String? { self.device(device)?.uid }
    func transportType(of device: AudioObjectID) -> UInt32 {
        self.device(device)?.transport ?? 0
    }
    func inputFormat(of device: AudioObjectID) -> DeviceFormat? { self.device(device)?.format }
}

@MainActor
final class InputDeviceChoiceTests: XCTestCase {
    func testALivingDefaultIsTheDeviceThatIsUsed() {
        let machine = FakeAudioDevices()
        machine.devices = [FakeAudioDevices.builtIn(), FakeAudioDevices.bluetooth()]
        machine.defaultInput = 2

        let resolved = machine.resolveLiveInput()
        XCTAssertEqual(resolved?.id, 2)
        XCTAssertEqual(resolved?.name, "APLTF")
        XCTAssertEqual(resolved?.uid, "APLTF-uid")
        XCTAssertFalse(resolved?.isFallback ?? true, "nothing was passed over")
    }

    /// 2026-08-27: a Bluetooth headset that had gone away stayed on the throne of the system
    /// default and kept calling itself alive; three real dictations went into it. Core Audio's
    /// aliveness plus an input stream is what decides, not the default.
    func testADeadDefaultIsPassedOverForTheBuiltInMicrophone() {
        let machine = FakeAudioDevices()
        machine.devices = [
            FakeAudioDevices.builtIn(), FakeAudioDevices.bluetooth(isLive: false),
        ]
        machine.defaultInput = 2

        let resolved = machine.resolveLiveInput()
        XCTAssertEqual(resolved?.id, 1, "the one device that is always really there")
        XCTAssertTrue(resolved?.isFallback ?? false, "and the engine has to be pointed at it")
    }

    /// Where the failover goes. Review 2026-09-03: it used to get there by writing the
    /// machine's own default input device, a change with reach that outlived the app and had
    /// already fired without cause; the engine is pointed at this device instead, and
    /// `AudioDeviceQuerying` has no way to write anything at all.
    func testTheFailoverTargetIsTheBuiltInMicrophoneAndNothingIsWritten() {
        let machine = FakeAudioDevices()
        machine.devices = [FakeAudioDevices.bluetooth(id: 2), FakeAudioDevices.builtIn(id: 1)]
        machine.defaultInput = 2

        XCTAssertEqual(machine.builtInInput(), 1)
        XCTAssertEqual(machine.defaultInput, 2, "the machine's own setting is untouched")
    }

    func testWithoutABuiltInMicrophoneThereIsNothingToFailOverTo() {
        let machine = FakeAudioDevices()
        machine.devices = [FakeAudioDevices.bluetooth(id: 2)]
        XCTAssertNil(machine.builtInInput())
    }

    func testAMachineWithoutALivingInputResolvesToNothing() {
        let machine = FakeAudioDevices()
        machine.devices = [FakeAudioDevices.builtIn(isLive: false)]
        machine.defaultInput = 1
        XCTAssertNil(machine.resolveLiveInput())
    }

    /// Without a built-in microphone — a Mac mini with an interface plugged in — any living
    /// input beats none.
    func testWithoutABuiltInMicrophoneAnyLivingInputWillDo() {
        let machine = FakeAudioDevices()
        machine.devices = [FakeAudioDevices.bluetooth(id: 7)]
        machine.defaultInput = 99

        let resolved = machine.resolveLiveInput()
        XCTAssertEqual(resolved?.id, 7)
        XCTAssertTrue(resolved?.isFallback ?? false)
    }
}

@MainActor
final class VoiceProcessingVerdictTests: XCTestCase {
    /// Measured 2026-08-27: the unit answered with NINE channels and a voice at 0.49 peak
    /// came out as 0.03 of floor noise. That is the reading that means "broken".
    func testNineChannelsIsABrokenUnit() {
        XCTAssertEqual(VoiceProcessingVerdict.reading(channels: 9), .broken(channels: 9))
        XCTAssertTrue(VoiceProcessingVerdict.reading(channels: 3).isBroken)
    }

    func testOneOrTwoChannelsIsKept() {
        XCTAssertEqual(VoiceProcessingVerdict.reading(channels: 1), .usable)
        XCTAssertEqual(VoiceProcessingVerdict.reading(channels: 2), .usable)
    }

    /// Review F6, 2026-09-03: the verdict used to be one flag for the whole process, so the
    /// built-in microphone being broken forced a headset plugged in afterwards into half
    /// duplex as well — no barge-in for the rest of the session, on hardware that never had
    /// the fault.
    func testTheVerdictBelongsToOneDeviceAndNotToTheProcess() {
        var health = VoiceProcessingHealth()
        health.markBroken("BuiltInMicrophoneDevice")

        XCTAssertTrue(health.isBroken("BuiltInMicrophoneDevice"))
        XCTAssertFalse(health.isBroken("AirPods-uid"), "another device was never measured")
        XCTAssertFalse(health.isBroken(nil), "and a device without a UID is never remembered")

        health.forget("BuiltInMicrophoneDevice")
        XCTAssertFalse(health.isBroken("BuiltInMicrophoneDevice"))
    }

    func testADeviceWithoutAUidIsNotFiledUnderAnything() {
        var health = VoiceProcessingHealth()
        health.markBroken(nil)
        XCTAssertFalse(health.isBroken(nil))
        XCTAssertFalse(health.isBroken("BuiltInMicrophoneDevice"))
    }
}

@MainActor
final class DeadDeviceWatchTests: XCTestCase {
    private func silence(blocks: Int) -> [Data] {
        Array(repeating: Data(count: 3200), count: blocks)
    }

    private var speech: Data {
        Data((0..<3200).map { UInt8($0 % 251 + 1) })
    }

    func testEightBlocksOfExactSilenceTripTheFailover() {
        var watch = DeadDeviceWatch()
        watch.begin()
        var tripped = false
        for block in silence(blocks: 7) { tripped = watch.received(block) || tripped }
        XCTAssertFalse(tripped, "seven blocks are 0.7 s and not yet a verdict")

        XCTAssertTrue(watch.received(Data(count: 3200)), "the eighth is")
    }

    /// A real microphone has a noise floor and never delivers exact zeros; one block that
    /// carries anything at all starts the count over.
    func testAnythingButSilenceStartsTheCountOver() {
        var watch = DeadDeviceWatch()
        watch.begin()
        for block in silence(blocks: 7) { _ = watch.received(block) }
        _ = watch.received(speech)
        for block in silence(blocks: 7) {
            XCTAssertFalse(watch.received(block), "the count began again at zero")
        }
    }

    func testTheSameRecordingDoesNotFailOverTwice() {
        var watch = DeadDeviceWatch()
        watch.begin()
        for block in silence(blocks: 8) { _ = watch.received(block) }
        watch.markFailedOver()
        for block in silence(blocks: 20) {
            XCTAssertFalse(watch.received(block), "once is enough")
        }
    }

    /// The other face of a dead device: the engine runs and the tap stays silent — no
    /// callback ever comes at all.
    func testNoBlockWithinTheFirstSecondIsAlsoADeadDevice() {
        var watch = DeadDeviceWatch()
        watch.begin()
        XCTAssertTrue(watch.firstBlockDeadlinePassed())

        var second = DeadDeviceWatch()
        second.begin()
        _ = second.received(speech)
        XCTAssertFalse(second.firstBlockDeadlinePassed(), "audio arrived, nothing to fail over")
    }

    /// The restart the failover itself performs keeps the marker, so a device that is still
    /// dead afterwards cannot send it round again.
    func testTheFailoversOwnRestartKeepsTheMarker() {
        var watch = DeadDeviceWatch()
        watch.begin()
        watch.markFailedOver()
        watch.begin(keepingFailover: true)
        XCTAssertFalse(watch.firstBlockDeadlinePassed())

        watch.begin()
        XCTAssertTrue(watch.firstBlockDeadlinePassed(), "a new recording watches again")
    }
}

/// The wakeword listener and the dictation on one device.
@MainActor
final class SharedMicrophoneTests: XCTestCase {
    /// Review 2026-09-03: the shell gave each of them a capture of its own, so the handover
    /// released one engine and built another on the same input device in the same turn — the
    /// settle window nothing on that path waited for. One instance takes the release out of
    /// the handover.
    func testBothSidesGetTheSameDeviceAndItIsBuiltOnce() {
        var built = 0
        let device = SharedMicrophone {
            built += 1
            return FakeCapture()
        }
        XCTAssertEqual(built, 0, "a shell that never records builds no engine")

        let listener = device.capturing()
        let dictation = device.capturing()
        XCTAssertTrue(listener === dictation)
        XCTAssertEqual(built, 1)
    }

    /// And the handover itself: the dictation goes on with the device the listener had, and
    /// the listener has it back afterwards — all on the one instance. That the listener no
    /// longer stops it on the way over is `WakewordListenerTests`; here the point is only that
    /// there is one device to hand over at all.
    func testTheHandoverRunsOnTheOneInstance() throws {
        let device = SharedMicrophone { FakeCapture() }
        let capture = try XCTUnwrap(device.capturing() as? FakeCapture)

        try capture.start()
        XCTAssertTrue(capture.isRunning)
        capture.stop()

        let dictation = try XCTUnwrap(device.capturing() as? FakeCapture)
        try dictation.start()
        XCTAssertTrue(capture.isRunning, "the same device, still one engine")
        XCTAssertEqual(capture.startCount, 2)
    }
}

/// The retry rule of `engineBoundTo`, with a fake engine and a fake clock instead of the
/// audio hardware it was measured on.
@MainActor
final class EngineBindingTests: XCTestCase {
    private let device = DeviceFormat(rate: 48000, channels: 1)
    /// What a node bound to nothing reports: the generic default.
    private let generic = DeviceFormat(rate: 44100, channels: 2)

    func testItBuildsAgainUntilTheEngineReportsTheDevice() {
        var formats = [generic, generic, device]
        var built = 0
        var waited: [TimeInterval] = []
        var clock: TimeInterval = 0

        let engine = engineBound(
            to: device, deadline: 1.0, step: 0.02,
            build: { () -> Int in
                built += 1
                return built
            },
            formatOf: { _ in formats.removeFirst() },
            wait: { seconds in
                waited.append(seconds)
                clock += seconds
            },
            elapsed: { clock })

        XCTAssertEqual(engine, 3, "the third one is the one that answered for the device")
        XCTAssertEqual(waited, [0.02, 0.02])
    }

    /// An engine that never binds is handed back anyway: a microphone that delivers nothing
    /// has `DeadDeviceWatch` behind it, and refusing to record at all is no better.
    func testAnEngineThatNeverBindsIsStillHandedBack() {
        var built = 0
        var clock: TimeInterval = 0
        let engine = engineBound(
            to: device, deadline: 0.1, step: 0.02,
            build: { () -> Int in
                built += 1
                return built
            },
            formatOf: { _ in self.generic },
            wait: { clock += $0 },
            elapsed: { clock })

        XCTAssertEqual(engine, built)
        XCTAssertEqual(built, 6, "one built, then five retries inside the deadline")
    }

    /// Nothing to compare against — a machine that could not say what its device looks like —
    /// means the first engine, with no waiting at all.
    func testWithoutADeviceFormatNothingIsWaitedFor() {
        var waited = 0
        let engine = engineBound(
            to: nil, deadline: 1.0, step: 0.02,
            build: { 1 }, formatOf: { _ in self.generic },
            wait: { _ in waited += 1 }, elapsed: { 0 })

        XCTAssertEqual(engine, 1)
        XCTAssertEqual(waited, 0)
    }
}
