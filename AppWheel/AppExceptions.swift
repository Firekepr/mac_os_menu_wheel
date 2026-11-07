import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ExcludedApp: Codable, Identifiable {
    let id: String
    let name: String
    let path: String

    var icon: NSImage { NSWorkspace.shared.icon(forFile: path) }
}

@MainActor
final class AppExceptions: ObservableObject {
    @Published private(set) var apps: [ExcludedApp]
    @Published private(set) var error: String?
    private let defaults: UserDefaults
    private let key = "excludedApplications"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        apps = defaults.data(forKey: key)
            .flatMap { try? JSONDecoder().decode([ExcludedApp].self, from: $0) } ?? []
    }

    func contains(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return apps.contains { $0.id == bundleIdentifier }
    }

    func add(bundleIdentifier: String, name: String, path: String) {
        error = nil
        guard !contains(bundleIdentifier: bundleIdentifier) else { return }
        apps.append(ExcludedApp(id: bundleIdentifier, name: name, path: path))
        apps.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        save()
    }

    func remove(_ app: ExcludedApp) {
        apps.removeAll { $0.id == app.id }
        save()
    }

    func chooseApplication() {
        let picker = NSOpenPanel()
        picker.title = "Adicionar exceção"
        picker.message = "Escolha um aplicativo em que a roda não deve abrir."
        picker.allowedContentTypes = [.applicationBundle]
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = false
        picker.directoryURL = URL(fileURLWithPath: "/Applications")
        picker.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = picker.url, let self else { return }
                guard let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier else {
                    self.error = "Não foi possível identificar esse aplicativo."
                    return
                }
                let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                self.add(bundleIdentifier: identifier, name: name, path: url.path)
            }
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(apps) { defaults.set(data, forKey: key) }
    }
}

struct AppExceptionsView: View {
    @ObservedObject var exceptions: AppExceptions
    @Environment(\.dismiss) private var dismiss
    @State private var runningApps: [NSRunningApplication] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Exceções por aplicativo")
                    .font(.title2.bold())
                Spacer()
                Button("Concluído") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            Text("Nestes apps, o botão direito funciona normalmente, sem abrir a roda. Você ainda pode escolhê-los na roda a partir de outros apps.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List {
                if exceptions.apps.isEmpty {
                    Text("Nenhuma exceção adicionada.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 12)
                }
                ForEach(exceptions.apps) { app in
                    HStack(spacing: 12) {
                        Image(nsImage: app.icon).resizable().frame(width: 32, height: 32)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(app.name).fontWeight(.medium)
                            Text(app.id).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { exceptions.remove(app) } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remover \(app.name) das exceções")
                        .accessibilityLabel("Remover \(app.name) das exceções")
                    }
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 200)

            HStack {
                Menu("Adicionar app aberto", systemImage: "plus") {
                    ForEach(runningApps, id: \.processIdentifier) { app in
                        if let identifier = app.bundleIdentifier, let url = app.bundleURL {
                            Button(app.localizedName ?? url.deletingPathExtension().lastPathComponent) {
                                exceptions.add(bundleIdentifier: identifier,
                                               name: app.localizedName ?? "Aplicativo", path: url.path)
                            }
                            .disabled(exceptions.contains(bundleIdentifier: identifier))
                        }
                    }
                    if runningApps.isEmpty { Text("Nenhum aplicativo disponível") }
                }
                Button("Escolher aplicativo…") { exceptions.chooseApplication() }
            }
            if let error = exceptions.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(24)
        .frame(width: 560, height: 450)
        .onAppear {
            runningApps = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
                .sorted { ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending }
        }
    }
}
