/// Draws a laid-out frame on a canvas (`Plan.md` §5.3).
///
/// A box draws its decorations outermost first (backgrounds and shadows
/// before its content, borders after), then its ops, its children inside
/// its clip, and its overlay ops. `cornerRadius` clips to its rectangle and
/// rounds the fills that cover exactly that rectangle, which is how SwiftUI
/// code uses it (`.padding().background(.blue).cornerRadius(8)`); SDL has
/// no rounded clips.
public struct Painter {

    let canvas: Canvas

    private var clips: [Rect]

    private var radii: [(rect: Rect, radius: Double)] = []

    public init(canvas: Canvas, bounds: Rect) {
        self.canvas = canvas
        self.clips = [bounds]
    }

    /// Draws the window: its background, the tree, then each overlay.
    public static func draw(_ frame: RenderFrame, on canvas: Canvas) {
        var painter = Painter(canvas: canvas, bounds: frame.bounds)
        canvas.fill(frame.bounds, color: frame.palette.background, radius: 0)
        if let root = frame.root {
            painter.draw(root, disabled: false)
        }
        for overlay in frame.overlays {
            painter.draw(overlay, disabled: false)
        }
    }

    mutating func draw(_ box: LayoutBox, disabled parentDisabled: Bool) {
        guard let clip = clips.last, box.frame.intersects(clip) || box.frame.isEmpty || !box.decorations.isEmpty else {
            return
        }
        let dims = box.disabled && !parentDisabled
        if dims {
            canvas.pushOpacity(0.45)
        }
        for decoration in box.decorations {
            begin(decoration)
        }
        draw(box.ops)
        if let boxClip = box.clip {
            push(boxClip)
        }
        for child in box.children {
            draw(child, disabled: box.disabled)
        }
        if box.clip != nil {
            pop()
        }
        draw(box.overlayOps)
        for decoration in box.decorations.reversed() {
            end(decoration)
        }
        if dims {
            canvas.popOpacity()
        }
    }

    private mutating func begin(_ decoration: LayoutBox.Decoration) {
        switch decoration {
        case .background(let color, let rect):
            canvas.fill(rect, color: color, radius: radius(for: rect))
        case .shadow(let color, let blur, let rect):
            // A soft edge from a few widening, fading layers.
            let layers = max(Int(blur / 3), 1)
            for layer in (0..<layers).reversed() {
                let spread = Double(layer + 1) * blur / Double(layers) / 2
                canvas.fill(rect.insetBy(dx: -spread, dy: -spread), color: color.opacity(1 / Double(layers + 1)),
                            radius: radius(for: rect) + spread)
            }
        case .opacity(let value):
            canvas.pushOpacity(value)
        case .cornerRadius(let radius, let rect):
            radii.append((rect, radius))
            push(rect)
        case .border:
            break
        }
    }

    private mutating func end(_ decoration: LayoutBox.Decoration) {
        switch decoration {
        case .border(let color, let width, let rect):
            canvas.stroke(rect, color: color, width: width, radius: radius(for: rect))
        case .opacity:
            canvas.popOpacity()
        case .cornerRadius:
            radii.removeLast()
            pop()
        case .background, .shadow:
            break
        }
    }

    private mutating func draw(_ ops: [LayoutBox.Op]) {
        for op in ops {
            switch op {
            case .fill(let rect, let color, let radius):
                canvas.fill(rect, color: color, radius: radius > 0 ? radius : self.radius(for: rect))
            case .stroke(let rect, let color, let width, let radius):
                canvas.stroke(rect, color: color, width: width, radius: radius)
            case .line(let from, let to, let color, let width):
                canvas.line(from: from, to: to, color: color, width: width)
            case .circle(let center, let radius, let color):
                canvas.fillCircle(center: center, radius: radius, color: color)
            case .text(let string, let font, let color, let rect, let alignment, let wrap):
                canvas.text(string, font: font, color: color, in: rect, alignment: alignment, wrap: wrap)
            case .clip(let rect):
                push(rect)
            case .unclip:
                pop()
            }
        }
    }

    private func radius(for rect: Rect) -> Double {
        guard let last = radii.last else { return 0 }
        let same = abs(last.rect.minX - rect.minX) < 0.5 && abs(last.rect.minY - rect.minY) < 0.5
            && abs(last.rect.width - rect.width) < 0.5 && abs(last.rect.height - rect.height) < 0.5
        return same ? last.radius : 0
    }

    private mutating func push(_ rect: Rect) {
        let clip = (clips.last ?? rect).intersection(rect)
        clips.append(clip)
        canvas.pushClip(clip)
    }

    private mutating func pop() {
        clips.removeLast()
        canvas.popClip()
    }
}
