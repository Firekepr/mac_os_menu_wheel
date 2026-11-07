import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FavoriteApp: Codable, Identifiable {
    let id: String
    let name: String
    let path: String
    let position: Int
}

/// A favorite owns its direction, even when the application is closed.
/// Remaining running apps fill vacant positions without appearing twice.
enum FavoriteLayout {
    static func arrange(runningIDs: [String], favorites: [Int: String]) -> [String?] {
        var seen = Set<String>()
        let running = runningIDs.filter { seen.insert($0).inserted }
        var pinned: [Int: String] = [:]
        var reserved = Set<String>()
        for position in favorites.keys.sorted() where (0..<8).contains(position) {
            if let id = favorites[position], reserved.insert(id).inserted { pinned[position] = id }
        }
        guard !pinned.isEmpty else { return Array(running.prefix(8)).map(Optional.some) }
        var remaining = running.filter { !reserved.contains($0) }.makeIterator()
        return (0..<8).map { pinned[$0] ?? remaining.next() }
    }
}

@MainActor
final class AppFavorites: ObservableObject {
    static let directions = ["Acima", "Acima à direita", "Direita", "Abaixo à direita",
                             "Abaixo", "Abaixo à esquerda", "Esquerda", "Acima à esquerda"]
    @Published private(set) var apps: [FavoriteApp]
    @Published private(set) var error: String?
    private let defaults: UserDefaults
    private let key = "favoriteApplications"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let decoded = defaults.data(forKey: key)
            .flatMap { try? JSONDecoder().decode([FavoriteApp].self, from: $0) } ?? []
        var positions = Set<Int>()
        var identifiers = Set<String>()
        apps = decoded.filter {
            guard (0..<8).contains($0.position), !positions.contains($0.position), !identifiers.contains($0.id) else { return false }
            positions.insert($0.position)
            identifiers.insert($0.id)
            return true
        }
    }

    func app(at position: Int) -> FavoriteApp? { apps.first { $0.position == position } }

    func set(position: Int, bundleIdentifier: String, name: String, path: String) {
        guard (0..<8).contains(position) else { return }
        error = nil
        apps.removeAll { $0.position == position || $0.id == bundleIdentifier }
        apps.append(FavoriteApp(id: bundleIdentifier, name: name, path: path, position: position))
        apps.sort { $0.position < $1.position }
        save()
    }

    func remove(at position: Int) {
        error = nil
        apps.removeAll { $0.position == position }
        save()
    }

    func chooseApplication(at position: Int) {
        guard (0..<8).contains(position) else { return }
        let picker = NSOpenPanel()
        picker.title = "Favorito — \(Self.directions[position])"
        picker.message = "Escolha o app que ficará fixo nesta direção."
        picker.allowedContentTypes = [.applicationBundle]
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = false
        picker.directoryURL = URL(fileURLWithPath: "/Applications")
        picker.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = picker.url, let self else { return }
                guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else {
                    self.error = "Não foi possível identificar esse aplicativo."
                    return
                }
                let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                self.set(position: position, bundleIdentifier: id, name: name, path: url.path)
            }
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(apps) { defaults.set(data, forKey: key) }
    }
}

struct AppFavoritesView: View {
    @ObservedObject var favorites: AppFavorites
    @State private var runningApps: [NSRunningApplication] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Apps favoritos em posições fixas").font(.title2.bold())
            Text("Escolha o app de cada direção. Favoritos fechados continuam na roda e podem ser abertos por ela. Os outros espaços recebem os apps abertos.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List(0..<8, id: \.self) { position in
                HStack(spacing: 12) {
                    Image(systemName: ["arrow.up", "arrow.up.right", "arrow.right", "arrow.down.right",
                                       "arrow.down", "arrow.down.left", "arrow.left", "arrow.up.left"][position])
                        .frame(width: 22).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(AppFavorites.directions[position]).font(.caption).foregroundStyle(.secondary)
                        Text(favorites.app(at: position)?.name ?? "Automático")
                            .fontWeight(.medium)
                    }
                    Spacer()
                    Menu {
                        ForEach(runningApps, id: \.processIdentifier) { app in
                            if let id = app.bundleIdentifier, let url = app.bundleURL {
                                Button(app.localizedName ?? "Aplicativo") {
                                    favorites.set(position: position, bundleIdentifier: id,
                                                  name: app.localizedName ?? "Aplicativo", path: url.path)
                                }
                            }
                        }
                        Divider()
                        Button("Escolher aplicativo…") { favorites.chooseApplication(at: position) }
                    } label: { Text("Escolher…") }
                    .fixedSize()
                    .accessibilityLabel("Escolher favorito: \(AppFavorites.directions[position])")
                    Button { favorites.remove(at: position) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .disabled(favorites.app(at: position) == nil)
                        .accessibilityLabel("Remover favorito: \(AppFavorites.directions[position])")
                }
                .padding(.vertical, 4)
            }
            .listStyle(.inset)
            Text("Posições salvas automaticamente. Escolher um app já fixado move-o para a nova posição. As alterações valem na próxima abertura da roda.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = favorites.error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .padding(20)
        .onAppear {
            runningApps = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
                .sorted { ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending }
        }
    }
}
