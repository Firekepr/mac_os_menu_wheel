import Foundation
import CoreGraphics


func expect(_ point: CGPoint, _ count: Int, _ expected: Int?, beyond: Bool = true) {
    precondition(WheelGeometry.index(at: point, count: count, allowsBeyondEdge: beyond) == expected,
                 "Unexpected sector for \(point), count \(count)")
}
expect(CGPoint(x: 190, y: 55), 8, 0)
expect(CGPoint(x: 285, y: 95), 8, 1)
expect(CGPoint(x: 325, y: 190), 8, 2)
expect(CGPoint(x: 285, y: 285), 8, 3)
expect(CGPoint(x: 190, y: 325), 8, 4)
expect(CGPoint(x: 95, y: 285), 8, 5)
expect(CGPoint(x: 55, y: 190), 8, 6)
expect(CGPoint(x: 95, y: 95), 8, 7)
expect(CGPoint(x: 190, y: 190), 8, nil)
expect(CGPoint(x: 266, y: 190), 8, nil)
expect(CGPoint(x: 800, y: 190), 8, 2)
expect(CGPoint(x: 800, y: 190), 8, nil, beyond: false)
expect(CGPoint(x: 190, y: 55), 0, nil)
expect(CGPoint(x: 55, y: 190), 1, 0)
for count in 1...8 {
    for index in 0..<count {
        let angle = Double(index) * 2 * .pi / Double(count) - .pi / 2
        expect(CGPoint(x: 190 + cos(angle) * 135, y: 190 + sin(angle) * 135), count, index)
    }
}
let leftScreen = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
for point in [CGPoint(x: -1920, y: -200), CGPoint(x: -1, y: -200), CGPoint(x: -1920, y: 879), CGPoint(x: -1, y: 879), CGPoint(x: -900, y: 300)] {
    let frame = WheelGeometry.panelFrame(around: point, visibleFrame: leftScreen)
    precondition(frame.midX == point.x && frame.midY == point.y, "Panel moved away from the pointer")
    let localPointer = CGPoint(x: point.x - frame.minX, y: frame.maxY - point.y)
    precondition(WheelGeometry.index(at: localPointer, count: 8, allowsBeyondEdge: true) == nil, "Pointer no longer starts in the cancellation center")
}
let centered = WheelGeometry.panelFrame(around: CGPoint(x: 500, y: 500), visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900))
precondition(centered.midX == 500 && centered.midY == 500)
print("Geometry checks passed: directions, dead zone, edges, empty list, alternate screen.")
