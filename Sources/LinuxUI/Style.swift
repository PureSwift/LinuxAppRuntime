import DynamicUI

/// A color, components from 0 to 1.
public struct Color: Equatable, Hashable, Sendable {

    public var red: Double

    public var green: Double

    public var blue: Double

    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// `0xRRGGBB`.
    public init(hex: UInt32, alpha: Double = 1) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    public func opacity(_ value: Double) -> Color {
        Color(red: red, green: green, blue: blue, alpha: alpha * value)
    }

    public static let clear = Color(red: 0, green: 0, blue: 0, alpha: 0)

    public static let black = Color(hex: 0x000000)

    public static let white = Color(hex: 0xFFFFFF)
}

public enum ColorScheme: Sendable {
    case light
    case dark
}

/// The IR's named colors and the player's own (`RenderIR.md`), in
/// GNOME/libadwaita's palette, light and dark.
public struct Palette: Sendable {

    public var scheme: ColorScheme

    public var accent: Color

    public init(scheme: ColorScheme, accent: Color = Color(hex: 0x3584E4)) {
        self.scheme = scheme
        self.accent = accent
    }

    var dark: Bool { scheme == .dark }

    /// Window background.
    public var background: Color { dark ? Color(hex: 0x222226) : Color(hex: 0xFAFAFB) }

    /// Grouped lists and forms behind their cards.
    public var groupedBackground: Color { dark ? Color(hex: 0x1D1D20) : Color(hex: 0xEBEBED) }

    /// Cards, rows, dialogs.
    public var card: Color { dark ? Color(hex: 0x36363A) : Color(hex: 0xFFFFFF) }

    /// The navigation and tab bars.
    public var bar: Color { dark ? Color(hex: 0x2E2E32) : Color(hex: 0xEBEBED) }

    public var primary: Color { dark ? Color(hex: 0xFFFFFF) : Color(hex: 0x000000, alpha: 0.8) }

    public var secondary: Color { primary.opacity(0.55) }

    public var separator: Color { dark ? Color(hex: 0xFFFFFF, alpha: 0.12) : Color(hex: 0x000000, alpha: 0.12) }

    /// Buttons and fields at rest.
    public var control: Color { dark ? Color(hex: 0xFFFFFF, alpha: 0.10) : Color(hex: 0x000000, alpha: 0.07) }

    /// Buttons while pressed.
    public var controlPressed: Color { dark ? Color(hex: 0xFFFFFF, alpha: 0.22) : Color(hex: 0x000000, alpha: 0.18) }

    /// Rows under the pointer while pressed, popup menu highlight.
    public var highlight: Color { accent.opacity(dark ? 0.35 : 0.18) }

    public var destructive: Color { dark ? Color(hex: 0xFF7B63) : Color(hex: 0xE01B24) }

    /// Dims the window behind a sheet or alert.
    public var scrim: Color { Color.black.opacity(dark ? 0.5 : 0.3) }

    /// A named color: `red`, `accentColor`, …; `nil` for names it doesn't
    /// know.
    public func named(_ name: String) -> Color? {
        switch name {
        case "primary": return primary
        case "secondary": return secondary
        case "accentColor": return accent
        case "clear": return .clear
        case "black": return .black
        case "white": return .white
        case "gray": return Color(hex: dark ? 0x9A9996 : 0x77767B)
        case "red": return Color(hex: dark ? 0xF66151 : 0xE01B24)
        case "orange": return Color(hex: dark ? 0xFFA348 : 0xFF7800)
        case "yellow": return Color(hex: dark ? 0xF8E45C : 0xF5C211)
        case "green": return Color(hex: dark ? 0x57E389 : 0x2EC27E)
        case "mint": return Color(hex: dark ? 0x8FF0A4 : 0x00C7BE)
        case "teal": return Color(hex: dark ? 0x93DDC2 : 0x30B0C7)
        case "cyan": return Color(hex: dark ? 0x99C1F1 : 0x32ADE6)
        case "blue": return Color(hex: dark ? 0x62A0EA : 0x3584E4)
        case "indigo": return Color(hex: dark ? 0x8C8CFF : 0x5856D6)
        case "purple": return Color(hex: dark ? 0xC061CB : 0x9141AC)
        case "pink": return Color(hex: dark ? 0xFF7FBF : 0xFF2D55)
        case "brown": return Color(hex: dark ? 0xCDAB8F : 0x986A44)
        default: return nil
        }
    }

    /// A color prop or argument: a name, `[name, opacity]`, or a fixed
    /// `0xAARRGGBB` int.
    public func color(_ value: PropValue?) -> Color? {
        switch value {
        case .string(let name)?:
            return named(name)
        case .array(let parts)?:
            guard let base = color(parts.first) else { return nil }
            return base.opacity(parts.count > 1 ? parts[1].double ?? 1 : 1)
        case .int(let argb)?:
            let value = UInt32(truncatingIfNeeded: argb)
            return Color(hex: value & 0xFF_FFFF, alpha: Double(value >> 24) / 255)
        default:
            return nil
        }
    }
}

/// A font: what the text engine opens.
public struct FontSpec: Equatable, Hashable, Sendable {

    public enum Design: String, Sendable {
        case `default`, serif, monospaced, rounded
    }

    /// Points.
    public var size: Double

    /// 100 (ultra light) to 900 (black).
    public var weight: Int

    public var design: Design

    public var italic: Bool

    public init(size: Double, weight: Int = 400, design: Design = .default, italic: Bool = false) {
        self.size = size
        self.weight = weight
        self.design = design
        self.italic = italic
    }

    public static let body = FontSpec(size: TextStyles.size("body"))

    /// SwiftUI's text styles in points, scaled for a desktop: `body` is 15.
    public enum TextStyles {

        public static func size(_ style: String) -> Double {
            switch style {
            case "largeTitle": 30
            case "title": 25
            case "title2": 20
            case "title3": 18
            case "headline": 15
            case "subheadline": 13.5
            case "callout": 14.5
            case "footnote": 12.5
            case "caption": 12
            case "caption2": 11
            default: 15
            }
        }

        /// `headline` is semibold; titles stay regular, as on iOS.
        public static func weight(_ style: String) -> Int {
            style == "headline" ? 600 : 400
        }
    }

    /// `ultraLight` … `black`.
    public static func weight(named name: String?) -> Int? {
        switch name {
        case "ultraLight": 100
        case "thin": 200
        case "light": 300
        case "regular": 400
        case "medium": 500
        case "semibold": 600
        case "bold": 700
        case "heavy": 800
        case "black": 900
        default: nil
        }
    }
}

/// Fixed sizes of the player's controls, in points.
enum Metrics {
    static let stackSpacing = 8.0
    static let controlHeight = 34.0
    static let controlRadius = 8.0
    static let buttonPadding = EdgeInsets(top: 7, leading: 14, bottom: 7, trailing: 14)
    static let rowInsets = EdgeInsets(top: 11, leading: 16, bottom: 11, trailing: 16)
    static let rowMinHeight = 44.0
    static let sectionSpacing = 22.0
    static let listInset = 16.0
    static let cardRadius = 12.0
    static let switchSize = Size(width: 44, height: 26)
    static let sliderHeight = 24.0
    static let knob = 20.0
    static let navBarHeight = 48.0
    static let tabBarHeight = 54.0
    static let searchFieldHeight = 34.0
    static let menuRowHeight = 32.0
    static let menuWidth = 220.0
    static let sheetMaxWidth = 560.0
    static let alertWidth = 340.0
    static let indicatorWidth = 6.0
    static let spacerMinLength = 8.0
}
