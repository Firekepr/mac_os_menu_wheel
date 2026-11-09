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
    @Published private(set) var isOpenMainWindowHovered = false
    @Published var isPresented = false
    @Published private var storedDiameter: CGFloat = WheelGeometry.size
    var diameter: CGFloat {
        get { storedDiameter }
        set { if storedDiameter != newValue { storedDiameter = newValue } }
    }
    private var dwellTimer: Timer?
    private let dwellDelay: TimeInterval

    init(dwellDelay: TimeInterval = 0.65) { self.dwellDelay = dwellDelay }

    func select(_ id: String?, canRevealClose: Bool) {
        if isOpenMainWindowHovered { isOpenMainWindowHovered = false }
        if isCloseHovered { isCloseHovered = false }
        if self.id != id {
            cancelDwell()
            self.id = id
        }
        if let id, let closeTargetID, id != closeTargetID {
            self.closeTargetID = nil
        }
        guard canRevealClose, let id else { cancelDwell(); return }
        guard closeTargetID != id, dwellTimer == nil else { return }
        dwellTimer = Timer.scheduledTimer(withTimeInterval: dwellDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.id == id else { return }
                self.dwellTimer = nil
                self.closeTargetID = id
            }
        }
    }

    func hoverClose() {
        cancelDwell()
        if isOpenMainWindowHovered { isOpenMainWindowHovered = false }
        if id != closeTargetID { id = closeTargetID }
        let hovered = closeTargetID != nil
        if isCloseHovered != hovered { isCloseHovered = hovered }
    }

    func reset() {
        cancelDwell()
        if id != nil { id = nil }
        if closeTargetID != nil { closeTargetID = nil }
        if isCloseHovered { isCloseHovered = false }
        if isOpenMainWindowHovered { isOpenMainWindowHovered = false }
    }

    private func cancelDwell() {
        dwellTimer?.invalidate()
        dwellTimer = nil
    }

    func update(at point: CGPoint, slots: [WheelSlot], allowsBeyondEdge: Bool) {
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
        if target?.canRequestQuit == true,
           let targetIndex,
           WheelActionGeometry.closePath(diameter: diameter, index: targetIndex, count: slots.count).cgPath.contains(point) {
            hoverClose()
            return
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
        select(app?.id, canRevealClose: insideWheel && app?.canRequestQuit == true)
    }
}

enum WheelActionGeometry {
    private static let padding: CGFloat = 88
    static func inset(diameter: CGFloat) -> CGFloat { diameter * padding / WheelGeometry.size }
    static func outerSize(diameter: CGFloat) -> CGFloat { diameter + 2 * inset(diameter: diameter) }
    static func fittingDiameter(_ requested: CGFloat, available: CGSize) -> CGFloat {
        min(requested, max(1, min(available.width, available.height)) / (1 + 2 * padding / WheelGeometry.size))
    }
    static func actionRadius(diameter: CGFloat) -> CGFloat { diameter / 2 + diameter * 45 / WheelGeometry.size }
    static func closePath(diameter: CGFloat, index: Int, count: Int) -> Path {
        guard count > 0, (0..<count).contains(index) else { return Path() }
        let side = outerSize(diameter: diameter)
        let center = CGPoint(x: side / 2, y: side / 2)
        let middle = Double(index) * 360 / Double(count) - 90
        let halfSpan = min(360 / Double(count), 60) / 2 - 2
        let inner = diameter / 2 + diameter * 10 / WheelGeometry.size
        let outer = diameter / 2 + diameter * 80 / WheelGeometry.size
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

private struct CloseActionSector: Shape {
    let diameter: CGFloat
    let index: Int
    let count: Int
    func path(in rect: CGRect) -> Path {
        WheelActionGeometry.closePath(diameter: diameter, index: index, count: count)
    }
}

struct WheelWithActions: View {
    @ObservedObject var model: RunningApps
    @ObservedObject var interaction: WheelInteraction
    var isActive = true
    var theme: WheelTheme = .glass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var closeIndex: Int? {
        model.slots.firstIndex { slot in
            slot.app?.id == interaction.closeTargetID && interaction.closeTargetID != nil
                && slot.app?.canRequestQuit == true
        }
    }

    var body: some View {
        let diameter = interaction.diameter
        let side = WheelActionGeometry.outerSize(diameter: diameter)
        ZStack {
            WheelView(model: model, selectedID: interaction.id, isOpenMainWindowHovered: interaction.isOpenMainWindowHovered,
                      isActive: isActive, theme: theme)
                .scaleEffect(diameter / WheelGeometry.size)
                .frame(width: diameter, height: diameter)

            if let index = closeIndex, let target = model.slots[index].app {
                let angle = Double(index) * 2 * .pi / Double(model.slots.count) - .pi / 2
                let radius = WheelActionGeometry.actionRadius(diameter: diameter)
                let shape = CloseActionSector(diameter: diameter, index: index, count: model.slots.count)
                ZStack {
                    WheelBackdrop(shape: shape, theme: theme)
                    if theme.isAero {
                        shape.fill(Color(red: 0.45, green: 0.06, blue: 0.13)
                            .opacity(theme == .frutigerAeroGlass
                                     ? (interaction.isCloseHovered ? 0.82 : 0.68)
                                     : (interaction.isCloseHovered ? 0.95 : 0.80)))
                    } else {
                        shape.fill(.red.opacity(interaction.isCloseHovered ? 0.40 : 0.08))
                    }
                    shape.stroke(.red.opacity(interaction.isCloseHovered ? 0.9 : 0.35), lineWidth: theme == .highContrast ? 2 : 1)
                        .shadow(color: .red.opacity(theme == .glass && interaction.isCloseHovered ? 0.4 : 0), radius: 8)
                    VStack(spacing: 3) {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 18, weight: .semibold))
                        Text(L10n.text("Fechar")).font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(theme == .highContrast || theme.isAero || interaction.isCloseHovered
                                     ? Color.white : .red)
                    .offset(x: cos(angle) * radius, y: sin(angle) * radius)
                }
                .frame(width: side, height: side)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L10n.text("Fechar %@", target.name))
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { model.requestQuit(target) }
                .help(L10n.text("Fechar %@", target.name))
            }
        }
        .frame(width: side, height: side)
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.15), value: interaction.closeTargetID)
        .animation(.easeOut(duration: 0.12), value: interaction.isCloseHovered)
    }
}
