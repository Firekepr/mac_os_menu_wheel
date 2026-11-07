import Foundation
import CoreGraphics

enum WheelGeometry {
    static let size: CGFloat = 380
    static let deadZone: CGFloat = 76

    /// Coordinates are local to the wheel, with y pointing down as in SwiftUI.
    static func index(at point: CGPoint, count: Int, allowsBeyondEdge: Bool, diameter: CGFloat = size) -> Int? {
        guard count > 0, diameter.isFinite, diameter > 0 else { return nil }
        let dx = (point.x - diameter / 2) * size / diameter
        let dy = (point.y - diameter / 2) * size / diameter
        let distance = hypot(dx, dy)
        guard distance > deadZone, allowsBeyondEdge || distance <= size / 2 else { return nil }
        let step = 2 * Double.pi / Double(count)
        let angle = atan2(dy, dx) + .pi / 2 + step / 2
        let normalized = (angle + 2 * .pi).truncatingRemainder(dividingBy: 2 * .pi)
        return Int(normalized / step) % count
    }

    static func panelFrame(around point: CGPoint, visibleFrame: CGRect, diameter: CGFloat = size) -> CGRect {
        let size = min(max(diameter, 1), visibleFrame.width, visibleFrame.height)
        let x = min(max(point.x - size / 2, visibleFrame.minX), max(visibleFrame.minX, visibleFrame.maxX - size))
        let y = min(max(point.y - size / 2, visibleFrame.minY), max(visibleFrame.minY, visibleFrame.maxY - size))
        return CGRect(x: x, y: y, width: size, height: size)
    }
}
