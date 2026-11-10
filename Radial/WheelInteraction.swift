import AppKit
import SwiftUI

/// The close target survives the gap to its outer sector, but a different
/// application selection clears it immediately and begins a fresh dwell.
/// Revealing the action never performs it. Releasing/clicking its explicit hit
/// area is the only way to request a quit.
@MainActor
final class WheelInteraction: ObservableObject {
    @Published var id: String?
    @Published private(set) var closeTargetID: String?
    @Published private(set) var isCloseHovered = false
    @Published private(set) var hoveredScriptAction: AppScriptAction?
    @Published private(set) var mailBadgeNeedsAuthorization = false
    @Published private(set) var isOpenMainWindowHovered = false
    @Published var isMainWindowOpen = false
    @Published var isPresented = false
    @Published private var storedDiameter: CGFloat = WheelGeometry.size
    var diameter: CGFloat {
        get { storedDiameter }
        set { if storedDiameter != newValue { storedDiameter = newValue } }
    }
    @Published private(set) var windows: [WheelWindow] = []
    @Published private(set) var windowPage = 0
    @Published private(set) var hoveredWindow: Int?
    @Published private(set) var hoveredWindowAction: WindowAction?
    private var windowLookup: Task<Void, Never>?
    private var dwellTimer: Timer?

    static let windowsPerPage = 3
    var isChoosingWindow: Bool { !windows.isEmpty }
    var windowTabCount: Int { visibleWindows.count + (windowPageCount > 1 ? 2 : 0) }
    var firstWindowTab: Int { windowPageCount > 1 ? 1 : 0 }
    var windowPageCount: Int { (windows.count + Self.windowsPerPage - 1) / Self.windowsPerPage }
    var visibleWindows: ArraySlice<WheelWindow> {
        windows.dropFirst(windowPage * Self.windowsPerPage).prefix(Self.windowsPerPage)
    }
    var windowChoice: (WheelWindow, WindowAction)? {
        guard let hoveredWindow, let hoveredWindowAction, visibleWindows.indices.contains(hoveredWindow) else { return nil }
        return (windows[hoveredWindow], hoveredWindowAction)
    }

    func moveWindowPage(by step: Int) {
        let next = windowPage + step
        guard (0..<windowPageCount).contains(next) else { return }
        windowPage = next
        setWindowHover(nil, action: nil)
    }

    func windowTitle(at index: Int) -> String {
        let title = windows[index].title
        return title.isEmpty ? L10n.text("Janela %@", String(index + 1)) : title
    }

    private func setWindowHover(_ index: Int?, action: WindowAction?) {
        if hoveredWindow != index { hoveredWindow = index }
        if hoveredWindowAction != action { hoveredWindowAction = action }
    }
    private let dwellDelay: TimeInterval
    private let loadWindows: @MainActor (WheelApp) async -> [WheelWindow]

    init(dwellDelay: TimeInterval = WheelPreferences.defaultActionDelay,
         loadWindows: @escaping @MainActor (WheelApp) async -> [WheelWindow] = AppWindows.list) {
        self.dwellDelay = dwellDelay
        self.loadWindows = loadWindows
    }

    func select(_ id: String?, canRevealClose: Bool, actionDelay: TimeInterval? = nil, app: WheelApp? = nil) {
        if hoveredScriptAction != nil { hoveredScriptAction = nil }
        if isOpenMainWindowHovered { isOpenMainWindowHovered = false }
        if isCloseHovered { isCloseHovered = false }
        if self.id != id {
            cancelDwell()
            self.id = id
        }
        if let id, let closeTargetID, id != closeTargetID {
            self.closeTargetID = nil
            mailBadgeNeedsAuthorization = false
        }
        guard canRevealClose, let id else { cancelDwell(); return }
        guard closeTargetID != id, dwellTimer == nil, windowLookup == nil else { return }
        dwellTimer = Timer.scheduledTimer(withTimeInterval: actionDelay ?? dwellDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.id == id else { return }
                self.dwellTimer = nil
                guard let app else { self.closeTargetID = id; return }
                let loadWindows = self.loadWindows
                self.windowLookup = Task { [weak self] in
                    let windows = await loadWindows(app)
                    let needsAuthorization: Bool
                    if !Task.isCancelled, app.id == AppScriptActions.mailID,
                       let pid = app.application?.processIdentifier {
                        needsAuthorization = await AppScriptActions.mailBadgeNeedsAuthorization(pid: pid)
                    } else {
                        needsAuthorization = false
                    }
                    guard !Task.isCancelled, let self, self.id == id else { return }
                    self.windowLookup = nil
                    self.mailBadgeNeedsAuthorization = needsAuthorization
                    if windows.count > 1 {
                        self.windowPage = 0
                        self.windows = windows
                    }
                    self.closeTargetID = id
                }
            }
        }
    }

    func hoverClose() { hoverAction(nil) }

    private func hoverAction(_ action: AppScriptAction?) {
        cancelDwell()
        if hoveredScriptAction != action { hoveredScriptAction = action }
        if isOpenMainWindowHovered { isOpenMainWindowHovered = false }
        if id != closeTargetID { id = closeTargetID }
        let hovered = closeTargetID != nil && action == nil
        if isCloseHovered != hovered { isCloseHovered = hovered }
    }

    func reset() {
        cancelDwell()
        if mailBadgeNeedsAuthorization { mailBadgeNeedsAuthorization = false }
        if isChoosingWindow { windows = [] }
        if windowPage != 0 { windowPage = 0 }
        setWindowHover(nil, action: nil)
        if hoveredScriptAction != nil { hoveredScriptAction = nil }
        if id != nil { id = nil }
        if closeTargetID != nil { closeTargetID = nil }
        if isCloseHovered { isCloseHovered = false }
        if isOpenMainWindowHovered { isOpenMainWindowHovered = false }
    }

    private func cancelDwell() {
        dwellTimer?.invalidate()
        dwellTimer = nil
        windowLookup?.cancel()
        windowLookup = nil
    }

    func update(at point: CGPoint, slots: [WheelSlot], allowsBeyondEdge: Bool, actionDelay: TimeInterval? = nil) {
        let inset = WheelActionGeometry.inset(diameter: diameter)
        let local = CGPoint(x: point.x - inset, y: point.y - inset)
        if WheelGeometry.isOpenMainWindowArea(at: local, diameter: diameter) {
            if !isOpenMainWindowHovered {
                reset()
                isOpenMainWindowHovered = true
            }
            return
        }
        let center = WheelActionGeometry.outerSize(diameter: diameter) / 2
        let deadZone = WheelGeometry.deadZone * diameter / WheelGeometry.size
        if hypot(point.x - center, point.y - center) <= deadZone {
            reset()
            return
        }
        let targetIndex = slots.firstIndex { $0.app?.id == closeTargetID && closeTargetID != nil }
        let target = targetIndex.flatMap { slots[$0].app }
        if isChoosingWindow, let targetIndex {
            if updateWindowChoice(at: point, index: targetIndex, count: slots.count) { return }
            if hypot(point.x - center, point.y - center) > diameter / 2 { return }
            if WheelGeometry.index(at: local, count: slots.count, allowsBeyondEdge: false, diameter: diameter) == targetIndex {
                setWindowHover(nil, action: nil)
                return
            }
            reset()
        }
        if let target, let targetIndex {
            let actions = appActions(for: target)
            for (part, action) in actions.enumerated() {
                if WheelActionGeometry.actionPath(diameter: diameter, index: targetIndex, count: slots.count,
                                                  part: part, parts: actions.count).cgPath.contains(point) {
                    hoverAction(action)
                    return
                }
            }
        }
        let index = WheelGeometry.index(at: local, count: slots.count,
                                        allowsBeyondEdge: allowsBeyondEdge, diameter: diameter)
        let app = index.flatMap { slots[$0].app }
        let wheelCenter = diameter / 2
        let insideWheel = hypot(local.x - wheelCenter, local.y - wheelCenter) <= wheelCenter
        if app == nil && (index != nil || insideWheel) {
            reset()
            return
        }
        let canReveal = insideWheel && app?.application?.isTerminated == false
        select(app?.id, canRevealClose: canReveal, actionDelay: actionDelay, app: app)
    }

    func changeWindowPage(at point: CGPoint, slots: [WheelSlot]) -> Bool {
        guard windowPageCount > 1,
              let index = slots.firstIndex(where: { $0.app?.id == closeTargetID && closeTargetID != nil }) else { return false }
        for (part, step) in [(0, -1), (windowTabCount - 1, 1)] {
            if WheelActionGeometry.actionPath(diameter: diameter, index: index, count: slots.count,
                                              part: part, parts: windowTabCount, band: .windows).contains(point) {
                moveWindowPage(by: step)
                return true
            }
        }
        return false
    }

    private func updateWindowChoice(at point: CGPoint, index: Int, count: Int) -> Bool {
        if let hoveredWindow, visibleWindows.indices.contains(hoveredWindow) {
            let actions = windowActions(for: windows[hoveredWindow])
            for (part, action) in actions.enumerated() {
                if WheelActionGeometry.actionPath(diameter: diameter, index: index, count: count,
                                                  part: part, parts: actions.count, band: .windowActions).contains(point) {
                    setWindowHover(hoveredWindow, action: action)
                    return true
                }
            }
        }
        for (part, windowIndex) in visibleWindows.indices.enumerated() {
            if WheelActionGeometry.actionPath(diameter: diameter, index: index, count: count,
                                              part: part + firstWindowTab, parts: windowTabCount, band: .windows).contains(point) {
                setWindowHover(windowIndex, action: .open)
                return true
            }
        }
        // Keep the submenu visible while crossing the gap, but release in the gap cancels.
        setWindowHover(hoveredWindow, action: nil)
        return false
    }

    func appActions(for app: WheelApp) -> [AppScriptAction?] {
        let authorization: [AppScriptAction?] = mailBadgeNeedsAuthorization && app.id == AppScriptActions.mailID
            ? [AppScriptActions.authorizeMailBadge] : []
        return authorization + app.scriptActions.map(Optional.some) + (app.canRequestQuit ? [nil] : [])
    }

    func windowActions(for window: WheelWindow) -> [WindowAction] {
        if closeTargetID == AppScriptActions.finderID { return window.scriptActions.map(WindowAction.script) }
        return mailBadgeNeedsAuthorization ? [.script(AppScriptActions.authorizeMailBadge)] + window.actions : window.actions
    }
}

enum WheelActionGeometry {
    enum Band {
        case standard, windows, windowActions

        var offsets: ClosedRange<CGFloat> {
            switch self {
            case .standard: 10...80
            case .windows: 10...42
            case .windowActions: 48...80
            }
        }
    }

    private static let padding: CGFloat = 88
    static func inset(diameter: CGFloat) -> CGFloat { diameter * padding / WheelGeometry.size }
    static func outerSize(diameter: CGFloat) -> CGFloat { diameter + 2 * inset(diameter: diameter) }
    static func fittingDiameter(_ requested: CGFloat, available: CGSize) -> CGFloat {
        min(requested, max(1, min(available.width, available.height)) / (1 + 2 * padding / WheelGeometry.size))
    }
    static func actionRadius(diameter: CGFloat, band: Band = .standard) -> CGFloat {
        let offsets = band.offsets
        return diameter / 2 + diameter * (offsets.lowerBound + offsets.upperBound) / (2 * WheelGeometry.size)
    }
    static func closePath(diameter: CGFloat, index: Int, count: Int) -> Path {
        actionPath(diameter: diameter, index: index, count: count, part: 0, parts: 1)
    }

    static func actionAngle(index: Int, count: Int, part: Int, parts: Int) -> Double {
        let span = min(360 / Double(count), 60) - 4
        return Double(index) * 360 / Double(count) - 90
            + span * ((Double(part) + 0.5) / Double(parts) - 0.5)
    }

    static func actionPath(diameter: CGFloat, index: Int, count: Int, part: Int, parts: Int, band: Band = .standard) -> Path {
        guard count > 0, (0..<count).contains(index), parts > 0, (0..<parts).contains(part) else { return Path() }
        let side = outerSize(diameter: diameter)
        let center = CGPoint(x: side / 2, y: side / 2)
        let middle = actionAngle(index: index, count: count, part: part, parts: parts)
        let halfSpan = (min(360 / Double(count), 60) - 4) / Double(parts) / 2 - (parts > 1 ? 0.75 : 0)
        let inner = diameter / 2 + diameter * band.offsets.lowerBound / WheelGeometry.size
        let outer = diameter / 2 + diameter * band.offsets.upperBound / WheelGeometry.size
        let start = Angle.degrees(middle - halfSpan)
        let end = Angle.degrees(middle + halfSpan)
        var path = Path()
        path.addArc(center: center, radius: outer, startAngle: start, endAngle: end, clockwise: false)
        path.addArc(center: center, radius: inner, startAngle: end, endAngle: start, clockwise: true)
        path.closeSubpath()
        return path
    }
    static func panelFrame(around point: CGPoint, diameter: CGFloat, visibleFrame: CGRect) -> CGRect {
        WheelGeometry.panelFrame(around: point, visibleFrame: visibleFrame, diameter: outerSize(diameter: diameter))
    }
}

private struct OuterActionSector: Shape {
    let diameter: CGFloat
    let index: Int
    let count: Int
    let part: Int
    let parts: Int
    var band: WheelActionGeometry.Band = .standard
    func path(in rect: CGRect) -> Path {
        WheelActionGeometry.actionPath(diameter: diameter, index: index, count: count, part: part, parts: parts, band: band)
    }
}

struct AppActionSector: View {
    let diameter: CGFloat
    let index: Int
    let count: Int
    let part: Int
    let parts: Int
    let action: AppScriptAction?
    let theme: WheelTheme
    var highlighted = false

    var body: some View {
        let side = WheelActionGeometry.outerSize(diameter: diameter)
        let angle = WheelActionGeometry.actionAngle(index: index, count: count,
                                                     part: part, parts: parts) * .pi / 180
        let radius = WheelActionGeometry.actionRadius(diameter: diameter)
        let shape = OuterActionSector(diameter: diameter, index: index, count: count,
                                      part: part, parts: parts)
        let accent: Color = action == AppScriptActions.authorizeMailBadge ? .orange : (action == nil ? .red : .accentColor)
        ZStack {
            WheelBackdrop(shape: shape, theme: theme)
            if action == nil && theme.isAero {
                shape.fill(Color(red: 0.45, green: 0.06, blue: 0.13)
                    .opacity(theme == .frutigerAeroGlass
                             ? (highlighted ? 0.82 : 0.68)
                             : (highlighted ? 0.95 : 0.80)))
            } else {
                shape.fill(accent.opacity(highlighted ? 0.40 : 0.08))
            }
            shape.stroke(accent.opacity(highlighted ? 0.9 : 0.35), lineWidth: theme == .highContrast ? 2 : 1)
                .shadow(color: accent.opacity(theme == .glass && highlighted ? 0.4 : 0), radius: 8)
            VStack(spacing: 3) {
                Image(systemName: action?.symbol ?? "xmark.circle.fill")
                    .font(.system(size: parts == 1 ? 18 : 14 * diameter / WheelGeometry.size,
                                  weight: .semibold))
                if parts == 1 {
                    Text(action?.displayTitle ?? L10n.text("Fechar"))
                        .font(.system(size: 11, weight: .semibold)).lineLimit(1)
                }
            }
            .foregroundStyle(theme == .highContrast || theme.isAero || highlighted ? Color.white : accent)
            .offset(x: cos(angle) * radius, y: sin(angle) * radius)
        }
        .frame(width: side, height: side)
    }
}

struct WheelWithActions: View {
    @ObservedObject var model: RunningApps
    @ObservedObject var interaction: WheelInteraction
    var isActive = true
    var showsMemoryUsage = false
    var theme: WheelTheme = .glass
    var isMainWindowOpen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var targetIndex: Int? {
        guard let target = interaction.closeTargetID else { return nil }
        return model.slots.firstIndex { $0.app?.id == target }
    }

    private var selectedActionTitle: String? {
        guard interaction.closeTargetID == interaction.id else { return nil }
        if interaction.isChoosingWindow {
            guard let action = interaction.hoveredWindowAction, action != .open else { return nil }
            return action.title
        }
        if let action = interaction.hoveredScriptAction { return action.displayTitle }
        return interaction.isCloseHovered ? L10n.text("Fechar") : nil
    }

    private var selectedWindowTitle: String? {
        guard interaction.isChoosingWindow else { return nil }
        return interaction.hoveredWindow.map { interaction.windowTitle(at: $0) }
            ?? L10n.text("Escolha uma janela")
    }

    @ViewBuilder
    private func windowSectors(at index: Int) -> some View {
        ForEach(Array(interaction.visibleWindows.indices.enumerated()), id: \.element) { part, windowIndex in
            let window = interaction.windows[windowIndex]
            windowSector(index: index, part: part + interaction.firstWindowTab, parts: interaction.windowTabCount,
                         band: .windows, highlighted: interaction.hoveredWindow == windowIndex,
                         label: interaction.windowTitle(at: windowIndex)) {
                Text(String(windowIndex + 1)).fontWeight(.semibold)
            } perform: {
                model.perform(.open, on: window)
            }
        }
        if interaction.windowPageCount > 1 {
            windowPageArrow(-1, at: index)
            windowPageArrow(1, at: index)
        }
        if let hoveredWindow = interaction.hoveredWindow {
            let window = interaction.windows[hoveredWindow]
            let actions = interaction.windowActions(for: window)
            ForEach(actions.indices, id: \.self) { part in
                let action = actions[part]
                let accent: Color? = action == .script(AppScriptActions.authorizeMailBadge) ? .orange : (action == .close ? .red : nil)
                windowSector(index: index, part: part, parts: actions.count,
                             band: .windowActions, highlighted: interaction.hoveredWindowAction == action,
                             label: action.title, accent: accent) {
                    Image(systemName: action.symbol)
                } perform: {
                    model.perform(action, on: window)
                }
            }
        }
    }

    private func windowPageArrow(_ step: Int, at index: Int) -> some View {
        let available = (0..<interaction.windowPageCount).contains(interaction.windowPage + step)
        return windowSector(index: index, part: step < 0 ? 0 : interaction.windowTabCount - 1,
                            parts: interaction.windowTabCount, band: .windows, highlighted: false,
                            label: L10n.text(step < 0 ? "Página anterior" : "Próxima página")) {
            Image(systemName: step < 0 ? "chevron.left" : "chevron.right")
        } perform: {
            interaction.moveWindowPage(by: step)
        }
        .opacity(available ? 1 : 0.35)
    }

    private func windowSector<Label: View>(index: Int, part: Int, parts: Int,
                                           band: WheelActionGeometry.Band, highlighted: Bool,
                                           label: String, accent: Color? = nil,
                                           @ViewBuilder content: () -> Label,
                                           perform: @escaping () -> Void) -> some View {
        let diameter = interaction.diameter
        let side = WheelActionGeometry.outerSize(diameter: diameter)
        let shape = OuterActionSector(diameter: diameter, index: index, count: model.slots.count,
                                      part: part, parts: parts, band: band)
        let angle = WheelActionGeometry.actionAngle(index: index, count: model.slots.count,
                                                    part: part, parts: parts) * .pi / 180
        let radius = WheelActionGeometry.actionRadius(diameter: diameter, band: band)
        let tint = accent ?? theme.accent
        return ZStack {
            WheelBackdrop(shape: shape, theme: theme)
            shape.fill(tint.opacity(highlighted ? 0.40 : 0.12))
            shape.stroke(tint.opacity(highlighted ? 0.9 : 0.5), lineWidth: theme == .highContrast ? 2 : 1)
            content()
                .font(.system(size: 12 * diameter / WheelGeometry.size, weight: .semibold))
                .foregroundStyle(highlighted || theme.isAero || theme == .highContrast ? Color.white : tint)
                .offset(x: cos(angle) * radius, y: sin(angle) * radius)
        }
        .frame(width: side, height: side)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { perform() }
        .help(label)
    }

    var body: some View {
        let diameter = interaction.diameter
        let side = WheelActionGeometry.outerSize(diameter: diameter)
        ZStack {
            WheelView(model: model, selectedID: interaction.id, selectedActionTitle: selectedActionTitle,
                      selectedWindowTitle: selectedWindowTitle, isOpenMainWindowHovered: interaction.isOpenMainWindowHovered,
                      isActive: isActive, showsMemoryUsage: showsMemoryUsage, theme: theme, isMainWindowOpen: isMainWindowOpen)
                .scaleEffect(diameter / WheelGeometry.size)
                .frame(width: diameter, height: diameter)

            if let index = targetIndex, interaction.isChoosingWindow {
                windowSectors(at: index)
            } else if let index = targetIndex, let target = model.slots[index].app {
                let actions = interaction.appActions(for: target)
                ForEach(actions.indices, id: \.self) { part in
                    let action = actions[part]
                    let highlighted = action.map { $0 == interaction.hoveredScriptAction } ?? interaction.isCloseHovered
                    let label = action.map(\.displayTitle) ?? L10n.text("Fechar %@", target.name)
                    AppActionSector(diameter: diameter, index: index, count: model.slots.count,
                                    part: part, parts: actions.count, action: action,
                                    theme: theme, highlighted: highlighted)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(label)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction {
                        if let action { model.perform(action, on: target) }
                        else { model.requestQuit(target) }
                    }
                    .help(label)
                }
            }
        }
        .frame(width: side, height: side)
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.15), value: interaction.closeTargetID)
        .animation(.easeOut(duration: 0.12), value: interaction.isCloseHovered)
    }
}
