import CSDL3
import Foundation
import LinuxUI

/// The player's `Canvas` over an `SDL_Renderer` (`Plan.md` §5.3).
///
/// Points scale to pixels by the window's density. Rounded rectangles and
/// circles are triangle fans from `SDL_RenderGeometry`, with a one-pixel
/// feather of transparent vertices around the edge so they look smooth;
/// text is SDL3_ttf's renderer text engine, cached for a frame.
final class SDLCanvas: Canvas {

    let renderer: OpaquePointer

    let fonts: SDLTextEngine

    private let textEngine: OpaquePointer

    var scale: Double = 1

    private var clips: [SDL_Rect] = []

    private var opacities: [Double] = [1]

    private var texts: [TextKey: (text: UnsafeMutablePointer<TTF_Text>, frame: Int)] = [:]

    private var frameNumber = 0

    private struct TextKey: Hashable {
        let string: String
        let font: FontSpec
        let wrap: Int32
        let alignment: Int
    }

    init?(renderer: OpaquePointer, fonts: SDLTextEngine) {
        guard let engine = TTF_CreateRendererTextEngine(renderer) else {
            return nil
        }
        self.renderer = renderer
        self.fonts = fonts
        self.textEngine = engine
        SDL_SetRenderDrawBlendMode(renderer, SDL_BLENDMODE_BLEND)
    }

    deinit {
        for entry in texts.values {
            TTF_DestroyText(entry.text)
        }
        TTF_DestroyRendererTextEngine(textEngine)
    }

    /// Starts a frame.
    func begin() {
        frameNumber += 1
        clips = []
        opacities = [1]
        SDL_SetRenderClipRect(renderer, nil)
    }

    /// Ends a frame: texts not drawn in it are freed.
    func end() {
        for (key, entry) in texts where entry.frame < frameNumber {
            TTF_DestroyText(entry.text)
            texts[key] = nil
        }
    }

    private var opacity: Double {
        opacities.last ?? 1
    }

    private func setColor(_ color: Color) {
        SDL_SetRenderDrawColorFloat(renderer, Float(color.red), Float(color.green), Float(color.blue), Float(color.alpha * opacity))
    }

    private func fcolor(_ color: Color, alpha: Double? = nil) -> SDL_FColor {
        SDL_FColor(r: Float(color.red), g: Float(color.green), b: Float(color.blue), a: Float((alpha ?? color.alpha) * opacity))
    }

    // MARK: Shapes

    func fill(_ rect: Rect, color: Color, radius: Double) {
        guard color.alpha > 0, !rect.isEmpty else { return }
        if radius <= 0 {
            setColor(color)
            var frect = pixels(rect)
            SDL_RenderFillRect(renderer, &frect)
            return
        }
        fillShape(outline(rect, radius: radius), color: color)
    }

    func stroke(_ rect: Rect, color: Color, width: Double, radius: Double) {
        guard color.alpha > 0, !rect.isEmpty, width > 0 else { return }
        let outer = outline(rect, radius: radius)
        let inner = outline(rect.insetBy(dx: width, dy: width), radius: max(radius - width, 0), points: outer.count)
        guard outer.count == inner.count, !outer.isEmpty else { return }
        let fill = fcolor(color)
        var vertices: [SDL_Vertex] = []
        var indices: [Int32] = []
        for index in outer.indices {
            vertices.append(vertex(outer[index], fill))
            vertices.append(vertex(inner[index], fill))
        }
        let count = Int32(outer.count)
        for index in 0..<count {
            let next = (index + 1) % count
            indices += [2 * index, 2 * index + 1, 2 * next, 2 * next, 2 * index + 1, 2 * next + 1]
        }
        SDL_RenderGeometry(renderer, nil, vertices, Int32(vertices.count), indices, Int32(indices.count))
    }

    func line(from: Point, to: Point, color: Color, width: Double) {
        if from.x == to.x || from.y == to.y {
            fill(Rect(x: min(from.x, to.x), y: min(from.y, to.y), width: max(abs(to.x - from.x), width),
                      height: max(abs(to.y - from.y), width)), color: color, radius: 0)
            return
        }
        setColor(color)
        SDL_RenderLine(renderer, Float(from.x * scale), Float(from.y * scale), Float(to.x * scale), Float(to.y * scale))
    }

    func fillCircle(center: Point, radius: Double, color: Color) {
        let segments = max(Int(radius * scale / 1.5), 12)
        var points: [(Double, Double)] = []
        for index in 0..<segments {
            let angle = Double(index) / Double(segments) * 2 * Double.pi
            points.append(((center.x + radius * cos(angle)) * scale, (center.y + radius * sin(angle)) * scale))
        }
        fillShape(points, color: color)
    }

    /// A convex outline in pixels: a fan from its center, feathered.
    private func fillShape(_ points: [(Double, Double)], color: Color) {
        guard points.count >= 3 else { return }
        let cx = points.reduce(0) { $0 + $1.0 } / Double(points.count)
        let cy = points.reduce(0) { $0 + $1.1 } / Double(points.count)
        let solid = fcolor(color), clear = fcolor(color, alpha: 0)
        var vertices = [vertex((cx, cy), solid)]
        for point in points {
            vertices.append(vertex(point, solid))
            let dx = point.0 - cx, dy = point.1 - cy
            let length = max((dx * dx + dy * dy).squareRoot(), 0.0001)
            vertices.append(vertex((point.0 + dx / length, point.1 + dy / length), clear))
        }
        var indices: [Int32] = []
        let count = Int32(points.count)
        for index in 0..<count {
            let next = (index + 1) % count
            let p = 1 + 2 * index, q = p + 1, pn = 1 + 2 * next, qn = pn + 1
            indices += [0, p, pn, p, q, pn, pn, q, qn]
        }
        SDL_RenderGeometry(renderer, nil, vertices, Int32(vertices.count), indices, Int32(indices.count))
    }

    /// A rounded rectangle's outline in pixels, corner arcs clockwise from
    /// the top-left.
    private func outline(_ rect: Rect, radius: Double, points: Int? = nil) -> [(Double, Double)] {
        let x0 = rect.minX * scale, y0 = rect.minY * scale, x1 = rect.maxX * scale, y1 = rect.maxY * scale
        let r = min(max(radius, 0) * scale, (x1 - x0) / 2, (y1 - y0) / 2)
        let segments = points.map { max($0 / 4 - 1, 1) } ?? min(max(Int(r / 2), 3), 16)
        let corners: [(Double, Double, Double)] = [
            (x0 + r, y0 + r, Double.pi), (x1 - r, y0 + r, 1.5 * Double.pi),
            (x1 - r, y1 - r, 0), (x0 + r, y1 - r, 0.5 * Double.pi),
        ]
        var result: [(Double, Double)] = []
        for (cx, cy, start) in corners {
            for step in 0...segments {
                let angle = start + Double(step) / Double(segments) * Double.pi / 2
                result.append((cx + r * cos(angle), cy + r * sin(angle)))
            }
        }
        return result
    }

    private func vertex(_ point: (Double, Double), _ color: SDL_FColor) -> SDL_Vertex {
        SDL_Vertex(position: SDL_FPoint(x: Float(point.0), y: Float(point.1)), color: color, tex_coord: SDL_FPoint(x: 0, y: 0))
    }

    private func pixels(_ rect: Rect) -> SDL_FRect {
        SDL_FRect(x: Float(rect.minX * scale), y: Float(rect.minY * scale), w: Float(rect.width * scale), h: Float(rect.height * scale))
    }

    // MARK: Text

    func text(_ string: String, font: FontSpec, color: Color, in rect: Rect, alignment: HorizontalAlignment, wrap: Bool) {
        guard !string.isEmpty, color.alpha > 0, let ttf = fonts.font(font) else { return }
        let wrapWidth = wrap ? max(Int32((rect.width * scale).rounded(.up)) + 1, 1) : 0
        let align: TTF_HorizontalAlignment
        switch alignment {
        case .leading: align = TTF_HORIZONTAL_ALIGN_LEFT
        case .center: align = TTF_HORIZONTAL_ALIGN_CENTER
        case .trailing: align = TTF_HORIZONTAL_ALIGN_RIGHT
        }
        let key = TextKey(string: string, font: font, wrap: wrapWidth, alignment: Int(align.rawValue))
        let text: UnsafeMutablePointer<TTF_Text>
        // The font's alignment applies to the texts laid out with it; the
        // text engine measures with it left-aligned.
        TTF_SetFontWrapAlignment(ttf, align)
        defer { TTF_SetFontWrapAlignment(ttf, TTF_HORIZONTAL_ALIGN_LEFT) }
        if let entry = texts[key] {
            text = entry.text
        } else {
            guard let made = TTF_CreateText(textEngine, ttf, string, 0) else { return }
            TTF_SetTextWrapWidth(made, wrapWidth)
            text = made
        }
        texts[key] = (text, frameNumber)
        TTF_SetTextColorFloat(text, Float(color.red), Float(color.green), Float(color.blue), Float(color.alpha * opacity))
        var width: Int32 = 0, height: Int32 = 0
        TTF_GetTextSize(text, &width, &height)
        let box = pixels(rect)
        var x = Double(box.x)
        if !wrap || width < Int32(box.w) {
            switch alignment {
            case .leading: break
            case .center: x += (Double(box.w) - Double(width)) / 2
            case .trailing: x += Double(box.w) - Double(width)
            }
        }
        let y = Double(box.y) + max((Double(box.h) - Double(height)) / 2, 0)
        pushClip(rect)
        TTF_DrawRendererText(text, Float(x.rounded()), Float(y.rounded()))
        popClip()
    }

    // MARK: Clips and opacity

    func pushClip(_ rect: Rect) {
        let x0 = Int32((rect.minX * scale).rounded(.down)), y0 = Int32((rect.minY * scale).rounded(.down))
        let x1 = Int32((rect.maxX * scale).rounded(.up)), y1 = Int32((rect.maxY * scale).rounded(.up))
        var clip = SDL_Rect(x: x0, y: y0, w: max(x1 - x0, 0), h: max(y1 - y0, 0))
        if let current = clips.last {
            let ix0 = max(clip.x, current.x), iy0 = max(clip.y, current.y)
            let ix1 = min(clip.x + clip.w, current.x + current.w), iy1 = min(clip.y + clip.h, current.y + current.h)
            clip = SDL_Rect(x: ix0, y: iy0, w: max(ix1 - ix0, 0), h: max(iy1 - iy0, 0))
        }
        clips.append(clip)
        SDL_SetRenderClipRect(renderer, &clip)
    }

    func popClip() {
        clips.removeLast()
        if var clip = clips.last {
            SDL_SetRenderClipRect(renderer, &clip)
        } else {
            SDL_SetRenderClipRect(renderer, nil)
        }
    }

    func pushOpacity(_ value: Double) {
        opacities.append(opacity * value)
    }

    func popOpacity() {
        if opacities.count > 1 {
            opacities.removeLast()
        }
    }
}
