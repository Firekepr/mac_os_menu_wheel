import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum FavoriteVisibility: String, Codable, CaseIterable, Identifiable {
    case always, whenRunning
    var id: String { rawValue }
    var title: String { self == .always ? L10n.text("Sempre na roda") : L10n.text("Só quando aberto") }
}

struct FavoriteApp: Codable, Identifiable {
    let id: String
    let name: String
    let path: String
    let position: Int
    let visibility: FavoriteVisibility

    init(id: String, name: String, path: String, position: Int, visibility: FavoriteVisibility = .always) {
        self.id = id
        self.name = name
        self.path = path
        self.position = position
        self.visibility = visibility
    }

    private enum CodingKeys: String, CodingKey { case id, name, path, position, visibility }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        path = try values.decode(String.self, forKey: .path)
        position = try values.decode(Int.self, forKey: .position)
        // Existing favorites keep their behavior when upgrading.
        visibility = (try? values.decode(FavoriteVisibility.self, forKey: .visibility)) ?? .always
    }
}

/// Conditional favorites reserve their direction only while running.
/// Keep eight sectors whenever favorites are configured so directions stay stable.
enum FavoriteLayout {
    static func arrange(runningIDs: [String], favorites: [Int: String], onlyWhenRunning: Set<String> = []) -> [String?] {
        var seen = Set<String>()
        let running = runningIDs.filter { seen.insert($0).inserted }
        var pinned: [Int: String] = [:]
        var reserved = Set<String>()
        var configured = Set<String>()
        for position in favorites.keys.sorted() where (0..<8).contains(position) {
            guard let id = favorites[position], configured.insert(id).inserted else { continue }
            if !onlyWhenRunning.contains(id) || seen.contains(id) {
                pinned[position] = id
                reserved.insert(id)
            }
        }
        guard !configured.isEmpty else { return Array(running.prefix(8)).map(Optional.some) }
        var remaining = running.filter { !reserved.contains($0) }.makeIterator()
        return (0..<8).map { pinned[$0] ?? remaining.next() }
    }
}

@MainActor
final class AppFavorites: ObservableObject {
    static let directions = [L10n.text("Acima"), L10n.text("Acima à direita"), L10n.text("Direita"), L10n.text("Abaixo à direita"),
                             L10n.text("Abaixo"), L10n.text("Abaixo à esquerda"), L10n.text("Esquerda"), L10n.text("Acima à esquerda")]
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

    func set(position: Int, bundleIdentifier: String, name: String, path: String, visibility: FavoriteVisibility? = nil) {
        guard (0..<8).contains(position) else { return }
        error = nil
        let mode = visibility ?? apps.first { $0.id == bundleIdentifier }?.visibility ?? .always
        apps.removeAll { $0.position == position || $0.id == bundleIdentifier }
        apps.append(FavoriteApp(id: bundleIdentifier, name: name, path: path, position: position, visibility: mode))
        apps.sort { $0.position < $1.position }
        save()
    }

    func setVisibility(_ visibility: FavoriteVisibility, at position: Int) {
        guard let app = app(at: position) else { return }
        set(position: position, bundleIdentifier: app.id, name: app.name, path: app.path, visibility: visibility)
    }

    func remove(at position: Int) {
        error = nil
        apps.removeAll { $0.position == position }
        save()
    }

    func chooseApplication(at position: Int) {
        guard (0..<8).contains(position) else { return }
        let picker = NSOpenPanel()
        picker.title = L10n.text("Favorito — %@", Self.directions[position])
        picker.message = L10n.text("Escolha o app que ficará fixo nesta direção.")
        picker.allowedContentTypes = [.applicationBundle]
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = false
        picker.directoryURL = URL(fileURLWithPath: "/Applications")
        picker.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = picker.url, let self else { return }
                guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else {
                    self.error = L10n.text("Não foi possível identificar esse aplicativo.")
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
            Text(L10n.text("Apps favoritos em posições fixas")).font(.title2.bold())
            Text(L10n.text("Escolha o app de cada direção e quando ele aparece. Em “Só quando aberto”, o espaço fica livre para outros apps enquanto o favorito estiver fechado."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List(0..<8, id: \.self) { position in
                HStack(spacing: 12) {
                    Image(systemName: ["arrow.up", "arrow.up.right", "arrow.right", "arrow.down.right",
                                       "arrow.down", "arrow.down.left", "arrow.left", "arrow.up.left"][position])
                        .frame(width: 22).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(AppFavorites.directions[position]).font(.caption).foregroundStyle(.secondary)
                        Text(favorites.app(at: position)?.name ?? L10n.text("Automático"))
                            .fontWeight(.medium)
                        if let app = favorites.app(at: position) {
                            Picker(L10n.text("Disponibilidade"), selection: Binding(
                                get: { favorites.app(at: position)?.visibility ?? app.visibility },
                                set: { favorites.setVisibility($0, at: position) }
                            )) {
                                ForEach(FavoriteVisibility.allCases) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .fixedSize()
                            .accessibilityLabel(L10n.text("Quando mostrar %@: %@", app.name, AppFavorites.directions[position]))
                        }
                    }
                    Spacer()
                    Menu {
                        ForEach(runningApps, id: \.processIdentifier) { app in
                            if let id = app.bundleIdentifier, let url = app.bundleURL {
                                Button(app.localizedName ?? L10n.text("Aplicativo")) {
                                    favorites.set(position: position, bundleIdentifier: id,
                                                  name: app.localizedName ?? L10n.text("Aplicativo"), path: url.path)
                                }
                            }
                        }
                        Divider()
                        Button(L10n.text("Escolher aplicativo…")) { favorites.chooseApplication(at: position) }
                    } label: { Text(L10n.text("Escolher…")) }
                    .fixedSize()
                    .accessibilityLabel(L10n.text("Escolher favorito: %@", AppFavorites.directions[position]))
                    Button { favorites.remove(at: position) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .disabled(favorites.app(at: position) == nil)
                        .accessibilityLabel(L10n.text("Remover favorito: %@", AppFavorites.directions[position]))
                }
                .padding(.vertical, 4)
            }
            .listStyle(.inset)
            Text(L10n.text("Posições salvas automaticamente. Escolher um app já fixado move-o para a nova posição. As alterações valem na próxima abertura da roda."))
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
