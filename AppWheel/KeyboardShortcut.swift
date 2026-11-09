import AppKit
import Carbon
import SwiftUI

struct WheelKeyboardShortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let keyLabel: String

    var isValid: Bool {
        let allowed = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        guard keyCode < 128, !(54...63).contains(keyCode), keyCode != 53,
              modifiers & ~allowed == 0,
              modifiers & UInt32(cmdKey | optionKey | controlKey) != 0,
              !keyLabel.isEmpty else { return false }
        // Do not replace the application's standard Quit/Hide/Close/Minimize.
        if modifiers == UInt32(cmdKey), [12, 13, 4, 46, 48, 49].contains(keyCode) { return false }
        if modifiers == UInt32(cmdKey | shiftKey), keyCode == 48 { return false }
        if modifiers & UInt32(cmdKey | controlKey) == UInt32(cmdKey | controlKey), keyCode == 12 { return false }
        return true
    }

    var title: String {
        var symbols = ""
        if modifiers & UInt32(controlKey) != 0 { symbols += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { symbols += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { symbols += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { symbols += "⌘" }
        return symbols + keyLabel
    }

    init(keyCode: UInt32, modifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        let special: [UInt16: String] = [36: "↩", 48: "⇥", 49: "␣", 51: "⌫", 76: "⌤",
                                       123: "←", 124: "→", 125: "↓", 126: "↑",
                                       122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
                                       98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"]
        let label = special[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? ""
        self.init(keyCode: UInt32(event.keyCode), modifiers: modifiers, keyLabel: label)
        guard isValid else { return nil }
    }
}

/// Uses the OS hot-key registry rather than watching every keystroke at idle.
/// Registration also detects combinations already reserved by other apps.
@MainActor
final class WheelHotKey {
    var pressed: (() -> Void)?
    var released: (() -> Void)?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private static let signature: OSType = 0x4150574C

    func configure(_ shortcut: WheelKeyboardShortcut?) -> String? {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        if let handler { RemoveEventHandler(handler) }
        handler = nil
        guard let shortcut else { return nil }
        guard shortcut.isValid else { return L10n.text("Escolha uma combinação com ⌘, ⌥ ou ⌃ e uma tecla.") }
        if handler == nil {
            let callback: EventHandlerUPP = { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                      id.signature == WheelHotKey.signature, id.id == 1 else { return OSStatus(eventNotHandledErr) }
                return MainActor.assumeIsolated {
                    let owner = Unmanaged<WheelHotKey>.fromOpaque(context).takeUnretainedValue()
                    if GetEventKind(event) == UInt32(kEventHotKeyPressed) { owner.pressed?() }
                    else { owner.released?() }
                    return noErr
                }
            }
            var events = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                          EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
            let result = InstallEventHandler(GetEventDispatcherTarget(), callback, events.count, &events,
                                             Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard result == noErr else { return L10n.text("Não foi possível ativar o atalho. Tente novamente.") }
        }
        let result = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
                                         EventHotKeyID(signature: Self.signature, id: 1),
                                         GetEventDispatcherTarget(), 0, &hotKey)
        if result != noErr {
            if let handler { RemoveEventHandler(handler) }
            handler = nil
            return L10n.text("Este atalho está indisponível. Escolha outra combinação.")
        }
        return nil
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}

struct KeyboardShortcutSettings: View {
    @ObservedObject var preferences: WheelPreferences
    @State private var isRecording = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.text("Atalho pelo teclado"))
                Spacer()
                Button(preferences.keyboardShortcut?.title ?? L10n.text("Gravar atalho…")) { isRecording = true }
                    .accessibilityLabel(L10n.text("Gravar atalho pelo teclado"))
                    .accessibilityValue(preferences.keyboardShortcut?.title ?? L10n.text("Nenhum atalho"))
                if preferences.keyboardShortcut != nil {
                    Button(L10n.text("Remover")) { preferences.keyboardShortcut = nil }
                }
            }
            Text(L10n.text("Segure o atalho, aponte e solte para escolher. Esc cancela. As exceções por aplicativo também se aplicam."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = preferences.keyboardShortcutError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .sheet(isPresented: $isRecording) {
            KeyboardShortcutRecorder(preferences: preferences)
        }
    }
}

private struct KeyboardShortcutRecorder: View {
    @ObservedObject var preferences: WheelPreferences
    @Environment(\.dismiss) private var dismiss
    @State private var candidate: WheelKeyboardShortcut?
    @State private var error: String?
    @State private var monitor: Any?

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "keyboard").font(.largeTitle).foregroundStyle(Color.accentColor)
            Text(L10n.text("Gravar atalho pelo teclado")).font(.title2.bold())
            Text(L10n.text("Pressione uma combinação com ⌘, ⌥ ou ⌃ e uma tecla."))
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Text(candidate?.title ?? L10n.text("Aguardando combinação…"))
                .font(candidate == nil ? .body : .system(size: 22, weight: .semibold))
                .foregroundStyle(candidate == nil ? Color.secondary : Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, minHeight: 60)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button(L10n.text("Cancelar")) { dismiss() }
                Spacer()
                Button(L10n.text("Salvar atalho")) {
                    preferences.keyboardShortcut = candidate
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(candidate == nil)
            }
        }
        .padding(24).frame(width: 400)
        .onAppear {
            preferences.isRecordingKeyboardShortcut = true
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let consumed = MainActor.assumeIsolated {
                    guard NSApplication.shared.isActive else { return false }
                    if event.keyCode == 53 { dismiss(); return true }
                    let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
                    if modifiers.isEmpty, event.keyCode == 48 { return false }
                    if modifiers.isEmpty, event.keyCode == 36, let candidate {
                        preferences.keyboardShortcut = candidate
                        dismiss()
                        return true
                    }
                    guard !event.isARepeat else { return true }
                    if let shortcut = WheelKeyboardShortcut(event: event) {
                        candidate = shortcut
                        error = nil
                    } else {
                        candidate = nil
                        error = L10n.text("Escolha uma combinação com ⌘, ⌥ ou ⌃ e uma tecla.")
                    }
                    return true
                }
                return consumed ? nil : event
            }
        }
        .onDisappear {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            preferences.isRecordingKeyboardShortcut = false
        }
    }
}
