// SPDX-License-Identifier: AGPL-3.0-only

import Carbon.HIToolbox
import Foundation

/// Why a hotkey could not be taken.
public enum HotkeyFailure: Error, Equatable, Sendable {
    /// `InstallEventHandler` refused.
    case handlerRefused(OSStatus)
    /// `RegisterEventHotKey` refused. Usually because another application holds the
    /// combination already.
    case registrationRefused(OSStatus)

    public var message: String {
        switch self {
        case .handlerRefused(let status):
            return "Die Tastenueberwachung liess sich nicht einrichten (Fehler \(status))."
        case .registrationRefused(let status):
            return "Die Tastenkombination ist schon belegt oder wurde abgelehnt (Fehler \(status))."
        }
    }
}

/// Takes a key combination for as long as the shell wants it, wherever the person is typing.
@MainActor
public protocol HotkeyRegistering: AnyObject {
    /// What is currently held, nil while nothing is.
    var registered: HotkeyCombination? { get }
    /// Takes the combination. `onPress` and `onRelease` are what push to talk is: the
    /// microphone runs between the two.
    func register(
        _ combination: HotkeyCombination,
        onPress: @escaping () -> Void,
        onRelease: @escaping () -> Void
    ) throws
    func unregister()
}

/// The Carbon hotkey API.
///
/// `RegisterEventHotKey` is the one way on macOS to get a global key combination **without**
/// asking for accessibility rights: the window server delivers the two events to this process
/// and nothing else about other applications becomes readable. The alternative,
/// `CGEvent.tapCreate`, sees every keystroke on the machine and needs the person to unlock
/// Accessibility for it — for a push-to-talk key that is a trade nobody should have to make.
///
/// Not deprecated despite living in Carbon: `RegisterEventHotKey` is the API Apple still
/// documents for global hotkeys, and it is what the system's own shortcut recorders use.
@MainActor
public final class CarbonHotkeyRegistrar: HotkeyRegistering {
    public private(set) var registered: HotkeyCombination?

    // `nonisolated(unsafe)` so `deinit` can give both back. Carbon holds a raw pointer to
    // this object, so a registration that outlived it would call into freed memory; the two
    // handles are otherwise only ever touched from the main actor.
    private nonisolated(unsafe) var hotkey: EventHotKeyRef?
    private nonisolated(unsafe) var handler: EventHandlerRef?
    private var onPress: (() -> Void)?
    private var onRelease: (() -> Void)?
    /// Identifies this registration in the Carbon event. One hotkey per shell, so one id.
    private let identifier: UInt32 = 1
    private static let signature = fourCharCode("cptt")

    public init() {}

    deinit {
        // Carbon holds a raw pointer to this object, so both registrations have to go with
        // it. `unregister()` is main-actor bound and cannot be called from here.
        if let hotkey { UnregisterEventHotKey(hotkey) }
        if let handler { RemoveEventHandler(handler) }
    }

    public func register(
        _ combination: HotkeyCombination,
        onPress: @escaping () -> Void,
        onRelease: @escaping () -> Void
    ) throws {
        unregister()
        self.onPress = onPress
        self.onRelease = onRelease

        var events = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let context = Unmanaged.passUnretained(self).toOpaque()
        var installed: EventHandlerRef?
        let handlerStatus = InstallEventHandler(
            GetEventDispatcherTarget(), companionHotkeyHandler, events.count, &events,
            context, &installed)
        guard handlerStatus == noErr, let installed else {
            self.onPress = nil
            self.onRelease = nil
            throw HotkeyFailure.handlerRefused(handlerStatus)
        }
        handler = installed

        var reference: EventHotKeyRef?
        let hotkeyId = EventHotKeyID(signature: Self.signature, id: identifier)
        let status = RegisterEventHotKey(
            combination.key.carbonKeyCode, combination.modifiers.carbonMask, hotkeyId,
            GetEventDispatcherTarget(), 0, &reference)
        guard status == noErr, let reference else {
            RemoveEventHandler(installed)
            handler = nil
            self.onPress = nil
            self.onRelease = nil
            throw HotkeyFailure.registrationRefused(status)
        }
        hotkey = reference
        registered = combination
    }

    public func unregister() {
        if let hotkey { UnregisterEventHotKey(hotkey) }
        if let handler { RemoveEventHandler(handler) }
        hotkey = nil
        handler = nil
        onPress = nil
        onRelease = nil
        registered = nil
    }

    /// Called from the Carbon handler, which runs on the main thread of the event dispatcher.
    fileprivate func handle(eventKind: UInt32, id: UInt32) {
        guard id == identifier else { return }
        switch Int(eventKind) {
        case kEventHotKeyPressed: onPress?()
        case kEventHotKeyReleased: onRelease?()
        default: break
        }
    }
}

/// Four-character code, the way Carbon writes a signature.
private func fourCharCode(_ text: String) -> OSType {
    var code: OSType = 0
    for byte in text.utf8.prefix(4) { code = (code << 8) | OSType(byte) }
    return code
}

/// The C callback Carbon holds. Reads which hotkey the event is about and hands it to the
/// registrar the context points at.
private func companionHotkeyHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ context: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let context else { return OSStatus(eventNotHandledErr) }
    var hotkeyId = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &hotkeyId)
    guard status == noErr else { return status }
    let kind = GetEventKind(event)
    let registrar = Unmanaged<CarbonHotkeyRegistrar>.fromOpaque(context).takeUnretainedValue()
    // Carbon dispatches this on the main thread; there is no other thread the event
    // dispatcher of an application runs on.
    MainActor.assumeIsolated { registrar.handle(eventKind: kind, id: hotkeyId.id) }
    return noErr
}
