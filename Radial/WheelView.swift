import SwiftUI

enum WheelTheme: String, CaseIterable, Identifiable {
    case glass, minimal, highContrast, frutigerAero, frutigerAeroGlass

    var id: Self { self }

    var title: String {
        switch self {
        case .glass: L10n.text("Glass")
        case .minimal: L10n.text("Minimalista")
        case .highContrast: L10n.text("Alto contraste")
        case .frutigerAero: L10n.text("Frutiger Aero")
        case .frutigerAeroGlass: L10n.text("Frutiger Aero · Liquid Glass")
        }
    }

    var isAero: Bool { self == .frutigerAero || self == .frutigerAeroGlass }
    var usesDarkAppearance: Bool { self == .highContrast || isAero }

    var accent: Color {
        switch self {
        case .highContrast: .yellow
        case .frutigerAero, .frutigerAeroGlass: Color(red: 0.76, green: 1, blue: 0.31)
        default: .accentColor
        }
    }

    var surface: Color {
        switch self {
        case .glass: .clear
        case .minimal: Color(nsColor: .windowBackgroundColor)
        case .highContrast: Color(white: 0.08)
        case .frutigerAero, .frutigerAeroGlass: Color(red: 0.04, green: 0.39, blue: 0.63)
        }
    }

    var sectorColors: [Color] {
        switch self {
        case .glass: [accent.opacity(0.05), accent.opacity(0.30)]
        case .minimal: [accent.opacity(0.13), accent.opacity(0.13)]
        case .highContrast: [accent.opacity(0.26), accent.opacity(0.42)]
        case .frutigerAero, .frutigerAeroGlass: [accent.opacity(0.22), accent.opacity(0.66)]
        }
    }

    var rimColors: [Color] {
        switch self {
        case .glass: [accent.opacity(0.70), .white.opacity(0.95), accent.opacity(0.70)]
        case .frutigerAero, .frutigerAeroGlass: [.white, accent, Color(red: 0.32, green: 0.84, blue: 0.23)]
        default: [accent, accent]
        }
    }
}

struct WheelBackdrop<Outline: Shape>: View {
    let shape: Outline
    let theme: WheelTheme

    var body: some View {
        switch theme {
        case .glass:
            shape.fill(.clear).glassEffect(.regular, in: shape)
        case .frutigerAero, .frutigerAeroGlass:
            ZStack {
                if theme == .frutigerAeroGlass {
                    shape.fill(.clear)
                        .glassEffect(.regular.tint(theme.surface.opacity(0.35)), in: shape)
                }
                shape.fill(
                    LinearGradient(
                        stops: [
                            .init(color: Color(red: 0.48, green: 0.92, blue: 1), location: 0),
                            .init(color: Color(red: 0.13, green: 0.71, blue: 0.94), location: 0.46),
                            .init(color: theme.surface, location: 0.72),
                            .init(color: Color(red: 0.02, green: 0.23, blue: 0.43), location: 1)
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .opacity(theme == .frutigerAeroGlass ? 0.36 : 1)
            }
            .overlay {
                shape.fill(RadialGradient(colors: [.white.opacity(0.65), .clear], center: .topLeading,
                                          startRadius: 4, endRadius: 250))
            }
            .overlay {
                shape.stroke(LinearGradient(colors: [.white.opacity(0.9), .cyan.opacity(0.4)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 2)
            }
        case .minimal, .highContrast:
            shape.fill(theme.surface)
        }
    }
}

struct WheelSurface<Sectors: View, Center: View>: View {
    let theme: WheelTheme
    let diameter: CGFloat
    @ViewBuilder let sectors: () -> Sectors
    @ViewBuilder let center: () -> Center
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            WheelBackdrop(shape: Circle(), theme: theme)
                .frame(width: diameter, height: diameter)
                .allowsHitTesting(false)
            if theme.isAero {
                AeroBubbles()
                    .scaleEffect(diameter / WheelGeometry.size)
                    .frame(width: diameter, height: diameter)
            }
            sectors()
            center()
        }
        .frame(width: diameter, height: diameter)
        .environment(\.colorScheme, theme.usesDarkAppearance ? .dark : colorScheme)
    }
}

struct WheelCenterBackdrop: View {
    let theme: WheelTheme

    var body: some View {
        switch theme {
        case .glass:
            Circle().fill(.background.opacity(0.45))
        case .frutigerAero:
            Circle()
                .fill(LinearGradient(colors: [theme.surface, Color(red: 0.02, green: 0.18, blue: 0.32)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay { Circle().strokeBorder(.white.opacity(0.45), lineWidth: 1) }
        case .frutigerAeroGlass:
            Circle().fill(Color(red: 0.02, green: 0.18, blue: 0.32).opacity(0.75))
                .glassEffect(.regular.tint(theme.surface.opacity(0.45)), in: Circle())
                .overlay { Circle().strokeBorder(.white.opacity(0.45), lineWidth: 1) }
        case .highContrast:
            Circle().fill(.black)
        case .minimal:
            Circle().fill(Color(nsColor: .controlBackgroundColor))
        }
    }
}

private struct AeroBubbles: View {
    private let bubbles: [(x: CGFloat, y: CGFloat, size: CGFloat)] = [
        (65, 94, 28), (84, 68, 10), (307, 96, 22),
        (327, 273, 35), (302, 298, 13), (76, 303, 20)
    ]

    var body: some View {
        ZStack {
            ForEach(bubbles.indices, id: \.self) { index in
                let bubble = bubbles[index]
                Circle()
                    .fill(RadialGradient(colors: [.white.opacity(0.7), .cyan.opacity(0.12), .clear],
                                         center: .topLeading, startRadius: 0, endRadius: bubble.size))
                    .overlay { Circle().strokeBorder(.white.opacity(0.45), lineWidth: 1) }
                    .frame(width: bubble.size, height: bubble.size)
                    .position(x: bubble.x, y: bubble.y)
            }
        }
        .frame(width: WheelGeometry.size, height: WheelGeometry.size)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct WheelView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: RunningApps
    let selectedID: String?
    var selectedActionTitle: String?
    var selectedWindowTitle: String?
    var isOpenMainWindowHovered = false
    var isActive = true
    var showsMemoryUsage = false
    var theme: WheelTheme = .glass
    var isMainWindowOpen = false
    @State private var memory: AppMemoryUsage?
    @State private var memoryPID: pid_t?
    @State private var isLoadingMemory = false
    @State private var playingPIDs: Set<pid_t> = []
    @State private var mailUnread: Int?
    @State private var unreadMailPID: pid_t?

    private var mailPID: pid_t? {
        guard isActive,
              let mail = model.apps.first(where: { $0.id == AppScriptActions.mailID }),
              model.isRunning(mail), let application = mail.application, !application.isTerminated else { return nil }
        return application.processIdentifier
    }

    private func unreadCount(for app: WheelApp) -> Int? {
        guard app.id == AppScriptActions.mailID, let pid = mailPID, pid == unreadMailPID,
              let mailUnread, mailUnread > 0 else { return nil }
        return mailUnread
    }

    private struct PlaybackTarget: Equatable {
        let pid: pid_t
        let isBrave: Bool
    }

    private var playbackTargets: [PlaybackTarget] {
        guard isActive else { return [] }
        return model.apps.compactMap { app in
            guard model.isRunning(app), let application = app.application, !application.isTerminated else { return nil }
            let isBrave = application.bundleIdentifier == AppWindows.braveBundleIdentifier
            guard isBrave || app.hasPlaybackControls
            else { return nil }
            return PlaybackTarget(pid: application.processIdentifier, isBrave: isBrave)
        }
    }

    private func isPlaying(_ app: WheelApp) -> Bool {
        guard isActive, model.isRunning(app), let pid = app.application?.processIdentifier else { return false }
        return playingPIDs.contains(pid)
    }

    private var pageLabel: String? {
        guard model.pageCount > 1 else { return nil }
        return L10n.text("Página %@ de %@", String(model.pageIndex + 1), String(model.pageCount))
    }

    private var mainWindowActionTitle: String {
        L10n.text(isMainWindowOpen ? "Fechar janela do Radial" : "Abrir Radial")
    }

    private var selected: WheelApp? {
        model.apps.first { $0.id == selectedID }
    }

    private var memoryTargetPID: pid_t? {
        guard isActive, showsMemoryUsage else { return nil }
        guard let application = selected?.application, !application.isTerminated else { return nil }
        return application.processIdentifier
    }

    private var memoryLabel: String? {
        guard memoryTargetPID != nil else { return nil }
        guard memoryPID == memoryTargetPID else { return L10n.text("RAM: consultando…") }
        if let memory { return "RAM ≈ \(memory.formatted)" }
        return isLoadingMemory ? L10n.text("RAM: consultando…") : L10n.text("RAM indisponível")
    }

    private var pageTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .modifier(
                active: WheelPageEntrance(angle: .degrees(Double(model.pageTurnDirection) * 12), opacity: 0),
                identity: WheelPageEntrance(angle: .zero, opacity: 1)
            ),
            removal: .opacity
        )
    }

    private var pageSectors: some View {
        ZStack {
            ForEach(model.slots) { slot in
                let index = slot.id
                let app = slot.app
                let angle = WheelGeometry.angle(for: index, count: model.slots.count)
                let active = app != nil && selectedID == app?.id
                let iconRadius: CGFloat = active && !reduceMotion ? 140 : 135

                WheelSectorDecoration(sector: WheelSector(index: index, count: model.slots.count),
                                      diameter: WheelGeometry.size, theme: theme, selected: active)

                if active && (theme == .glass || theme.isAero) {
                    Circle()
                        .fill(theme.accent.opacity(0.22))
                        .frame(width: 64, height: 64)
                        .blur(radius: 12)
                        .offset(x: cos(angle) * iconRadius, y: sin(angle) * iconRadius)
                }

                if let app {
                    Image(nsImage: model.icon(for: app))
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 52, height: 52)
                        .scaleEffect(active && !reduceMotion ? 1.16 : 1)
                        .shadow(color: theme == .minimal ? .clear : .black.opacity(active ? 0.24 : 0.15), radius: active ? 10 : 6, y: active ? 6 : 4)
                        .overlay(alignment: .bottomTrailing) {
                            if app.favorite != nil {
                                FavoriteAppBadge()
                            }
                        }
                        .modifier(SelectedIconFloat(isSelected: active && isActive))
                        .overlay(alignment: .bottom) {
                            if app.favorite != nil && model.isRunning(app) {
                                RunningAppIndicator().offset(y: 12)
                            }
                        }
                        .offset(x: cos(angle) * iconRadius, y: sin(angle) * iconRadius)

                    if isPlaying(app) {
                        // Keep the marker next to the icon, outside its floating animation.
                        Image(systemName: app.id == AppWindows.braveBundleIdentifier ? "speaker.wave.2.fill" : "play.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 17, height: 17)
                            .background(Color(red: 0.08, green: 0.43, blue: 0.28), in: Circle())
                            .overlay { Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1) }
                            .offset(x: cos(angle) * iconRadius + 25, y: sin(angle) * iconRadius - 25)
                            .allowsHitTesting(false)
                    }
                    if let unread = unreadCount(for: app) {
                        Text(unread > 99 ? "99+" : unread.formatted())
                            .font(.system(size: 9, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 17, minHeight: 17)
                            .background(Color.red, in: Capsule())
                            .overlay { Capsule().strokeBorder(.white.opacity(0.7), lineWidth: 1) }
                            .offset(x: cos(angle) * iconRadius + 25, y: sin(angle) * iconRadius - 25)
                            .allowsHitTesting(false)
                    }
                } else {
                    Circle().fill(.secondary.opacity(0.25)).frame(width: 5, height: 5)
                        .offset(x: cos(angle) * 135, y: sin(angle) * 135)
                }
            }
        }
        .frame(width: WheelGeometry.size, height: WheelGeometry.size)
    }

    var body: some View {
        WheelSurface(theme: theme, diameter: WheelGeometry.size) {
            ZStack {
                pageSectors
                    .id(model.pageIndex)
                    .transition(pageTransition)
            }
            .animation(.easeInOut(duration: reduceMotion ? 0.12 : 0.20), value: model.pageTurnRevision)
        } center: {
            VStack(spacing: selectedActionTitle == nil && selectedWindowTitle == nil ? 6 : 3) {
                Image(systemName: selected == nil ? "cursorarrow.rays" : "arrow.up.forward.app")
                    .font(.title2)
                    .foregroundStyle(selected == nil ? Color.secondary : theme.accent)
                    .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                Text(selected?.name ?? L10n.text("Escolha um app"))
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .contentTransition(.opacity)
                if let selectedWindowTitle {
                    Text(selectedWindowTitle)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .multilineTextAlignment(.center)
                }
                if let selectedActionTitle {
                    Text(selectedActionTitle)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme == .highContrast ? Color.primary : theme.accent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                if let memoryLabel {
                    Text(memoryLabel)
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(theme == .highContrast ? .primary : .secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .help(memory?.help ?? L10n.text("Consumo de memória do aplicativo selecionado."))
                }
                if selectedWindowTitle == nil, let pageLabel {
                    Label(pageLabel, systemImage: "arrow.up.arrow.down")
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .help(L10n.text("Role para trocar de página."))
                }
            }
            .offset(y: selected == nil ? -16 : 0)
            .padding(8)
            .frame(width: WheelGeometry.centerDiameter, height: WheelGeometry.centerDiameter)
            .background { WheelCenterBackdrop(theme: theme) }
            .overlay {
                if selected == nil {
                    CenterOpenArea()
                        .fill((isMainWindowOpen ? Color.red : theme.accent).opacity(isOpenMainWindowHovered ? 0.45 : 0.12))
                        .overlay(alignment: .bottom) {
                            Label(L10n.text(isMainWindowOpen ? "Fechar janela" : "Abrir"),
                                  systemImage: isMainWindowOpen ? "xmark" : "macwindow")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(isOpenMainWindowHovered ? Color.white : Color.primary)
                                .padding(.top, 6)
                                .frame(width: WheelGeometry.centerDiameter,
                                       height: WheelGeometry.centerDiameter * WheelGeometry.centerOpenFraction,
                                       alignment: .top)
                        }
                        .clipShape(CenterOpenArea())
                        .overlay { CenterOpenArea().stroke(.primary.opacity(0.12), lineWidth: 1) }
                        .help(mainWindowActionTitle)
                }
            }
            .overlay {
                Circle()
                    .stroke(theme.accent.opacity(selected == nil ? 0 : 0.30), lineWidth: 1)
            }
        }
        .contentShape(Circle())
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .spring(duration: 0.24, bounce: 0.15), value: selectedID)
        .animation(.easeOut(duration: 0.12), value: isOpenMainWindowHovered)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("Roda de aplicativos"))
        .accessibilityValue([selected?.name ?? L10n.text("Nenhum aplicativo selecionado"),
                             selectedWindowTitle, selectedActionTitle,
                             selected.flatMap { unreadCount(for: $0) }.map { L10n.text("Não lidos: %@", $0.formatted()) },
                             selected.map { L10n.text(model.isRunning($0) ? "Em execução" : "Fechado") },
                             selected.flatMap { app in
                                 guard isPlaying(app) else { return nil }
                                 return L10n.text(app.id == AppWindows.braveBundleIdentifier ? "Reproduzindo áudio" : "Reproduzindo mídia")
                             },
                             memoryLabel, pageLabel].compactMap { $0 }.joined(separator: ", "))
        .task(id: playbackTargets) {
            let targets = playbackTargets
            let visiblePlayingPIDs = playingPIDs.intersection(targets.map(\.pid))
            if visiblePlayingPIDs != playingPIDs { playingPIDs = visiblePlayingPIDs }
            guard !targets.isEmpty else { return }
            while !Task.isCancelled {
                for target in targets {
                    let pid = target.pid
                    let playing = target.isBrave
                        ? await AppWindows.braveHasAudibleTab(pid: pid)
                        : await AppScriptActions.isPlaying(pid: pid)
                    guard !Task.isCancelled else { return }
                    guard playing != playingPIDs.contains(pid) else { continue }
                    if playing { playingPIDs.insert(pid) }
                    else { playingPIDs.remove(pid) }
                }
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
            }
        }
        .task(id: mailPID) {
            unreadMailPID = mailPID
            mailUnread = nil
            guard let pid = mailPID else { return }
            while !Task.isCancelled {
                let count = await AppScriptActions.unreadMailCount(pid: pid)
                guard !Task.isCancelled else { return }
                if count != mailUnread { mailUnread = count }
                do { try await Task.sleep(for: .seconds(3)) }
                catch { return }
            }
        }
        .task(id: memoryTargetPID) {
            memory = nil
            memoryPID = memoryTargetPID
            isLoadingMemory = true
            guard let pid = memoryTargetPID else { isLoadingMemory = false; return }
            let bundlePath = selected?.application?.bundleURL?.path
            // Sweeping across icons should not enumerate every process for
            // every transient selection. Cancellation stops this debounce.
            do { try await Task.sleep(for: .milliseconds(150)) }
            catch { return }
            while !Task.isCancelled {
                let worker = Task.detached(priority: .utility) {
                    AppMemory.sample(root: pid, bundlePath: bundlePath)
                }
                let sample = await withTaskCancellationHandler {
                    await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled else { return }
                memory = sample
                isLoadingMemory = false
                do { try await Task.sleep(for: .seconds(3)) }
                catch { return }
            }
        }
        .accessibilityActions {
            ForEach(model.apps) { app in
                Button(L10n.text("Abrir %@", app.name)) { model.activate(app) }
                if app.canRequestQuit {
                    Button(L10n.text("Fechar %@", app.name)) { model.requestQuit(app) }
                }
            }
            Button(mainWindowActionTitle) {
                NotificationCenter.default.post(name: .radialToggleMainWindow, object: nil)
            }
        }
    }

}

struct FavoriteAppBadge: View {
    var body: some View {
        Image(systemName: "star.fill")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .padding(4)
            .background(Color.accentColor, in: Circle())
    }
}

/// A static Dock-style marker; no timers or continuous animations.
struct RunningAppIndicator: View {
    var body: some View {
        Circle()
            .fill(.primary.opacity(0.8))
            .frame(width: 4, height: 4)
            .accessibilityHidden(true)
    }
}

private struct WheelPageEntrance: ViewModifier {
    var angle: Angle
    var opacity: Double

    func body(content: Content) -> some View {
        content.rotationEffect(angle).opacity(opacity)
    }
}

private struct CenterOpenArea: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = rect.width / 2
        let angle = asin(1 - 2 * WheelGeometry.centerOpenFraction)
        var path = Path()
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: radius,
                    startAngle: .radians(angle), endAngle: .radians(.pi - angle), clockwise: false)
        path.closeSubpath()
        return path
    }
}

struct SelectedIconFloat: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isSelected: Bool
    @State private var startedAt: Date?

    private var isFloating: Bool { isSelected && !reduceMotion }

    func body(content: Content) -> some View {
        // Keep the exact same image subtree when selection changes. Conditionally
        // wrapping it in a phase animator replaces its identity and can flicker.
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isFloating)) { context in
            let elapsed = startedAt.map { max(0, context.date.timeIntervalSince($0)) } ?? 0
            let lift = isFloating ? -2 * (1 - cos(elapsed * 2 * .pi / 2.3)) : 0
            content.offset(y: lift)
        }
        .onChange(of: isFloating, initial: true) { _, floating in
            // Start at zero displacement and velocity on every selection.
            startedAt = floating ? .now : nil
        }
    }
}

struct WheelSectorDecoration: View {
    let sector: WheelSector
    let diameter: CGFloat
    let theme: WheelTheme
    let selected: Bool
    var hovered = false
    var dropTarget = false

    var body: some View {
        let highlighted = selected || dropTarget
        let borderOpacity = theme == .highContrast ? 0.40 : theme.isAero ? 0.24 : 0.08
        let rimWidth: CGFloat = theme == .highContrast ? 4 : theme == .minimal ? 1.5 : 2.5
        ZStack {
            sector.fill(RadialGradient(colors: theme.sectorColors, center: .center,
                                       startRadius: sector.innerRadius - 2, endRadius: diameter / 2))
                .opacity(highlighted ? 1 : hovered ? 0.4 : 0)
            sector.stroke(.primary.opacity(borderOpacity), lineWidth: 1)
            sector.stroke(.white.opacity(theme == .minimal ? 0 : 0.22), lineWidth: 1)
                .opacity(highlighted ? 1 : 0)
            sector.rim
                .stroke(LinearGradient(colors: theme.rimColors, startPoint: .topLeading, endPoint: .bottomTrailing),
                        style: StrokeStyle(lineWidth: rimWidth, lineCap: .round))
                .shadow(color: theme == .glass ? .accentColor.opacity(0.65) : .clear, radius: 7)
                .opacity(highlighted ? 1 : 0)
            if dropTarget {
                sector.stroke(theme.accent, lineWidth: 2.5)
            }
        }
    }
}

struct WheelSector: Shape {
    let index: Int
    let count: Int
    var innerRadius: CGFloat = 77
    var outerInset: CGFloat = 5

    private var angle: Double { WheelGeometry.angle(for: index, count: count) }
    private var halfStep: Double { .pi / Double(max(count, 1)) }

    var rim: some Shape {
        Rim(sector: self)
    }

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let start = Angle.radians(angle - halfStep)
        let end = Angle.radians(angle + halfStep)
        var path = Path()
        path.addArc(center: center, radius: rect.width / 2 - outerInset,
                    startAngle: start, endAngle: end, clockwise: false)
        path.addArc(center: center, radius: innerRadius,
                    startAngle: end, endAngle: start, clockwise: true)
        path.closeSubpath()
        return path
    }

    private struct Rim: Shape {
        let sector: WheelSector

        func path(in rect: CGRect) -> Path {
            let inset = Angle.degrees(2).radians
            var path = Path()
            path.addArc(center: CGPoint(x: rect.midX, y: rect.midY),
                        radius: rect.width / 2 - sector.outerInset,
                        startAngle: .radians(sector.angle - sector.halfStep + inset),
                        endAngle: .radians(sector.angle + sector.halfStep - inset), clockwise: false)
            return path
        }
    }
}
