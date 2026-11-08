import AppKit
import SwiftUI

enum MouseTriggerButton: Int, CaseIterable, Identifiable {
    case left = 0, right = 1, middle = 2, side4 = 3, side5 = 4
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .left: return L10n.text("Botão esquerdo")
        case .right: return L10n.text("Botão direito")
        case .middle: return L10n.text("Botão do meio (rodinha)")
        case .side4: return L10n.text("Botão lateral 4")
        case .side5: return L10n.text("Botão lateral 5")
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

    @Published var language: AppLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: "appLanguage")
            if language == .system {
                defaults.removeObject(forKey: "AppleLanguages")
            } else {
                defaults.set([language.rawValue], forKey: "AppleLanguages")
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        language = defaults.string(forKey: "appLanguage").flatMap(AppLanguage.init(rawValue:)) ?? .system
        wheelDiameter = Self.validDiameter((defaults.object(forKey: "wheelDiameter") as? Double) ?? Self.defaultDiameter)
        holdDelay = Self.validDelay((defaults.object(forKey: "wheelHoldDelay") as? Double) ?? Self.defaultDelay)
        triggerButton = (defaults.object(forKey: "wheelTriggerButton") as? Int)
            .flatMap(MouseTriggerButton.init(rawValue:)) ?? .right
    }
    var gestureHint: String {
        L10n.text("Segure o %@ por %@ ms, aponte e solte.", triggerButton.title.lowercased(), String(Int((holdDelay * 1000).rounded())))
    }
    func reset() {
        wheelDiameter = Self.defaultDiameter
        holdDelay = Self.defaultDelay
        triggerButton = .right
        language = .system
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
    @State private var showsRestartDialog = false
    @State private var isRestarting = false
    @State private var restartError: String?
    var body: some View {
        Form {
            Section(L10n.text("Idioma")) {
                Picker(L10n.text("Idioma"), selection: $preferences.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title).tag(language)
                    }
                }
                Text(L10n.text("Encerre e abra o AppWheel para aplicar a mudança de idioma."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L10n.text("Aparência")) {
                VStack(spacing: 10) {
                    LabeledContent(L10n.text("Tamanho da roda"), value: "\(Int(preferences.wheelDiameter)) pt")
                    Slider(value: $preferences.wheelDiameter, in: 260...520, step: 10) {
                        Text(L10n.text("Tamanho da roda"))
                    }
                    .labelsHidden()
                }
            }
            Section(L10n.text("Gesto de abertura")) {
                VStack(spacing: 10) {
                    LabeledContent(L10n.text("Tempo para abrir"), value: "\(Int((preferences.holdDelay * 1000).rounded())) ms")
                    Slider(value: $preferences.holdDelay, in: 0.15...1.0, step: 0.05) {
                        Text(L10n.text("Tempo para abrir"))
                    }
                    .labelsHidden()
                }
                Picker(L10n.text("Botão do mouse"), selection: $preferences.triggerButton) {
                    ForEach(MouseTriggerButton.allCases) { button in
                        Text(button.title).tag(button)
                    }
                }
                Text(L10n.text("Cliques rápidos e arrastos continuam sendo encaminhados ao aplicativo. As alterações valem para o próximo gesto."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text(L10n.text("As preferências são salvas automaticamente."))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.text("Restaurar padrão")) { preferences.reset() }
            }
        }
        .formStyle(.grouped)
        .disabled(isRestarting)
        .onChange(of: preferences.language) { _, _ in
            restartError = nil
            showsRestartDialog = true
        }
        .alert(L10n.text(restartError == nil ? "Reiniciar AppWheel?" : "Não foi possível reiniciar"),
               isPresented: $showsRestartDialog) {
            if restartError != nil {
                Button(L10n.text("OK"), role: .cancel) { restartError = nil }
            } else {
                Button(L10n.text("Reiniciar agora")) {
                    isRestarting = true
                    Task { @MainActor in
                        do {
                            try await AppRelaunch.restart()
                        } catch {
                            isRestarting = false
                            restartError = error.localizedDescription
                            showsRestartDialog = true
                        }
                    }
                }
                Button(L10n.text("Depois"), role: .cancel) {}
            }
        } message: {
            Text(restartError ?? L10n.text("O AppWheel precisa reiniciar para aplicar o novo idioma. Suas preferências serão mantidas."))
        }
    }
}
