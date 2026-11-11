import Foundation
import CoreGraphics

enum WheelGeometry {
    static let size: CGFloat = 380
    static let deadZone: CGFloat = 76
    static let centerDiameter: CGFloat = 126
    static let centerOpenFraction: CGFloat = 0.30

    static func angle(for index: Int, count: Int) -> Double {
        Double(index) * 2 * .pi / Double(max(count, 1)) - .pi / 2
    }

    /// Bottom 30% of the visible center disk, in wheel-local coordinates.
    static func isOpenMainWindowArea(at point: CGPoint, diameter: CGFloat = size) -> Bool {
        guard diameter.isFinite, diameter > 0 else { return false }
        let dx = (point.x - diameter / 2) * size / diameter
        let dy = (point.y - diameter / 2) * size / diameter
        let radius = centerDiameter / 2
        return dy >= radius * (1 - 2 * centerOpenFraction) && hypot(dx, dy) <= radius
    }

    /// Coordinates are local to the wheel, with y pointing down as in SwiftUI.
    static func index(at point: CGPoint, count: Int, allowsBeyondEdge: Bool, diameter: CGFloat = size,
                      innerRadius: CGFloat? = nil, outerInset: CGFloat = 0) -> Int? {
        guard count > 0, diameter.isFinite, diameter > 0 else { return nil }
        let dx = point.x - diameter / 2
        let dy = point.y - diameter / 2
        let distance = hypot(dx, dy)
        let innerRadius = innerRadius ?? deadZone * diameter / size
        guard distance > innerRadius, allowsBeyondEdge || distance <= diameter / 2 - outerInset else { return nil }
        let step = 2 * Double.pi / Double(count)
        let angle = atan2(dy, dx) + .pi / 2 + step / 2
        let normalized = (angle + 2 * .pi).truncatingRemainder(dividingBy: 2 * .pi)
        return Int(normalized / step) % count
    }

    static func panelFrame(around point: CGPoint, visibleFrame: CGRect, diameter: CGFloat = size) -> CGRect {
        let size = min(max(diameter, 1), visibleFrame.width, visibleFrame.height)
        // Keep the gesture's origin at the exact center, including at screen
        // edges. Parts of the panel may extend beyond the current display.
        return CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
    }
}
