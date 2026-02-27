//
//  GlobalShortcutService.swift
//  SuperCapture
//
//  Global keyboard shortcut for toggling recording.
//

import AppKit
import OSLog

/// Monitors for a global keyboard shortcut and invokes a callback when triggered.
@MainActor
@Observable
final class GlobalShortcutService {

    // MARK: - Properties

    /// Whether the global shortcut is enabled.
    var isEnabled: Bool {
        get {
            access(keyPath: \.isEnabled)
            return UserDefaults.standard.object(forKey: "shortcutEnabled") as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.isEnabled) {
                UserDefaults.standard.set(newValue, forKey: "shortcutEnabled")
            }
            reinstallMonitors()
        }
    }

    /// The key code for the shortcut (default: 15 = "R").
    var keyCode: UInt16 {
        get {
            access(keyPath: \.keyCode)
            let stored = UserDefaults.standard.object(forKey: "shortcutKeyCode")
            return (stored as? UInt16) ?? 15 // "R" key
        }
        set {
            withMutation(keyPath: \.keyCode) {
                UserDefaults.standard.set(newValue, forKey: "shortcutKeyCode")
            }
            reinstallMonitors()
        }
    }

    /// The modifier flags for the shortcut (default: Cmd+Shift).
    var modifierFlags: NSEvent.ModifierFlags {
        get {
            access(keyPath: \.modifierFlags)
            let stored = UserDefaults.standard.object(forKey: "shortcutModifierFlags")
            let raw = (stored as? UInt) ?? NSEvent.ModifierFlags([.command, .shift]).rawValue
            return NSEvent.ModifierFlags(rawValue: raw)
        }
        set {
            withMutation(keyPath: \.modifierFlags) {
                UserDefaults.standard.set(newValue.rawValue, forKey: "shortcutModifierFlags")
            }
            reinstallMonitors()
        }
    }

    /// Human-readable description of the current shortcut.
    var shortcutDescription: String {
        guard isEnabled else { return "Not set" }
        var parts: [String] = []
        let flags = modifierFlags
        if flags.contains(.control) { parts.append("Ctrl") }
        if flags.contains(.option) { parts.append("Opt") }
        if flags.contains(.shift) { parts.append("Shift") }
        if flags.contains(.command) { parts.append("Cmd") }
        parts.append(keyName(for: keyCode))
        return parts.joined(separator: "+")
    }

    /// Callback invoked on the main actor when the shortcut is triggered.
    var onToggle: (() -> Void)?

    /// Set once on init and cleared in deinit; accessed from main actor only during normal operation.
    nonisolated(unsafe) private var globalMonitor: Any?
    nonisolated(unsafe) private var localMonitor: Any?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "SuperCapture", category: "GlobalShortcutService")

    // MARK: - Lifecycle

    init() {
        // Monitors are installed lazily via start() to avoid blocking
        // the MenuBarExtra event loop during app initialization.
    }

    /// Installs the event monitors. Call once after app startup.
    func start() {
        guard globalMonitor == nil else { return }
        installMonitors()
    }

    deinit {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
    }

    // MARK: - Configuration

    /// Disables the shortcut and removes all monitors.
    func clearShortcut() {
        isEnabled = false
    }

    /// Sets a new key combo and enables the shortcut. Single reinstall.
    func updateShortcut(keyCode newKeyCode: UInt16, modifierFlags newFlags: NSEvent.ModifierFlags) {
        withMutation(keyPath: \.keyCode) {
            UserDefaults.standard.set(newKeyCode, forKey: "shortcutKeyCode")
        }
        withMutation(keyPath: \.modifierFlags) {
            UserDefaults.standard.set(newFlags.rawValue, forKey: "shortcutModifierFlags")
        }
        withMutation(keyPath: \.isEnabled) {
            UserDefaults.standard.set(true, forKey: "shortcutEnabled")
        }
        reinstallMonitors()
    }

    // MARK: - Monitor Management

    private func installMonitors() {
        guard isEnabled else {
            logger.info("Global shortcut disabled")
            return
        }

        let targetKeyCode = keyCode
        let targetFlags = modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Global monitor: fires when the app is NOT focused
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            let eventFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == targetKeyCode && eventFlags == targetFlags {
                Task { @MainActor [weak self] in
                    self?.onToggle?()
                }
            }
        }

        // Local monitor: fires when the app IS focused
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let eventFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == targetKeyCode && eventFlags == targetFlags {
                Task { @MainActor [weak self] in
                    self?.onToggle?()
                }
                return nil // consume the event
            }
            return event
        }

        logger.info("Global shortcut installed: \(self.shortcutDescription)")
    }

    private func removeMonitors() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        globalMonitor = nil
        localMonitor = nil
    }

    private func reinstallMonitors() {
        removeMonitors()
        installMonitors()
    }

    // MARK: - Key Name Mapping

    private func keyName(for keyCode: UInt16) -> String {
        // Common key codes to human-readable names
        switch keyCode {
        case 0: return "A"
        case 1: return "S"
        case 2: return "D"
        case 3: return "F"
        case 4: return "H"
        case 5: return "G"
        case 6: return "Z"
        case 7: return "X"
        case 8: return "C"
        case 9: return "V"
        case 11: return "B"
        case 12: return "Q"
        case 13: return "W"
        case 14: return "E"
        case 15: return "R"
        case 16: return "Y"
        case 17: return "T"
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 22: return "6"
        case 23: return "5"
        case 24: return "="
        case 25: return "9"
        case 26: return "7"
        case 27: return "-"
        case 28: return "8"
        case 29: return "0"
        case 30: return "]"
        case 31: return "O"
        case 32: return "U"
        case 33: return "["
        case 34: return "I"
        case 35: return "P"
        case 37: return "L"
        case 38: return "J"
        case 40: return "K"
        case 41: return ";"
        case 43: return ","
        case 44: return "/"
        case 45: return "N"
        case 46: return "M"
        case 47: return "."
        case 49: return "Space"
        case 51: return "Delete"
        case 53: return "Esc"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 99: return "F3"
        case 100: return "F8"
        case 101: return "F9"
        case 103: return "F11"
        case 105: return "F13"
        case 109: return "F10"
        case 111: return "F12"
        case 118: return "F4"
        case 120: return "F2"
        case 122: return "F1"
        default: return "Key(\(keyCode))"
        }
    }
}
