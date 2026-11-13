import DynamicUI

/// A node placed on screen, with what to draw and how it takes input: the
/// result of a layout pass, which drawing and hit testing walk.
public final class LayoutBox {

    /// What a box draws, in window points.
    public enum Op {
        case fill(Rect, Color, radius: Double)
        case stroke(Rect, Color, width: Double, radius: Double)
        case line(Point, Point, Color, width: Double)
        case circle(Point, radius: Double, Color)
        case text(String, FontSpec, Color, Rect, HorizontalAlignment, wrap: Bool)
        /// Clips the ops that follow, until `unclip`.
        case clip(Rect)
        case unclip
    }

    /// A modifier's effect, at the rectangle it applies to.
    enum Decoration {
        case background(Color, Rect)
        case border(Color, width: Double, Rect)
        case shadow(Color, radius: Double, Rect)
        case opacity(Double)
        case cornerRadius(Double, Rect)
    }

    public let id: RenderNode.ID

    public let type: String

    /// The node's outer frame, all modifiers included.
    public internal(set) var frame: Rect

    /// The node's own content, inside its modifiers.
    public internal(set) var contentFrame: Rect

    public internal(set) var children: [LayoutBox] = []

    /// Drawn before the children.
    public internal(set) var ops: [Op] = []

    /// Drawn after the children.
    public internal(set) var overlayOps: [Op] = []

    /// Outermost first.
    var decorations: [Decoration] = []

    /// Clips the children: scroll views, lists.
    var clip: Rect?

    /// How the box takes input, if it does.
    var role: Role?

    /// Where `role` applies; the frame if `nil`.
    var hitRect: Rect?

    /// Takes no input, nor do its children.
    var disabled = false

    /// A row's swipe actions, shown as its context menu.
    var contextMenu: [PopupItem]?

    init(id: RenderNode.ID, type: String, frame: Rect) {
        self.id = id
        self.type = type
        self.frame = frame
        self.contentFrame = frame
    }

    /// Depth first, the first box of `type` (and drawing `text`, if given).
    public func find(_ type: String, text: String? = nil) -> LayoutBox? {
        if self.type == type, text == nil || draws(text!) {
            return self
        }
        for child in children {
            if let found = child.find(type, text: text) { return found }
        }
        return nil
    }

    /// The box with `id`.
    public func box(_ id: RenderNode.ID) -> LayoutBox? {
        if self.id == id { return self }
        for child in children {
            if let found = child.box(id) { return found }
        }
        return nil
    }

    /// Whether this box or a descendant draws `text`.
    public func draws(_ text: String) -> Bool {
        for op in ops + overlayOps {
            if case .text(let string, _, _, _, _, _) = op, string == text {
                return true
            }
        }
        return children.contains { $0.draws(text) }
    }

    /// Every string drawn, in drawing order.
    public var texts: [String] {
        func strings(_ ops: [Op]) -> [String] {
            ops.compactMap { if case .text(let string, _, _, _, _, _) = $0 { string } else { nil } }
        }
        return strings(ops) + children.flatMap(\.texts) + strings(overlayOps)
    }
}

/// How a box takes input.
enum Role {
    /// `Button`, `NavigationLink`, `onTapGesture`: `tap` on release inside.
    case tap(RenderNode.ID)
    /// `Link`: opens the URL.
    case link(String)
    case toggle(RenderNode.ID, isOn: Bool)
    case textField(RenderNode.ID)
    case slider(RenderNode.ID, value: Double, min: Double, max: Double, step: Double?, track: Rect)
    case stepper(RenderNode.ID, value: Int, min: Int, max: Int, step: Int)
    /// A picker's segment or inline row, or a tab: `change` with the index.
    case select(RenderNode.ID, index: Int)
    case disclosure(RenderNode.ID, isExpanded: Bool)
    /// A navigation back button: `pop` with the levels left.
    case back(RenderNode.ID, levels: Int)
    /// Opens a popup menu.
    case menu([PopupItem])
    /// A row of an open popup menu.
    case popupItem(PopupItem)
    /// A row with swipe actions: they're in its context menu.
    case contextMenu([PopupItem])
    /// A scroll view or list's viewport.
    case scroll(RenderNode.ID, content: Size, viewport: Rect)
    /// A presentation's backdrop: dismisses a sheet when clicked.
    case backdrop(RenderNode.ID?)
    /// An alert's button: its `tap`, if it has one, then `change(false)` to
    /// the alert.
    case alertButton(RenderNode.ID?, alert: RenderNode.ID)
    /// Takes clicks so nothing beneath does.
    case blocker
}

/// A row of a popup menu: a `Menu`'s items, a picker's options, a row's
/// swipe actions.
struct PopupItem {

    enum Action {
        case tap(RenderNode.ID)
        case select(RenderNode.ID, index: Int)
        case none
    }

    var title: String

    var glyph: String?

    var checked = false

    var destructive = false

    var enabled = true

    var separator = false

    /// A section's header: drawn, not chosen.
    var header = false

    var indent = 0

    var action: Action = .none

    static let divider = PopupItem(title: "", separator: true)
}
