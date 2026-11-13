import DynamicUI

/// What a node inherits from its ancestors: the IR's inherited modifiers
/// (`RenderIR.md` §Modifiers), and what the player tracks itself.
public struct ViewEnvironment {

    public var palette: Palette

    public var font: FontSpec = .body

    /// `nil`: the palette's primary color.
    public var foreground: Color?

    /// `tint`, or the accent color.
    public var tint: Color?

    public var disabled = false

    public var lineLimit: Int?

    public var textAlignment: HorizontalAlignment = .leading

    /// The axis of the stack a `Spacer` or `Divider` is in.
    var stackAxis: Axis = .vertical

    /// Inside a list row: buttons draw as rows, not as filled buttons.
    var inListRow = false

    /// Inside a popup menu or toolbar: buttons draw plainly.
    var plainButtons = false

    public init(palette: Palette) {
        self.palette = palette
    }

    public var foregroundColor: Color {
        foreground ?? palette.primary
    }

    public var tintColor: Color {
        tint ?? palette.accent
    }

    /// Applies a node's inherited modifiers. The innermost wins, as in
    /// SwiftUI: `.font(.title).font(.body)` is `title`.
    func applying(_ modifiers: [ModifierNode]) -> ViewEnvironment {
        var environment = self
        for modifier in modifiers.reversed() {
            environment.apply(modifier)
        }
        return environment
    }

    private mutating func apply(_ modifier: ModifierNode) {
        let args = modifier.args
        switch modifier.kind {
        case "font":
            if let style = args["style"]?.string {
                font = FontSpec(
                    size: FontSpec.TextStyles.size(style),
                    weight: FontSpec.TextStyles.weight(style),
                    design: font.design,
                    italic: font.italic
                )
            } else if let size = args["size"]?.double {
                font.size = size
            }
            if let weight = FontSpec.weight(named: args["weight"]?.string) {
                font.weight = weight
            }
            if let design = args["design"]?.string.flatMap(FontSpec.Design.init(rawValue:)) {
                font.design = design
            }
            if args["italic"]?.bool == true {
                font.italic = true
            }
        case "fontWeight":
            if let weight = FontSpec.weight(named: args["weight"]?.string) {
                font.weight = weight
            }
        case "italic":
            font.italic = args["value"]?.bool ?? true
        case "foregroundColor":
            foreground = palette.color(args["color"])
        case "tint":
            tint = palette.color(args["color"]) ?? tint
        case "disabled":
            if args["value"]?.bool ?? true {
                disabled = true
            }
        case "lineLimit":
            lineLimit = args["lines"]?.int
        case "multilineTextAlignment":
            textAlignment = HorizontalAlignment(args["alignment"]?.string)
        default:
            break
        }
    }
}
