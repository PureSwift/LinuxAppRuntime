/// Measures text: SDL3_ttf in the app, a fixed-width stand-in in tests.
public protocol TextEngine: AnyObject {

    /// The size of `text` wrapped to `maxWidth` (`nil`: one line per
    /// paragraph), at most `lineLimit` lines.
    func measure(_ text: String, font: FontSpec, maxWidth: Double?, lineLimit: Int?) -> Size

    /// The height of one line.
    func lineHeight(_ font: FontSpec) -> Double

    /// The width of one unwrapped line, for carets and hit testing.
    func width(_ text: String, font: FontSpec) -> Double
}

/// What the player draws on (`Plan.md` §5.3). Coordinates are points; the
/// SDL canvas scales them to pixels.
public protocol Canvas: AnyObject {

    func fill(_ rect: Rect, color: Color, radius: Double)

    func stroke(_ rect: Rect, color: Color, width: Double, radius: Double)

    func line(from: Point, to: Point, color: Color, width: Double)

    func fillCircle(center: Point, radius: Double, color: Color)

    /// `text` wrapped to `rect`'s width when `wrap`, aligned within it,
    /// clipped to it.
    func text(_ text: String, font: FontSpec, color: Color, in rect: Rect, alignment: HorizontalAlignment, wrap: Bool)

    /// Clips what follows to `rect`, within the current clip.
    func pushClip(_ rect: Rect)

    func popClip()

    /// Multiplies the alpha of what follows.
    func pushOpacity(_ value: Double)

    func popOpacity()
}

/// A text engine where every character is `0.55 × size` wide and a line is
/// `1.25 × size` tall, wrapping at spaces: predictable layouts for tests.
public final class FixedTextEngine: TextEngine {

    public init() { }

    public func lineHeight(_ font: FontSpec) -> Double {
        (font.size * 1.25).rounded()
    }

    public func width(_ text: String, font: FontSpec) -> Double {
        Double(text.count) * font.size * 0.55
    }

    public func measure(_ text: String, font: FontSpec, maxWidth: Double?, lineLimit: Int?) -> Size {
        let lines = self.lines(text, font: font, maxWidth: maxWidth)
        let count = lineLimit.map { min($0, lines.count) } ?? lines.count
        let width = lines.prefix(count).map { self.width($0, font: font) }.max() ?? 0
        return Size(width: width, height: Double(max(count, 1)) * lineHeight(font))
    }

    func lines(_ text: String, font: FontSpec, maxWidth: Double?) -> [String] {
        var lines: [String] = []
        for paragraph in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let maxWidth else {
                lines.append(String(paragraph))
                continue
            }
            var line = ""
            for word in paragraph.split(separator: " ") {
                let candidate = line.isEmpty ? String(word) : line + " " + word
                if !line.isEmpty, width(candidate, font: font) > maxWidth {
                    lines.append(line)
                    line = String(word)
                } else {
                    line = candidate
                }
            }
            lines.append(line)
        }
        return lines
    }
}

/// Records what's drawn, for tests.
public final class RecordingCanvas: Canvas {

    public enum Command: Equatable {
        case fill(Rect, Color, radius: Double)
        case stroke(Rect, Color, width: Double, radius: Double)
        case line(Point, Point, Color)
        case circle(Point, radius: Double, Color)
        case text(String, FontSpec, Color, Rect)
        case pushClip(Rect)
        case popClip
        case pushOpacity(Double)
        case popOpacity
    }

    public private(set) var commands: [Command] = []

    public init() { }

    public func fill(_ rect: Rect, color: Color, radius: Double) {
        commands.append(.fill(rect, color, radius: radius))
    }

    public func stroke(_ rect: Rect, color: Color, width: Double, radius: Double) {
        commands.append(.stroke(rect, color, width: width, radius: radius))
    }

    public func line(from: Point, to: Point, color: Color, width: Double) {
        commands.append(.line(from, to, color))
    }

    public func fillCircle(center: Point, radius: Double, color: Color) {
        commands.append(.circle(center, radius: radius, color))
    }

    public func text(_ text: String, font: FontSpec, color: Color, in rect: Rect, alignment: HorizontalAlignment, wrap: Bool) {
        commands.append(.text(text, font, color, rect))
    }

    public func pushClip(_ rect: Rect) {
        commands.append(.pushClip(rect))
    }

    public func popClip() {
        commands.append(.popClip)
    }

    public func pushOpacity(_ value: Double) {
        commands.append(.pushOpacity(value))
    }

    public func popOpacity() {
        commands.append(.popOpacity)
    }

    /// The strings drawn, in order.
    public var texts: [String] {
        commands.compactMap {
            if case .text(let text, _, _, _) = $0 { text } else { nil }
        }
    }

    /// Where `string` was drawn.
    public func rect(ofText string: String) -> Rect? {
        for command in commands {
            if case .text(let text, _, _, let rect) = command, text == string {
                return rect
            }
        }
        return nil
    }

    public func color(ofText string: String) -> Color? {
        for command in commands {
            if case .text(let text, _, let color, _) = command, text == string {
                return color
            }
        }
        return nil
    }
}
