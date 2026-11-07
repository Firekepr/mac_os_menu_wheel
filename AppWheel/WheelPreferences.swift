import AppKit
import SwiftUI

enum MouseTriggerButton: Int, CaseIterable, Identifiable {
    case left = 0, right = 1, middle = 2, side4 = 3, side5 = 4
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .left: return "Botão esquerdo"
        case .right: return "Botão direito"
        case .middle: return "Botão do meio (rodinha)"
        case .side4: return "Botão lateral 4"
        case .side5: return "Botão lateral 5"
        }
    }
    var down: CGEventType { self == .left ? .leftMouseDown : self == .right ? .rightMouseDown : .otherMouseDown }
    var drag: CGEventType { self == .left ? .leftMouseDragged : self == .right ? .rightMouseDragged : .otherMouseDragged }
    var up: CGEventType { self == .left ? .leftMouseUp : self == .right ? .rightMouseUp : .otherMouseUp }
    func matches(_ event: CGEvent, type: CGEventType, phase: CGEventType) -> Bool {
        type == phase && event.getIntegerValueField(.mouseEventButtonNumber) == Int64(rawValue)
    }
}

@MainActor
final class WheelPreferences: ObservableObject {
    static let defaultDiameter = 380.0
    static let defaultDelay = 0.3
    private let defaults: UserDefaults
    @Published var wheelDiameter: Double {
        didSet {
            let value = Self.validDiameter(wheelDiameter)
            if wheelDiameter != value { wheelDiameter = value }
            defaults.set(value, forKey: "wheelDiameter")
        }
    }
    @Published var holdDelay: Double {
        didSet {
            let value = Self.validDelay(holdDelay)
            if holdDelay != value { holdDelay = value }
            defaults.set(value, forKey: "wheelHoldDelay")
        }
    }
    @Published var triggerButton: MouseTriggerButton {
        didSet { defaults.set(triggerButton.rawValue, forKey: "wheelTriggerButton") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        wheelDiameter = Self.validDiameter((defaults.object(forKey: "wheelDiameter") as? Double) ?? Self.defaultDiameter)
        holdDelay = Self.validDelay((defaults.object(forKey: "wheelHoldDelay") as? Double) ?? Self.defaultDelay)
        triggerButton = (defaults.object(forKey: "wheelTriggerButton") as? Int)
            .flatMap(MouseTriggerButton.init(rawValue:)) ?? .right
    }
    var gestureHint: String {
        "Segure o \(triggerButton.title.lowercased()) por \(Int((holdDelay * 1000).rounded())) ms, aponte e solte."
    }
    func reset() {
        wheelDiameter = Self.defaultDiameter
        holdDelay = Self.defaultDelay
        triggerButton = .right
    }
    private static func validDiameter(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 260), 520) : defaultDiameter
    }
    private static func validDelay(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0.15), 1.0) : defaultDelay
    }
}

struct WheelPreferencesView: View {
    @ObservedObject var preferences: WheelPreferences
    var body: some View {
        Form {
            Section("Aparência") {
                LabeledContent("Tamanho da roda", value: "\(Int(preferences.wheelDiameter)) pt")
                Slider(value: $preferences.wheelDiameter, in: 260...520, step: 10) {
                    Text("Tamanho da roda")
                }
            }
            Section("Gesto de abertura") {
                LabeledContent("Tempo para abrir", value: "\(Int((preferences.holdDelay * 1000).rounded())) ms")
                Slider(value: $preferences.holdDelay, in: 0.15...1.0, step: 0.05) {
                    Text("Tempo para abrir")
                }
                Picker("Botão do mouse", selection: $preferences.triggerButton) {
                    ForEach(MouseTriggerButton.allCases) { button in
                        Text(button.title).tag(button)
                    }
                }
                Text("Cliques rápidos e arrastos continuam sendo encaminhados ao aplicativo. As alterações valem para o próximo gesto.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("As preferências são salvas automaticamente.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Restaurar padrão") { preferences.reset() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 380)
    }
}
