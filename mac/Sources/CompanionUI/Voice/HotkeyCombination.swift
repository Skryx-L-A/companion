// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Carbon.HIToolbox
import Foundation

/// A key combination for push to talk, in the two shapes it has to exist in: the text that is
/// written into the settings and the pair of numbers Carbon registers.
///
/// The keys on offer are a short list on purpose. A free-form recorder would let a person take
/// Command-Q away from every app on the machine, and a global combination is exactly the kind
/// of setting that is hard to undo once it swallowed the key you needed to undo it with.
public struct HotkeyCombination: Sendable, Equatable, Hashable {
    /// The keys push to talk can sit on.
    public enum Key: String, Sendable, CaseIterable, Hashable {
        case space
        case f13
        case f14
        case f19

        /// Carbon virtual key code. From `HIToolbox/Events.h`, not from memory.
        public var carbonKeyCode: UInt32 {
            switch self {
            case .space: return UInt32(kVK_Space)
            case .f13: return UInt32(kVK_F13)
            case .f14: return UInt32(kVK_F14)
            case .f19: return UInt32(kVK_F19)
            }
        }

        public var label: String {
            switch self {
            case .space: return "Space"
            case .f13: return "F13"
            case .f14: return "F14"
            case .f19: return "F19"
            }
        }
    }

    /// The four modifiers, in the order macOS writes them.
    public struct Modifiers: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)

        /// Carbon modifier mask, the second argument of `RegisterEventHotKey`.
        public var carbonMask: UInt32 {
            var mask: UInt32 = 0
            if contains(.control) { mask |= UInt32(controlKey) }
            if contains(.option) { mask |= UInt32(optionKey) }
            if contains(.shift) { mask |= UInt32(shiftKey) }
            if contains(.command) { mask |= UInt32(cmdKey) }
            return mask
        }

        /// The symbols in the order the system menus show them.
        public var symbols: String {
            var text = ""
            if contains(.control) { text += "\u{2303}" }
            if contains(.option) { text += "\u{2325}" }
            if contains(.shift) { text += "\u{21E7}" }
            if contains(.command) { text += "\u{2318}" }
            return text
        }

        /// The words the settings text uses, so a combination survives a round trip through
        /// `UserDefaults` as something a person can read.
        var names: [String] {
            var parts: [String] = []
            if contains(.control) { parts.append("ctrl") }
            if contains(.option) { parts.append("alt") }
            if contains(.shift) { parts.append("shift") }
            if contains(.command) { parts.append("cmd") }
            return parts
        }

        static func named(_ name: String) -> Modifiers? {
            switch name {
            case "ctrl", "control": return .control
            case "alt", "option", "opt": return .option
            case "shift": return .shift
            case "cmd", "command": return .command
            default: return nil
            }
        }
    }

    public var key: Key
    public var modifiers: Modifiers

    public init(key: Key, modifiers: Modifiers) {
        self.key = key
        self.modifiers = modifiers
    }

    /// The default, as named in the task for phase 1b. Not a quiet choice: see
    /// `systemConflict`.
    public static let pushToTalkDefault = HotkeyCombination(
        key: .space, modifiers: [.control, .option])

    /// What the settings offer. Function keys without a modifier are in the list because they
    /// are the only keys on a Mac that no system shortcut claims.
    public static let choices: [HotkeyCombination] = [
        HotkeyCombination(key: .space, modifiers: [.control, .option]),
        HotkeyCombination(key: .space, modifiers: [.control, .shift]),
        HotkeyCombination(key: .space, modifiers: [.command, .option]),
        HotkeyCombination(key: .f13, modifiers: []),
        HotkeyCombination(key: .f14, modifiers: []),
        HotkeyCombination(key: .f19, modifiers: []),
    ]

    /// What the settings page shows: `⌃⌥Space`.
    public var display: String { modifiers.symbols + key.label }

    /// What is written into the settings: `ctrl+alt+space`.
    public var settingsValue: String { (modifiers.names + [key.rawValue]).joined(separator: "+") }

    /// A sentence naming the system shortcut this combination collides with, or nil when it
    /// collides with none that ships switched on.
    ///
    /// Said out loud rather than quietly avoided, because the combination is the one the task
    /// names as the default. macOS has it under Keyboard, Input Sources; a system shortcut
    /// wins over `RegisterEventHotKey`, so on a machine with two input sources push to talk
    /// would switch the keyboard layout instead of recording.
    public var systemConflict: String? {
        if key == .space && modifiers == [.control, .option] {
            return "macOS benutzt diese Kombination fuer den Wechsel zur vorherigen Eingabequelle. Wer mehr als eine Tastaturbelegung hat, nimmt besser eine andere."
        }
        if key == .space && modifiers == [.control] {
            return "macOS benutzt diese Kombination fuer den Wechsel der Eingabequelle."
        }
        return nil
    }

    /// Reads `ctrl+alt+space`. Nil for anything that is not a combination this shell can
    /// register, so a hand-edited settings file falls back to the default instead of silently
    /// registering something else.
    public init?(settingsValue: String) {
        let parts = settingsValue.lowercased().split(separator: "+").map(String.init)
        guard let last = parts.last, let key = Key(rawValue: last) else { return nil }
        var modifiers: Modifiers = []
        for name in parts.dropLast() {
            guard let modifier = Modifiers.named(name) else { return nil }
            modifiers.insert(modifier)
        }
        self.key = key
        self.modifiers = modifiers
    }
}
