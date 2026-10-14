// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import AVFoundation
import CompanionProtocol
import Foundation

/// The microphone, through the echo-cancelling audio unit of the system.
///
/// `AVAudioInputNode.setVoiceProcessingEnabled(true)` puts the engine on
/// `kAudioUnitSubType_VoiceProcessingIO`, the same unit FaceTime uses: it cancels what the
/// speakers put back into the microphone, suppresses room noise and rides the gain. That
/// cancellation is the whole basis for barge-in — without it, the figure hears itself, and
/// `DESIGN.md` section Voice falls back to half duplex, mute the microphone while it speaks.
/// The flag is read back from the node afterwards rather than assumed, so the fallback is
/// decided on what the system actually did.
///
/// What leaves this class is what a streaming recogniser wants and nothing more: 16 kHz, mono,
/// signed 16-bit little-endian. The hardware runs at 44.1 or 48 kHz float, so every buffer
/// goes through one `AVAudioConverter`.
@MainActor
public final class MicrophoneCapture: AudioCapturing {
    public var onBuffer: ((Data) -> Void)?
    public private(set) var isRunning = false
    public private(set) var hasEchoCancellation = false
    /// True once `setVoiceProcessingEnabled(true)` was actually called on `engine`'s own
    /// input node and has not since been undone by a fresh engine replacing it.
    ///
    /// Not the same thing as `hasEchoCancellation`, which review M5 (2026-08-28) named as
    /// the wrong stand-in: that one says "the unit is on AND usable", so `stop()` skipped
    /// disabling it whenever the readback came back false — including the one case that
    /// matters, the input side enabling but the output side throwing, where the unit stayed
    /// on the input for good. This field says only what `stop()` actually needs to know: is
    /// there something on `engine`'s current nodes worth switching off.
    private var isVoiceProcessingEngagedOnThisEngine = false

    private var engine = AVAudioEngine()
    private let target: AVAudioFormat
    /// Everything this class asks Core Audio about the hardware. Behind a protocol so the
    /// decisions made from those answers can be exercised without a microphone
    /// (`AudioDevices.swift`).
    private let devices: AudioDeviceQuerying
    /// The device the running engine actually listens to, set by `start()`. While nothing
    /// runs, the system default is reported instead.
    private var activeInputName: String?
    /// Counts what arrives and says when the device is provably delivering nothing — blocks
    /// of exact digital zero, or no block at all within the first second.
    private var watch = DeadDeviceWatch()
    /// True only for the restart the failover itself performs, so `start()` does not clear
    /// the marker and the same dead recording cannot fail over twice.
    private var didFailoverInProgress = false
    /// Names the binding that is under way, so a `stop()` or a second `start()` calls the one
    /// before it off: every scheduled step checks that it is still the current one.
    private var pendingBinding = 0
    /// The device the failover moved this recording to, or nil while nothing was moved.
    ///
    /// The engine is pointed at it and the machine is left alone. Cleared when a new
    /// recording begins: the next one asks the system again, because by then the device that
    /// delivered nothing may well be back.
    private var forcedDevice: AudioObjectID?
    /// Which devices' voice-processing unit was caught eating the signal. Per process, so a
    /// verdict measured once is not paid for again on every recording that follows.
    private static var voiceProcessingHealth = VoiceProcessingHealth()
    /// How long the voice-processing unit is given to let go of the input before the engine
    /// that will actually record is built, and how long that engine is then given to bind to
    /// the device. Measured 2026-08-28: two tenths of a second of settling is enough on its
    /// own, and the retry below never had to run.
    private static let engineSettleSeconds = 0.2
    private static let engineBindingDeadline = 1.0
    private static let engineBindingStep = 0.02
    /// How much audio one delivered block holds. A tenth of a second is short enough that
    /// the recogniser's first partial arrives quickly and long enough that the line rate
    /// stays at ten messages a second.
    private let blockSeconds = 0.1

    public init(
        format: VoiceCaptureFormat = .default,
        devices: AudioDeviceQuerying = SystemAudioDevices()
    ) {
        self.devices = devices
        // Only for the real machine: a test hands in a table of devices and must not put a
        // listener on the Core Audio of the machine it runs on.
        if devices is SystemAudioDevices { Self.watchTheDefaultInput() }
        // Interleaved 16-bit is what goes on the wire; mono, because a recogniser gains
        // nothing from a second channel and it would double the bytes.
        self.target = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: Double(format.sampleRateHz),
            channels: AVAudioChannelCount(format.channels), interleaved: true)
            ?? AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
    }

    public func start() throws {
        guard !isRunning else { return }
        watch.begin(keepingFailover: didFailoverInProgress)
        // A binding left over from a start that was called off is not this recording's.
        pendingBinding += 1
        if !didFailoverInProgress { forcedDevice = nil }
        isVoiceProcessingEngagedOnThisEngine = false
        let input = engine.inputNode

        // The system default is whatever connected LAST, and macOS keeps a Bluetooth
        // device on the throne even after it disconnected — the engine then records from
        // a device that is not there and delivers silence. Three real dictations went
        // that way (2026-08-27, "APLTF" was default and not connected). So the default is
        // trusted only while Core Audio calls it alive and it still has input streams;
        // otherwise the engine is pointed at a device that really exists, the built-in
        // microphone first.
        //
        // A device the failover picked outranks all of that for as long as that recording
        // lasts: it was chosen because the one before it was provably delivering nothing.
        var activeInputDevice: AudioObjectID?
        var activeInputUID: String?
        if let forced = forcedDevice {
            point(input, at: forced)
            activeInputDevice = forced
            activeInputName = devices.name(of: forced)
            activeInputUID = devices.uid(of: forced)
        } else if let resolved = devices.resolveLiveInput() {
            if resolved.isFallback { point(input, at: resolved.id) }
            activeInputDevice = resolved.id
            activeInputName = resolved.name
            activeInputUID = resolved.uid
        } else {
            activeInputName = nil
        }

        // Both ends of the same voice-processing unit: the input side does the cancelling,
        // the output side is the reference signal it cancels against. A system that refuses
        // is not an error — it means half duplex, and `hasEchoCancellation` says so.
        //
        // A unit that was already found broken ON THIS DEVICE is not asked again. Enabling it
        // costs the whole start-up of this recording even when the answer is thrown away a
        // line later: measured 2026-08-28 on this machine, `start()` took 630 to 753
        // milliseconds with the detour and 45 to 48 without it, and the first block of audio
        // arrived after 849 to 1018 milliseconds instead of 106.
        //
        // Per device, not per process (review F6, 2026-09-03): what was measured is the
        // channel count of one piece of hardware, and a verdict about the built-in microphone
        // said nothing about the headset somebody plugs in afterwards — it only forced that
        // one into half duplex as well, for the rest of the session.
        //
        // A recording the failover moved gets no voice processing at all. The unit follows
        // the SYSTEM default and shrugs at a device set on the audio unit below it (measured
        // 2026-08-27), so enabling it here would quietly undo the move and record from the
        // dead device again. Half duplex on the microphone that works beats echo cancellation
        // on the one that delivers nothing, and half duplex is the documented fallback.
        if forcedDevice != nil || Self.voiceProcessingHealth.isBroken(activeInputUID) {
            hasEchoCancellation = false
        } else {
            do {
                try input.setVoiceProcessingEnabled(true)
                // Set the moment the call that matters succeeds, not after the readback:
                // the output side enabling next can still throw, and `input` would then
                // stay on the unit with `hasEchoCancellation` left false, which used to
                // read as "nothing to switch off" in `stop()`.
                isVoiceProcessingEngagedOnThisEngine = true
                try engine.outputNode.setVoiceProcessingEnabled(true)
                hasEchoCancellation = input.isVoiceProcessingEnabled
            } catch {
                hasEchoCancellation = false
            }
        }
        // A voice-processing unit that answers with an absurd channel count is broken and
        // eats the signal instead of cleaning it. Measured 2026-08-27 on the machine this
        // was built for: the unit reported NINE channels, and a voice that reached 0.49
        // peak on the raw microphone came out of the unit as 0.03 of floor noise — every
        // real dictation ended in "no words found" while the raw signal was loud and
        // clear. A healthy unit publishes one channel, two at most. Anything beyond that
        // is switched off again, and the documented fallback carries barge-in: half
        // duplex, the microphone muted while the figure speaks.
        let verdict = hasEchoCancellation
            ? VoiceProcessingVerdict.reading(channels: input.outputFormat(forBus: 0).channelCount)
            : .usable
        if case .broken(let count) = verdict {
            let line = "Voice-Processing liefert \(count) Kanäle statt einem – "
                + "Einheit gilt als defekt, Aufnahme läuft roh\n"
            FileHandle.standardError.write(Data(line.utf8))
            Self.voiceProcessingHealth.markBroken(activeInputUID)
            // Switching the unit off on the same engine is not enough: the engine that had
            // it keeps a poisoned input path and the tap delivers one block and goes quiet
            // — measured 2026-08-27, a six-second recording arrived as 85 ms. A fresh
            // engine that never saw voice processing streams cleanly, so the poisoned one
            // is thrown away whole.
            // The poisoned engine goes first, and the device is only itself again once it
            // has: measured 2026-08-28, the built-in microphone publishes THREE input
            // channels for as long as that engine lives and one again eleven milliseconds
            // after it is released. Asking the system what the device looks like while the
            // unit still holds it gives the unit's answer, not the device's.
            //
            // Review M4, 2026-08-28: the poisoned engine is freed by the reassignment
            // below and nothing else — `input` is left untouched here on purpose, because
            // reading `.inputNode` off the throwaway engine that used to sit between this
            // line and `engineBoundTo` materialised a second input node bound to the
            // device during the exact settle window `engineBoundTo` waits out, the same
            // class of state this whole fix exists to avoid. `input` is reassigned once
            // `engineBoundTo` hands back an engine that has actually settled.
            //
            // Review F11, 2026-09-03: the line below used to be followed immediately by
            // `engine = Self.engineBoundTo(...)`, which overwrote it before anything could
            // observe it — a leftover of the round-1 rewrite. It is the release of the
            // poisoned engine and nothing else now, and the engine that will really record
            // is built after the settle, in `bindEngine`.
            engine = AVAudioEngine()
            hasEchoCancellation = false
            // The fresh engine never had voice processing touched, so `stop()` must not
            // try to turn it off there either — that would rebind its input node to
            // nothing for the next recording (see the guard in `stop()`).
            isVoiceProcessingEngagedOnThisEngine = false
            // Everything from here is the settle window, and it does not belong to the main
            // actor: `bindEngine` comes back through the main queue instead of sleeping on
            // it (review F12, 2026-09-03).
            bindEngine(to: activeInputDevice)
            return
        }

        try beginStreaming()
    }

    /// Installs the tap and starts the engine that is already pointed at its device.
    ///
    /// Its own method because there are two ways here: `start()` in one go, and `bindEngine`
    /// a settle window later, on a machine whose voice-processing unit had to be thrown away
    /// with its engine.
    private func beginStreaming() throws {
        let input = engine.inputNode
        // Read after enabling: the voice-processing unit publishes its own format, and a tap
        // installed with the format from before would be handed buffers of another shape.
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioFailure.noInputDevice
        }
        guard let resampler = Resampler(from: inputFormat, to: target) else {
            throw AudioFailure.engine("\(inputFormat) lässt sich nicht in 16 kHz mono wandeln")
        }

        let frames = AVAudioFrameCount(inputFormat.sampleRate * blockSeconds)
        // The tap block MUST be @Sendable and nonisolated. This class is @MainActor, and a
        // plain closure formed here inherits that isolation — AVFAudio then calls it on its
        // own audio queue, and the runtime's isolation check traps on entry, before a single
        // line runs. That was the crash on the very first real key press (2026-08-27,
        // EXC_BREAKPOINT in dispatch_assert_queue via swift_task_checkIsolatedSwift): the
        // hop to the main actor inside was never reached. `@Sendable` makes the closure
        // nonisolated; it touches only the Sendable resampler and hops for everything else.
        let tap: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { [weak self] buffer, _ in
            guard let pcm = resampler.data(from: buffer) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.watchForADeadDevice(pcm)
                    // Debugging tap: with COMPANION_CAPTURE_DUMP set to a directory, every
                    // converted block is appended to capture.pcm there — raw 16 kHz mono
                    // s16le, playable with ffplay or feedable to the recogniser directly.
                    // The one honest way to see what the pipeline really carries.
                    if let dir = ProcessInfo.processInfo.environment["COMPANION_CAPTURE_DUMP"] {
                        let url = URL(fileURLWithPath: dir).appendingPathComponent("capture.pcm")
                        if let handle = try? FileHandle(forWritingTo: url) {
                            handle.seekToEndOfFile()
                            handle.write(pcm)
                            try? handle.close()
                        } else {
                            try? pcm.write(to: url)
                        }
                    }
                    self.onBuffer?(pcm)
                }
            }
        }
        input.installTap(onBus: 0, bufferSize: frames, format: inputFormat, block: tap)

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw AudioFailure.engine(error.localizedDescription)
        }
        isRunning = true
        // The second face of a dead device: no callback ever comes. One second is ten
        // missed blocks — far beyond any startup jitter of a working microphone.
        if !didFailoverInProgress {
            DispatchQueue.main.asyncAfter(deadline: .now() + DeadDeviceWatch.firstBlockDeadline) {
                [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.isRunning, self.watch.firstBlockDeadlinePassed() else {
                        return
                    }
                    self.failOverToTheBuiltInMicrophone()
                }
            }
        }
    }

    /// Listens for the system default input changing, and forgets what was measured about the
    /// device that becomes the new default.
    ///
    /// The hardware behind one UID does change while the name stays: a dock, a USB interface
    /// that reconnects, a virtual device its driver rebuilt. A verdict of "the voice-processing
    /// unit of this device is broken" would otherwise hold for the rest of the session with no
    /// way back except quitting the app (review F6, 2026-09-03). Forgetting costs one enable of
    /// the unit on the next recording and nothing else.
    ///
    /// This is an addition to the watch on silent blocks, not a replacement: the default
    /// changing says nothing about the device a running engine was pointed at — somebody
    /// plugging in headphones mid-dictation must not move the recording — so a device that
    /// goes dead under a recording is still caught by `DeadDeviceWatch` and by nothing else.
    ///
    /// Installed once for the process, because the verdicts it clears are held per process
    /// too. It is a property listener, not a job that runs: it costs nothing between the rare
    /// moments somebody changes their sound settings.
    private static var isWatchingTheDefaultInput = false

    private static func watchTheDefaultInput() {
        guard !isWatchingTheDefaultInput else { return }
        isWatchingTheDefaultInput = true
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main
        ) { _, _ in
            MainActor.assumeIsolated {
                let system = SystemAudioDevices()
                guard let device = system.defaultInputDevice() else { return }
                voiceProcessingHealth.forget(system.uid(of: device))
            }
        }
        guard status != noErr else { return }
        isWatchingTheDefaultInput = false
        FileHandle.standardError.write(
            Data("Standard-Eingabegerät lässt sich nicht beobachten: status=\(status)\n".utf8))
    }

    /// Points one node's audio unit at a device, which is how the engine is moved without
    /// touching anything outside this app.
    private func point(_ node: AVAudioInputNode, at device: AudioObjectID) {
        var deviceId = device
        guard let unit = node.audioUnit else { return }
        AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &deviceId, UInt32(MemoryLayout<AudioObjectID>.size))
    }

    /// The name of the microphone that is or would be heard.
    ///
    /// While the engine runs this is the device it was really pointed at — which can
    /// differ from the system default, because a dead default is skipped. While nothing
    /// runs, the system default is asked at the moment of the question rather than
    /// cached: it follows whatever connected last, and the whole point of surfacing it
    /// is to catch exactly that change.
    public var inputName: String? {
        if isRunning, let activeInputName { return activeInputName }
        guard let device = devices.defaultInputDevice() else { return nil }
        return devices.name(of: device)
    }

    /// An engine whose input node has really bound to `device`.
    ///
    /// A brand-new `AVAudioEngine` built after the voice-processing unit has been touched
    /// hands out an input node that is bound to nothing: it reports the generic 44 100 Hz
    /// stereo default instead of the device, `start()` returns success in no time at all, and
    /// not one buffer ever arrives. Measured 2026-08-28 on this machine: two of four
    /// recordings came up that way and stayed silent for the whole three seconds they ran,
    /// while `installTap` with that format is one race away from the exception
    /// "Failed to create tap due to format mismatch".
    ///
    /// Waiting on the node that came out wrong does not help — that node stays wrong. What
    /// helps is building another engine, and only once the unit has actually been let go.
    /// Measured 2026-08-28 on this machine, sampling every fifty milliseconds after the
    /// voice-processing engine was released: a fresh engine reports the generic 44 100 Hz
    /// stereo for the first 190 milliseconds and the device's own 48 kHz mono from 254
    /// milliseconds on, and stays there.
    ///
    /// The caller has released the poisoned engine before this runs, so the device answers
    /// for itself again. The settle covers the usual case in one step; the loop is the
    /// safety net for a machine that needs longer. If the answer never matches, the last
    /// engine is handed back anyway: the watch on the first block catches a microphone that
    /// delivers nothing, and one that cannot be bound is not made better by refusing to
    /// record at all.
    ///
    /// Nothing sleeps on the main actor for any of it (review F12, 2026-09-03). The settle
    /// and every retry come back through the main queue, so the window costs this class its
    /// own start-up and costs the rest of the app nothing: the 0.2 s guaranteed and up to
    /// 1.2 s in the worst case used to freeze every main-actor timer with it, `DaemonClient`'s
    /// request deadlines among them (review M3, 2026-08-28). `start()` therefore returns
    /// before the microphone is open on this one path, which is the honest report: it was not
    /// open when it returned before either. `isRunning` turns true when the engine really
    /// runs, and `stop()` calls a pending binding off.
    ///
    /// The alternative was `AudioCapturing.start() async throws` across the protocol, both
    /// real callers and every test double. That is the cleaner shape and it stays scoped out:
    /// `VoiceController.startRecording` reads `hasEchoCancellation` in the line after
    /// `start()` to decide half duplex, so an asynchronous open would have to hand that back
    /// through a callback and would change the pipeline's own state machine — a redesign, not
    /// a fix, and one nothing in this branch could verify without a microphone.
    private func bindEngine(to device: AudioObjectID?) {
        pendingBinding += 1
        let generation = pendingBinding
        let wanted = device.flatMap { devices.inputFormat(of: $0) }
        let giveUpAt = Date().addingTimeInterval(Self.engineBindingDeadline)
        continueBinding(
            after: Self.engineSettleSeconds, wanted: wanted, giveUpAt: giveUpAt,
            generation: generation)
    }

    /// One step of the settle: wait, build an engine, and either take it or come back.
    private func continueBinding(
        after seconds: TimeInterval, wanted: DeviceFormat?, giveUpAt: Date, generation: Int
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.pendingBinding == generation else { return }
                let candidate = AVAudioEngine()
                self.engine = candidate
                let format = candidate.inputNode.outputFormat(forBus: 0)
                let bound = DeviceFormat(
                    rate: format.sampleRate, channels: format.channelCount)
                if let wanted, bound != wanted, Date() < giveUpAt {
                    self.continueBinding(
                        after: Self.engineBindingStep, wanted: wanted, giveUpAt: giveUpAt,
                        generation: generation)
                    return
                }
                do {
                    try self.beginStreaming()
                } catch {
                    // Nobody is waiting on a return value here any more, and this class has
                    // no way to say a sentence to a person. The silence that follows is
                    // caught where every other silent microphone is caught: the watch on the
                    // first block, and the recogniser finding no words.
                    FileHandle.standardError.write(
                        Data("Mikrofon: Engine nach dem Settle nicht gestartet: \(error)\n".utf8))
                }
            }
        }
    }

    /// Counts blocks of exact digital silence and, at the threshold, restarts the engine
    /// on the built-in microphone — the one device that is always really there.
    private func watchForADeadDevice(_ pcm: Data) {
        guard isRunning else { return }
        guard watch.received(pcm) else { return }
        failOverToTheBuiltInMicrophone()
    }

    /// Restarts the engine on the built-in microphone — the one device that is always
    /// really there. Called once per recording, from either face of a dead device.
    private func failOverToTheBuiltInMicrophone() {
        guard !watch.hasFailedOver else { return }
        watch.markFailedOver()
        let deadName = activeInputName ?? "unbekannt"
        guard let builtin = devices.builtInInput() else {
            FileHandle.standardError.write(
                Data("Mikrofon-Failover: kein eingebautes Mikrofon gefunden\n".utf8))
            return
        }
        let builtinName = devices.name(of: builtin) ?? "eingebautes Mikrofon"
        FileHandle.standardError.write(
            Data("Mikrofon-Failover: \(deadName) liefert nichts, wechsle auf \(builtinName)\n"
                .utf8))
        let held = onBuffer
        didFailoverInProgress = true
        defer { didFailoverInProgress = false }
        stop()
        // Only this app's own engine is moved, never the machine.
        //
        // It used to write `kAudioHardwarePropertyDefaultInputDevice` — the system-wide
        // default — with the argument that the voice-processing unit follows that setting and
        // shrugs at a device set on the audio unit below it, so moving the default was "the
        // hand movement the person would make in the sound settings". That observation is
        // real and is why a failed-over recording runs without voice processing (see
        // `start()`); the remedy was not. `DESIGN.md` Grundprinzip reserves a change with
        // reach for the human, this one outlived the app, and the commit that introduced it
        // recorded the failover firing without cause twice in six attempts — switching the
        // system default from the built-in microphone to the built-in microphone (review,
        // 2026-09-03).
        forcedDevice = builtin
        onBuffer = held
        try? start()
        onDeviceFailover?(deadName, builtinName)
    }

    /// Told when a recording moved to another microphone, with the dead and the new name.
    public var onDeviceFailover: ((String, String) -> Void)?

    public func stop() {
        // A recording that is still waiting for its engine ends here too: the scheduled step
        // finds its generation gone and does nothing. Before the guard below, because during
        // the settle window nothing is running yet.
        pendingBinding += 1
        guard isRunning else { return }
        isRunning = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // Voice processing is switched off with the recording. Leaving it on keeps the audio
        // unit and its buffers alive for a figure that is not listening to anything.
        //
        // Only when it was on. Switching it off on an engine that never had it is not the
        // no-op it looks like: it leaves the input node reporting the generic default instead
        // of the device, and the next recording starts on a node bound to nothing.
        //
        // `hasEchoCancellation` is not the right question here (review M5, 2026-08-28): it
        // means "the unit is on AND the readback says usable", and the input side enabling
        // while the output side throws leaves it false while the input is still on the
        // unit — this guard used to skip disabling it in exactly that case.
        guard isVoiceProcessingEngagedOnThisEngine else { return }
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        try? engine.outputNode.setVoiceProcessingEnabled(false)
    }

    /// What the input path looks like right now, without recording a single sample.
    ///
    /// Enabling voice processing and reading a format do not open the microphone, so this
    /// runs without a permission prompt and without anything being heard — which is what
    /// makes it usable as a check on a machine somebody is working on.
    ///
    /// It does leave a mark all the same: once the voice-processing unit has been touched,
    /// every input node built afterwards in this process is slower to bind and sometimes
    /// binds to nothing (measured 2026-08-28, see `engineBoundTo`). This is a diagnostic for
    /// a run that prints and exits, not something to call inside a session that will record.
    public func inspect() -> [String: String] {
        let input = engine.inputNode
        var enabling = "nicht versucht"
        do {
            try input.setVoiceProcessingEnabled(true)
            try engine.outputNode.setVoiceProcessingEnabled(true)
            enabling = "ok"
        } catch {
            enabling = "\(error.localizedDescription)"
        }
        let format = input.outputFormat(forBus: 0)
        let report: [String: String] = [
            "voiceProcessingEnabling": enabling,
            "voiceProcessingActive": String(input.isVoiceProcessingEnabled),
            "inputSampleRate": String(format.sampleRate),
            "inputChannels": String(format.channelCount),
            "targetSampleRate": String(target.sampleRate),
            "targetChannels": String(target.channelCount),
            "resampler": String(Resampler(from: format, to: target) != nil),
        ]
        try? input.setVoiceProcessingEnabled(false)
        try? engine.outputNode.setVoiceProcessingEnabled(false)
        return report
    }
}

/// One microphone for the wakeword listener and the dictation, built on first use.
///
/// The two never run at once, and the handover between them is the moment that costs: the
/// listener releases its engine and the dictation builds another one on the same input device
/// in the same main-actor turn — the pattern `bindEngine` exists to survive. Measured
/// 2026-08-28: a device that a released engine had held publishes three input channels for as
/// long as that engine lives and one again eleven milliseconds later, and a fresh engine binds
/// to the device only from about 254 milliseconds on. Nothing waited for that window on this
/// path (review, 2026-09-03).
///
/// Sharing one instance takes the release out of the handover altogether: the dictation goes on
/// with the engine the listener was using, which is exactly what two dictations in a row
/// already do.
///
/// Since 2026-09-05 the listener does not even stop it — `WakewordListener.pause` hands over
/// the `onBuffer` subscription and leaves the device running, and `VoiceController` does not
/// start a running one. The stream is continuous across the handover, so nothing has to settle
/// and nothing spoken into it is lost.
///
/// Lazy, because a shell that never records must not build an `AVAudioEngine` at launch.
@MainActor
public final class SharedMicrophone {
    private let build: @MainActor () -> AudioCapturing
    private var capture: AudioCapturing?

    /// - Parameter build: what to build on first use. A test hands in a fake, so nothing of
    ///   Core Audio is touched to check that it is built once.
    public init(build: @escaping @MainActor () -> AudioCapturing = { MicrophoneCapture() }) {
        self.build = build
    }

    public func capturing() -> AudioCapturing {
        if let capture { return capture }
        let built = build()
        capture = built
        return built
    }
}

/// One `AVAudioConverter`, used from the audio thread only.
///
/// Not on the main actor on purpose: it is called from the tap, where hopping to the main
/// actor first would mean carrying float buffers across the boundary ten times a second
/// instead of the bytes that are actually needed.
private final class Resampler: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let target: AVAudioFormat

    init?(from source: AVAudioFormat, to target: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: source, to: target) else { return nil }
        self.converter = converter
        self.target = target
    }

    /// The buffer as interleaved signed 16-bit little-endian bytes, or nil when the converter
    /// produced nothing.
    func data(from buffer: AVAudioPCMBuffer) -> Data? {
        let ratio = target.sampleRate / buffer.format.sampleRate
        // Room for the resampler's own filter delay on top of the arithmetic; a capacity that
        // is too small silently truncates.
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            return nil
        }
        // The buffer is handed over through a box rather than through a captured variable:
        // the converter's input block is declared as one that may run concurrently, and a
        // plain `var` in there is a data race the compiler is right to point at. The box is
        // only ever touched from the one call below.
        let once = InputBufferOnce(buffer)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            guard let input = once.take() else {
                // One input buffer per call. Saying "no data now" ends the conversion instead
                // of the converter waiting for more.
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            return input
        }
        guard status != .error, output.frameLength > 0,
              let channel = output.int16ChannelData else { return nil }
        return Data(
            bytes: channel[0],
            count: Int(output.frameLength) * Int(target.channelCount) * EnergyVAD.sampleBytes)
    }
}

/// Hands one buffer to the converter's input block, exactly once.
///
/// Unchecked because an `AVAudioPCMBuffer` is not `Sendable` and the block is declared as
/// possibly concurrent. It is not: the converter calls it synchronously, on the thread that
/// called `convert`, before that call returns.
private final class InputBufferOnce: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }

    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}

/// The microphone permission, through `AVCaptureDevice`.
///
/// The prompt macOS shows carries the text of `NSMicrophoneUsageDescription` from
/// `Info.plist`; without that key the app is terminated instead of asked. The request happens
/// on first actual use, never at launch.
@MainActor
public final class SystemMicrophoneAuthorization: MicrophoneAuthorizing {
    public init() {}

    public var authorization: MicrophoneAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .undetermined
        case .denied: return .denied
        // A profile forbids it. Kept apart from a denial because the two differ in what the
        // person can do about them, and saying "in den Systemeinstellungen freigeben" to
        // somebody whose machine is managed is an instruction that cannot be followed.
        case .restricted: return .restricted
        @unknown default: return .denied
        }
    }

    public func requestAuthorization() async -> MicrophoneAuthorization {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted ? .granted : .denied)
            }
        }
    }
}
