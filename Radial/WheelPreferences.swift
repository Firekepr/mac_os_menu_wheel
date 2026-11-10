import AppKit
import SwiftUI
import ServiceManagement

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

enum WheelCapacity: Int, CaseIterable {
    case four = 4, eight = 8, twelve = 12
}

@MainActor
final class WheelPreferences: ObservableObject {
    static let defaultDiameter = 380.0
    static let defaultDelay = 0.3
    nonisolated static let defaultActionDelay = 0.65
    static let actionDelayRange = 0.15...1.5
    private let defaults: UserDefaults
    let appActions: AppActionPreferences
    @Published var theme: WheelTheme {
        didSet { defaults.set(theme.rawValue, forKey: "wheelTheme") }
    }

    @Published var wheelCapacity: WheelCapacity {
        didSet { defaults.set(wheelCapacity.rawValue, forKey: "wheelCapacity") }
    }

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
    @Published var actionDelay: Double {
        didSet {
            let value = Self.validActionDelay(actionDelay)
            if actionDelay != value { actionDelay = value }
            defaults.set(value, forKey: "wheelActionDelay")
        }
    }
    @Published var triggerButton: MouseTriggerButton {
        didSet { defaults.set(triggerButton.rawValue, forKey: "wheelTriggerButton") }
    }
    @Published var showsMemoryUsage: Bool {
        didSet { defaults.set(showsMemoryUsage, forKey: "wheelShowsMemoryUsage") }
    }

    @Published var showsHoldPreview: Bool {
        didSet { defaults.set(showsHoldPreview, forKey: "wheelShowsHoldPreview") }
    }
    @Published var keyboardShortcut: WheelKeyboardShortcut? {
        didSet {
            if let keyboardShortcut, let data = try? JSONEncoder().encode(keyboardShortcut) {
                defaults.set(data, forKey: "wheelKeyboardShortcut")
            } else {
                defaults.removeObject(forKey: "wheelKeyboardShortcut")
            }
        }
    }
    @Published var isRecordingKeyboardShortcut = false
    @Published var keyboardShortcutError: String?

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
        appActions = AppActionPreferences(defaults: defaults)
        wheelCapacity = WheelCapacity(rawValue: defaults.integer(forKey: "wheelCapacity")) ?? .eight
        theme = defaults.string(forKey: "wheelTheme").flatMap(WheelTheme.init(rawValue:)) ?? .glass
        keyboardShortcut = defaults.data(forKey: "wheelKeyboardShortcut")
            .flatMap { try? JSONDecoder().decode(WheelKeyboardShortcut.self, from: $0) }
            .flatMap { $0.isValid ? $0 : nil }
        showsMemoryUsage = defaults.bool(forKey: "wheelShowsMemoryUsage")
        showsHoldPreview = defaults.bool(forKey: "wheelShowsHoldPreview")
        language = defaults.string(forKey: "appLanguage").flatMap(AppLanguage.init(rawValue:)) ?? .system
        wheelDiameter = Self.validDiameter((defaults.object(forKey: "wheelDiameter") as? Double) ?? Self.defaultDiameter)
        holdDelay = Self.validDelay((defaults.object(forKey: "wheelHoldDelay") as? Double) ?? Self.defaultDelay)
        actionDelay = Self.validActionDelay((defaults.object(forKey: "wheelActionDelay") as? Double) ?? Self.defaultActionDelay)
        triggerButton = (defaults.object(forKey: "wheelTriggerButton") as? Int)
            .flatMap(MouseTriggerButton.init(rawValue:)) ?? .right
    }
    var gestureHint: String {
        L10n.text("Segure o %@ por %@ ms, aponte e solte.", triggerButton.title.lowercased(), String(Int((holdDelay * 1000).rounded())))
    }
    func reset() {
        wheelCapacity = .eight
        theme = .glass
        wheelDiameter = Self.defaultDiameter
        holdDelay = Self.defaultDelay
        actionDelay = Self.defaultActionDelay
        triggerButton = .right
        showsMemoryUsage = false
        showsHoldPreview = false
        keyboardShortcut = nil
        language = .system
    }
    private static func validDiameter(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 260), 520) : defaultDiameter
    }
    private static func validDelay(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0.15), 1.0) : defaultDelay
    }
    private static func validActionDelay(_ value: Double) -> Double {
        guard value.isFinite else { return defaultActionDelay }
        return min(max(value, actionDelayRange.lowerBound), actionDelayRange.upperBound)
    }
}

/// The system registration is the source of truth; never register on app launch
/// or overwrite changes the user makes in System Settings.
@MainActor
final class LaunchAtLogin: ObservableObject {
    @Published private(set) var status: SMAppService.Status
    @Published private(set) var error: String?
    private let readStatus: () -> SMAppService.Status
    private let register: () throws -> Void
    private let unregister: () throws -> Void

    init(readStatus: @escaping () -> SMAppService.Status = { SMAppService.mainApp.status },
         register: @escaping () throws -> Void = { try SMAppService.mainApp.register() },
         unregister: @escaping () throws -> Void = { try SMAppService.mainApp.unregister() }) {
        self.readStatus = readStatus
        self.register = register
        self.unregister = unregister
        status = readStatus()
    }

    var isRequested: Bool { status == .enabled || status == .requiresApproval }

    func refresh() { status = readStatus() }

    func setEnabled(_ enabled: Bool) {
        refresh()
        error = nil
        guard enabled != isRequested else { return }
        do {
            if enabled { try register() } else { try unregister() }
        } catch {
            self.error = L10n.text("Não foi possível alterar a inicialização automática: %@", error.localizedDescription)
        }
        refresh()
    }
}

struct WheelPreferencesView: View {
    @ObservedObject var preferences: WheelPreferences
    @StateObject private var launchAtLogin = LaunchAtLogin()
    @State private var showsRestartDialog = false
    @State private var isRestarting = false
    @State private var restartError: String?
    var body: some View {
        Form {
            Section(L10n.text("Inicialização")) {
                Toggle(L10n.text("Iniciar com o macOS"), isOn: Binding(
                    get: { launchAtLogin.isRequested },
                    set: { launchAtLogin.setEnabled($0) }
                ))
                Text(L10n.text("Abrir o Radial em segundo plano ao iniciar sessão no macOS."))
                    .font(.caption).foregroundStyle(.secondary)
                if launchAtLogin.status == .requiresApproval {
                    Text(L10n.text("Aguardando sua autorização nos Itens de Início do macOS."))
                        .font(.caption).foregroundStyle(.secondary)
                    Button(L10n.text("Abrir Itens de Início")) {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                }
                if launchAtLogin.status == .notFound {
                    Text(L10n.text("O macOS não encontrou o app para configurar a inicialização automática."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = launchAtLogin.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            Section(L10n.text("Idioma")) {
                Picker(L10n.text("Idioma"), selection: $preferences.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title).tag(language)
                    }
                }
                Text(L10n.text("Encerre e abra o Radial para aplicar a mudança de idioma."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L10n.text("Aparência")) {
                Picker(L10n.text("Tema da roda"), selection: $preferences.theme) {
                    ForEach(WheelTheme.allCases) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
                Picker(L10n.text("Posições por página"), selection: $preferences.wheelCapacity) {
                    ForEach(WheelCapacity.allCases, id: \.self) { capacity in
                        Text(String(capacity.rawValue)).tag(capacity)
                    }
                }
                Toggle(L10n.text("Mostrar consumo de RAM"), isOn: $preferences.showsMemoryUsage)
                WheelThemePreview(theme: preferences.theme, capacity: preferences.wheelCapacity)

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
                VStack(spacing: 10) {
                    LabeledContent(L10n.text("Tempo para revelar ações"), value: "\(Int((preferences.actionDelay * 1000).rounded())) ms")
                    Slider(value: $preferences.actionDelay, in: WheelPreferences.actionDelayRange, step: 0.05) {
                        Text(L10n.text("Tempo para revelar ações"))
                    }
                    .labelsHidden()
                }
                Picker(L10n.text("Botão do mouse"), selection: $preferences.triggerButton) {
                    ForEach(MouseTriggerButton.allCases) { button in
                        Text(button.title).tag(button)
                    }
                }
                Toggle(L10n.text("Mostrar contagem ao segurar"), isOn: $preferences.showsHoldPreview)
                Text(L10n.text("Exibe um arco ao redor do ponteiro enquanto aguarda a abertura da roda."))
                    .font(.caption).foregroundStyle(.secondary)
                Text(L10n.text("Cliques rápidos e arrastos continuam sendo encaminhados ao aplicativo. As alterações valem para o próximo gesto."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L10n.text("Teclado")) {
                KeyboardShortcutSettings(preferences: preferences)
            }
            HStack {
                Text(L10n.text("As preferências são salvas automaticamente."))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.text("Restaurar padrão")) { preferences.reset() }
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLogin.refresh()
        }
        .disabled(isRestarting)
        .onChange(of: preferences.language) { _, _ in
            restartError = nil
            showsRestartDialog = true
        }
        .alert(L10n.text(restartError == nil ? "Reiniciar Radial?" : "Não foi possível reiniciar"),
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
            Text(restartError ?? L10n.text("O Radial precisa reiniciar para aplicar o novo idioma. Suas preferências serão mantidas."))
        }
    }
}

private struct WheelThemePreview: View {
    let theme: WheelTheme
    let capacity: WheelCapacity
    @StateObject private var model = RunningApps()

    var body: some View {
        WheelView(model: model, selectedID: model.apps.first?.id, isActive: false, theme: theme)
            .scaleEffect(0.46)
            .frame(width: 180, height: 180)
            .frame(maxWidth: .infinity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: capacity, initial: true) { _, capacity in model.refresh(capacity: capacity) }
    }
}
