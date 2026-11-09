import AppKit
import Carbon

MainActor.assumeIsolated {
    let suite = "AppWheel.KeyboardChecks.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = WheelPreferences(defaults: defaults)
    precondition(preferences.keyboardShortcut == nil, "A fresh install must not reserve a shortcut")
    let chosen = WheelKeyboardShortcut(keyCode: 40, modifiers: UInt32(controlKey | optionKey), keyLabel: "K")
    precondition(chosen.isValid && chosen.title == "⌃⌥K")
    preferences.keyboardShortcut = chosen
    precondition(WheelPreferences(defaults: defaults).keyboardShortcut == chosen)
    preferences.keyboardShortcut = nil
    precondition(defaults.object(forKey: "wheelKeyboardShortcut") == nil)
    precondition(WheelPreferences(defaults: defaults).keyboardShortcut == nil)
    preferences.keyboardShortcut = chosen
    preferences.reset()
    precondition(WheelPreferences(defaults: defaults).keyboardShortcut == nil)
    let plain = WheelKeyboardShortcut(keyCode: 40, modifiers: 0, keyLabel: "K")
    let shiftOnly = WheelKeyboardShortcut(keyCode: 40, modifiers: UInt32(shiftKey), keyLabel: "K")
    let quit = WheelKeyboardShortcut(keyCode: 12, modifiers: UInt32(cmdKey), keyLabel: "Q")
    let escape = WheelKeyboardShortcut(keyCode: 53, modifiers: UInt32(cmdKey), keyLabel: "⎋")
    let modifierOnly = WheelKeyboardShortcut(keyCode: 55, modifiers: UInt32(cmdKey), keyLabel: "⌘")
    precondition(!plain.isValid && !shiftOnly.isValid && !quit.isValid && !escape.isValid && !modifierOnly.isValid)
    defaults.set(Data("invalid".utf8), forKey: "wheelKeyboardShortcut")
    precondition(WheelPreferences(defaults: defaults).keyboardShortcut == nil)
    defaults.set(try! JSONEncoder().encode(quit), forKey: "wheelKeyboardShortcut")
    precondition(WheelPreferences(defaults: defaults).keyboardShortcut == nil)
    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .option, .capsLock],
                                timestamp: 0, windowNumber: 0, context: nil, characters: "k",
                                charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40)!
    precondition(WheelKeyboardShortcut(event: event) == chosen)
    print("Keyboard checks passed: disabled default, persistence, removal, reset, invalid data, modifiers, protected keys, recording normalization.")
}
