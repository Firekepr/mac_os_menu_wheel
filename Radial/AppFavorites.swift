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

enum FavoriteLayout {
    static func pages(runningIDs: [String], favorites: [Int: String], onlyWhenRunning: Set<String> = [],
                      capacity: WheelCapacity = .eight) -> [[String?]] {
        let count = capacity.rawValue
        let blank = Array<String?>(repeating: nil, count: count)
        var pages = [blank]
        let running = Set(runningIDs)
        var placed = Set<String>()
        let directions = favorites.keys.filter { (0..<8).contains($0) }.sorted {
            // Exact directions take priority when four sectors collapse eight directions.
            let first = ($0 * count).isMultiple(of: 8)
            let second = ($1 * count).isMultiple(of: 8)
            return first == second ? $0 < $1 : first
        }

        for direction in directions {
            guard let id = favorites[direction],
                  !onlyWhenRunning.contains(id) || running.contains(id),
                  placed.insert(id).inserted else { continue }
            if !pages[pages.count - 1].contains(nil) { pages.append(blank) }
            let page = pages.count - 1
            let slot = pages[page].indices.filter { pages[page][$0] == nil }.min {
                let first = abs($0 * 8 - direction * count)
                let second = abs($1 * 8 - direction * count)
                return min(first, 8 * count - first) < min(second, 8 * count - second)
            }!
            pages[page][slot] = id
        }

        var page = 0
        for id in runningIDs where placed.insert(id).inserted {
            while !pages[page].contains(nil) {
                page += 1
                if page == pages.count { pages.append(blank) }
            }
            let slot = pages[page].firstIndex(of: nil)!
            pages[page][slot] = id
        }
        return pages
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

    /// Commit a move/swap in one publication and one save. Both favorites keep
    /// their own visibility, path and identity; no destination is overwritten.
    @discardableResult
    func move(id: String, to position: Int) -> Bool {
        guard (0..<8).contains(position), let source = apps.first(where: { $0.id == id }),
              source.position != position else { return false }
        let destination = app(at: position)
        var updated = apps.filter { $0.id != source.id && $0.position != position }
        updated.append(FavoriteApp(id: source.id, name: source.name, path: source.path,
                                   position: position, visibility: source.visibility))
        if let destination {
            updated.append(FavoriteApp(id: destination.id, name: destination.name, path: destination.path,
                                       position: source.position, visibility: destination.visibility))
        }
        error = nil
        apps = updated.sorted { $0.position < $1.position }
        save()
        return true
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var runningApps: [NSRunningApplication] = []
    @State private var selectedPosition = 0
    @State private var hoveredPosition: Int?
    @GestureState private var dragState: FavoriteDragState?
    @State private var dragCancelled = false
    @State private var escapeMonitor: Any?

    private var dropTargetPosition: Int? {
        guard !dragCancelled, let dragState else { return nil }
        return FavoriteEditorGeometry.position(at: dragState.location)
    }

    private var selectedApp: FavoriteApp? { favorites.app(at: selectedPosition) }

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 5) {
                Text(L10n.text("Apps favoritos em posições fixas")).font(.title2.bold())
                Text(L10n.text("Clique para configurar ou arraste um favorito para reorganizar."))
                    .font(.callout).foregroundStyle(.secondary)
            }

            ZStack {
                Circle()
                    .fill(.clear)
                    .glassEffect(.regular, in: Circle())
                ForEach(0..<8, id: \.self) { position in
                    positionButton(position)
                }
                VStack(spacing: 5) {
                    Image(systemName: "pencil.tip.crop.circle")
                        .font(.title2).foregroundStyle(Color.accentColor)
                    Text(AppFavorites.directions[selectedPosition])
                        .font(.system(size: 12, weight: .semibold))
                        .multilineTextAlignment(.center)
                    Text(L10n.text("Editar posição"))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .padding(10)
                .frame(width: 106, height: 106)
                .background(.quaternary.opacity(0.4), in: Circle())
                .allowsHitTesting(false)
            }
            .frame(width: 320, height: 320)
            .coordinateSpace(name: "favoriteEditorWheel")
            .overlay(alignment: .topLeading) {
                if !dragCancelled, let dragState,
                   let app = favorites.apps.first(where: { $0.id == dragState.id }) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                        .resizable().frame(width: 44, height: 44)
                        .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                        .position(dragState.location)
                        .allowsHitTesting(false)
                }
            }
            .onChange(of: dragState?.id) { _, id in
                if id == nil { finishDrag() }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: selectedPosition)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hoveredPosition)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: dropTargetPosition)

            positionEditor

            Text(L10n.text("Posições salvas automaticamente. Escolher um app já fixado move-o para a nova posição. As alterações valem na próxima abertura da roda."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = favorites.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(20)
        .onAppear { refreshRunningApps() }
        .onDisappear { finishDrag() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            if dragState != nil { dragCancelled = true }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in
            refreshRunningApps()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
            refreshRunningApps()
        }
    }

    @ViewBuilder
    private func positionButton(_ position: Int) -> some View {
        let button = basePositionButton(position)
        if let app = favorites.app(at: position) {
            button
            .highPriorityGesture(dragGesture(for: app))
            .accessibilityHint(L10n.text("Arraste para mover. Sobre outro favorito, as posições são trocadas."))
            .accessibilityActions {
                ForEach((0..<8).filter { $0 != position }, id: \.self) { destination in
                    Button(L10n.text("Mover para %@", AppFavorites.directions[destination])) {
                        if favorites.move(id: app.id, to: destination) { selectedPosition = destination }
                    }
                }
            }
        } else {
            button
        }
    }

    private func basePositionButton(_ position: Int) -> some View {
        let app = favorites.app(at: position)
        let isRunning = app.map { favorite in
            runningApps.contains { !$0.isTerminated && $0.bundleIdentifier == favorite.id }
        } ?? false
        let selected = selectedPosition == position
        let hovered = hoveredPosition == position
        let dropTarget = dropTargetPosition == position
        return Button {
            selectedPosition = position
        } label: {
            FavoritePositionLabel(position: position, app: app, isRunning: isRunning,
                                  selected: selected, hovered: hovered, dropTarget: dropTarget,
                                  isDragging: !dragCancelled && app != nil && dragState?.id == app?.id)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hoveredPosition = position }
            else if hoveredPosition == position { hoveredPosition = nil }
        }
        .help(L10n.text("Favorito — %@", AppFavorites.directions[position]) + ": " + (app?.name ?? L10n.text("Automático")))
        .accessibilityLabel(L10n.text("Escolher favorito: %@", AppFavorites.directions[position]))
        .accessibilityValue((app?.name ?? L10n.text("Automático"))
                            + (app == nil ? "" : ", " + L10n.text(isRunning ? "Em execução" : "Fechado")))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func dragGesture(for app: FavoriteApp) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named("favoriteEditorWheel"))
            .updating($dragState) { value, state, _ in
                state = FavoriteDragState(id: app.id, location: value.location)
            }
            .onChanged { _ in
                monitorEscapeDuringDrag()
            }
            .onEnded { value in
                guard !dragCancelled,
                      let destination = FavoriteEditorGeometry.position(at: value.location) else { return }
                if favorites.move(id: app.id, to: destination) { selectedPosition = destination }
            }
    }

    private func monitorEscapeDuringDrag() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { dragCancelled = true }
            return nil
        }
    }

    private func finishDrag() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        dragCancelled = false
    }

    private var positionEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(AppFavorites.directions[selectedPosition])
                        .font(.caption).foregroundStyle(.secondary)
                    Text(selectedApp?.name ?? L10n.text("Automático"))
                        .font(.headline).lineLimit(1).help(selectedApp?.name ?? L10n.text("Automático"))
                }
                Spacer(minLength: 8)
                Menu {
                    ForEach(runningApps, id: \.processIdentifier) { app in
                        if let id = app.bundleIdentifier, let url = app.bundleURL {
                            Button(app.localizedName ?? L10n.text("Aplicativo")) {
                                favorites.set(position: selectedPosition, bundleIdentifier: id,
                                              name: app.localizedName ?? L10n.text("Aplicativo"), path: url.path)
                            }
                        }
                    }
                    Divider()
                    Button(L10n.text("Escolher aplicativo…")) {
                        favorites.chooseApplication(at: selectedPosition)
                    }
                } label: {
                    Text(L10n.text(selectedApp == nil ? "Escolher aplicativo…" : "Trocar aplicativo…"))
                }
                .fixedSize()
                .accessibilityLabel(L10n.text("Escolher favorito: %@", AppFavorites.directions[selectedPosition]))
            }
            if let app = selectedApp {
                HStack {
                    Picker(L10n.text("Disponibilidade"), selection: Binding(
                        get: { favorites.app(at: selectedPosition)?.visibility ?? app.visibility },
                        set: { favorites.setVisibility($0, at: selectedPosition) }
                    )) {
                        ForEach(FavoriteVisibility.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityLabel(L10n.text("Quando mostrar %@: %@", app.name, AppFavorites.directions[selectedPosition]))
                    Spacer(minLength: 12)
                    Button(L10n.text("Remover favorito"), systemImage: "minus.circle") {
                        favorites.remove(at: selectedPosition)
                    }
                    .accessibilityLabel(L10n.text("Remover favorito: %@", AppFavorites.directions[selectedPosition]))
                }
                Text(app.visibility == .always
                     ? L10n.text("Este favorito aparece mesmo quando o aplicativo está fechado.")
                     : L10n.text("Quando este favorito estiver fechado, outros apps poderão usar a posição."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(L10n.text("Esta posição será preenchida por um app aberto."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 126, alignment: .topLeading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
    }

    private func refreshRunningApps() {
        runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            .sorted { ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending }
    }
}

private struct FavoritePositionLabel: View {
    let position: Int
    let app: FavoriteApp?
    let isRunning: Bool
    let selected: Bool
    let hovered: Bool
    let dropTarget: Bool
    let isDragging: Bool

    var body: some View {
        let sector = FavoriteEditorSector(position: position)
        let angle = Double(position) * .pi / 4 - .pi / 2
            ZStack {
                sector.fill(Color.accentColor.opacity(dropTarget ? 0.35 : selected ? 0.23 : hovered ? 0.10 : 0.015))
                sector.stroke(dropTarget || selected ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.08),
                              lineWidth: dropTarget ? 2.5 : selected ? 1.5 : 1)
                VStack(spacing: 3) {
                    if let app {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                            .resizable().interpolation(.high)
                            .frame(width: 36, height: 36)
                            .shadow(color: .black.opacity(0.14), radius: 3, y: 2)
                            .opacity(isDragging ? 0.25 : 1)
                    } else {
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(selected ? Color.accentColor : .secondary)
                            .frame(width: 36, height: 36)
                            .background(.primary.opacity(0.045), in: Circle())
                    }
                    Text(app?.name ?? L10n.text("Automático"))
                        .font(.system(size: 10, weight: selected ? .semibold : .regular))
                        .lineLimit(1).truncationMode(.tail)
                        .frame(width: 80)
                    RunningAppIndicator()
                        .opacity(isRunning ? 1 : 0)
                }
                .offset(x: cos(angle) * 115, y: sin(angle) * 115)
            }
            .contentShape(sector)
    }
}

private struct FavoriteDragState: Equatable {
    let id: String
    let location: CGPoint
}

enum FavoriteEditorGeometry {
    static let diameter: CGFloat = 320
    static let innerRadius: CGFloat = 58

    static func position(at point: CGPoint) -> Int? {
        let dx = point.x - diameter / 2
        let dy = point.y - diameter / 2
        let distance = hypot(dx, dy)
        guard distance > innerRadius, distance <= diameter / 2 - 3 else { return nil }
        let step = Double.pi / 4
        let angle = (atan2(dy, dx) + .pi / 2 + step / 2 + 2 * .pi).truncatingRemainder(dividingBy: 2 * .pi)
        return Int(angle / step) % 8
    }
}

/// Eight fixed directions, matching the wheel's clockwise order from the top.
private struct FavoriteEditorSector: Shape {
    let position: Int
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let start = Angle.degrees(Double(position) * 45 - 90 - 22.5)
        let end = Angle.degrees(Double(position) * 45 - 90 + 22.5)
        var path = Path()
        path.addArc(center: center, radius: rect.width / 2 - 3,
                    startAngle: start, endAngle: end, clockwise: false)
        path.addArc(center: center, radius: FavoriteEditorGeometry.innerRadius,
                    startAngle: end, endAngle: start, clockwise: true)
        path.closeSubpath()
        return path
    }
}
