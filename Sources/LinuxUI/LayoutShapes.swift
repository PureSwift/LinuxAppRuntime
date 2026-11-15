import DynamicUI
import Foundation

/// Shapes, and the pull-to-refresh wrapper around lists (`RenderIR.md`).
extension Layout {

    /// A `Shape`: filled with `fill`, outlined with `stroke` at `lineWidth`,
    /// or filled with the foreground color. Like `Color`, it takes the space
    /// it's offered. Ellipses that aren't circles draw as capsules: the
    /// canvas has no ellipse.
    func placeShape(_ node: RenderNode, in rect: Rect, _ environment: ViewEnvironment, _ box: LayoutBox) {
        let props = node.props
        let shortest = min(rect.width, rect.height)
        var frame = rect
        let radius: Double
        switch props["shape"]?.string {
        case "circle":
            frame = rect.place(Size(width: shortest, height: shortest), .center)
            radius = shortest / 2
        case "ellipse", "capsule":
            radius = shortest / 2
        case "roundedRectangle":
            radius = min(props["cornerRadius"]?.double ?? 0, shortest / 2)
        default:
            radius = 0
        }
        let palette = environment.palette
        if let stroke = palette.color(props["stroke"]) {
            let width = props["lineWidth"]?.double ?? 1
            // Strokes are centered on the outline, as SwiftUI's are.
            box.ops.append(.stroke(frame.insetBy(dx: -width / 2, dy: -width / 2), stroke, width: width, radius: radius + width / 2))
        } else {
            let fill = palette.color(props["fill"]) ?? environment.foregroundColor
            box.ops.append(.fill(frame, fill, radius: radius))
        }
    }

    /// A `Refreshable`: its list, with a spinner over the top while
    /// `refreshing`. Pulling past the top sends `refresh` (`Input.swift`).
    func placeRefreshable(_ node: RenderNode, in rect: Rect, _ environment: ViewEnvironment, _ box: LayoutBox) {
        if let first = node.children.first {
            box.children.append(place(first, in: rect, environment))
        }
        guard node.props["refreshing"]?.bool == true else { return }
        let palette = environment.palette
        let center = Point(x: rect.midX, y: rect.minY + 28)
        box.overlayOps.append(.circle(center, radius: 18, palette.card))
        for index in 0..<8 {
            let angle = Double(index) / 8 * 2 * Double.pi
            box.overlayOps.append(.circle(Point(x: center.x + 9 * cos(angle), y: center.y + 9 * sin(angle)),
                                          radius: 2.2, palette.secondary.opacity(0.25 + 0.75 * Double(index) / 8)))
        }
    }
}
