import DynamicUI
import Foundation

/// What a window shows: a laid-out tree and its overlays.
public struct RenderFrame {

    public var root: LayoutBox?

    /// Sheets, alerts and the popup menu, bottom to top.
    public var overlays: [LayoutBox]

    public var bounds: Rect

    public var palette: Palette

    /// Every string drawn, in drawing order.
    public var texts: [String] {
        (root?.texts ?? []) + overlays.flatMap(\.texts)
    }

    /// Where `text` is drawn, topmost first: overlays, then the tree.
    public func rect(ofText text: String) -> Rect? {
        func search(_ box: LayoutBox) -> Rect? {
            for child in box.children.reversed() {
                if let rect = search(child) { return rect }
            }
            for op in (box.ops + box.overlayOps).reversed() {
                if case .text(let string, _, _, let rect, _, _) = op, string == text {
                    return rect
                }
            }
            return nil
        }
        for overlay in overlays.reversed() {
            if let rect = search(overlay) { return rect }
        }
        return root.flatMap(search)
    }

    /// Depth first, the first box of `type`, overlays first.
    public func find(_ type: String, text: String? = nil) -> LayoutBox? {
        for overlay in overlays.reversed() {
            if let box = overlay.find(type, text: text) { return box }
        }
        return root?.find(type, text: text)
    }
}

/// The player's model (`Plan.md` §5.1): the tree the guest sent, the view
/// state that outlives updates, and the events going back.
///
/// Main loop only. The guest answers an event with its update before the
/// event call returns, so after `send` the tree is already current.
public final class RenderStore {

    /// The tree the guest sent.
    public private(set) var root: RenderNode?

    /// Where events and row requests go.
    public var delegate: (any RendererDelegate)?

    public let textEngine: TextEngine

    public var palette: Palette {
        didSet { setNeedsDisplay() }
    }

    /// Called when the window should draw again.
    public var onNeedsDisplay: (() -> Void)?

    /// Called when a text field gains (`true`, with the caret's rectangle)
    /// or loses focus, to start or stop the platform's text input.
    public var onTextInput: ((Bool, Rect?) -> Void)?

    /// Opens a `Link`'s URL. `xdg-open` by default.
    public var openURL: (String) -> Void = RenderStore.xdgOpen

    /// The clipboard, for a text field's copy, cut and paste.
    public var clipboard: (get: () -> String?, set: (String) -> Void)?

    /// The last layout.
    public private(set) var frame: RenderFrame?

    public private(set) var needsLayout = true

    // MARK: View state

    struct Editor {
        var text: String
        /// In characters.
        var cursor: Int
        /// The text the IR had when this was last synced.
        var lastIR: String
    }

    var editors: [RenderNode.ID: Editor] = [:]

    public internal(set) var focused: RenderNode.ID?

    var caretVisible = true

    /// The text fields drawn in the last layout, in order: where their text
    /// starts and how far it's scrolled.
    var textFieldFrames: [RenderNode.ID: (rect: Rect, shift: Double)] = [:]

    var textFieldOrder: [RenderNode.ID] = []

    var scrollOffsets: [RenderNode.ID: Point] = [:]

    /// A slider's value while it's dragged.
    var sliderValues: [RenderNode.ID: Double] = [:]

    /// The box being pressed: its node and type, which tell a stepper's
    /// halves apart.
    var pressed: (id: RenderNode.ID, type: String)?

    /// Whether the pointer is still over the pressed box.
    var pressInside = false

    var pressedRole: Role?

    /// Where the pointer last was: what the arrow keys scroll.
    var pointerLocation: Point?

    /// How far past the top the user has pulled a refreshable list.
    var overscroll: Double = 0

    var pressedFrame: Rect?

    /// The frame of the box last released, where its menu opens.
    var lastPressedFrame: Rect?

    /// The slider being dragged, and the value it showed when the drag began.
    var dragging: (id: RenderNode.ID, start: Double, min: Double, max: Double, step: Double?, track: Rect)?

    var popup: Popup?

    /// The open `DatePicker` popover.
    var datePopover: DatePopover?

    /// The calendar dates show in: the local time zone and locale by default.
    public var calendar: Calendar = {
        var calendar = Calendar.current
        calendar.timeZone = TimeZone.current
        calendar.locale = Locale.current
        return calendar
    }() {
        didSet { setNeedsDisplay() }
    }

    private var rows: [RenderNode.ID: (revision: PropValue?, rows: [Int: RenderNode])] = [:]

    public init(textEngine: TextEngine, palette: Palette = Palette(scheme: .light)) {
        self.textEngine = textEngine
        self.palette = palette
    }

    // MARK: Updates

    /// `Renderer.apply`: replaces everything.
    public func apply(_ tree: RenderNode) {
        root = tree
        setNeedsDisplay()
    }

    /// `Renderer.replaceSubtree`: replaces the node `id` and its subtree,
    /// in the tree or in a lazy container's fetched rows.
    public func replace(_ id: RenderNode.ID, with subtree: RenderNode) {
        if root?.replace(id, with: subtree) == true {
            setNeedsDisplay()
            return
        }
        for (list, cache) in rows {
            for (index, row) in cache.rows {
                var row = row
                if row.replace(id, with: subtree) {
                    rows[list]?.rows[index] = row
                    setNeedsDisplay()
                    return
                }
            }
        }
    }

    public func setNeedsDisplay() {
        needsLayout = true
        onNeedsDisplay?()
    }

    // MARK: Layout

    /// Lays out the tree for a window of `size` points.
    @discardableResult
    public func layout(size: Size) -> RenderFrame {
        let window = Rect(origin: .zero, size: size)
        textFieldFrames = [:]
        let layout = Layout(store: self, window: window)
        let environment = ViewEnvironment(palette: palette)
        var rootBox: LayoutBox?
        if let root {
            let measured = layout.size(root, ProposedSize(size), environment)
            let rect = window.place(layout.clamp(measured, to: size), .center)
            rootBox = layout.place(root, in: rect, environment)
        }
        var overlays: [LayoutBox] = []
        var index = 0
        while index < layout.presentations.count {
            let (node, environment) = layout.presentations[index]
            overlays.append(layout.placePresentation(node, environment, window: window))
            index += 1
        }
        if let popup {
            overlays.append(layout.placePopup(popup, environment, window: window))
        }
        if let datePopover {
            if let node = node(datePopover.id) {
                overlays.append(layout.placeDatePopover(datePopover, node, environment, window: window))
            } else {
                // The picker went away.
                self.datePopover = nil
            }
        }
        let frame = RenderFrame(root: rootBox, overlays: overlays, bounds: window, palette: palette)
        textFieldOrder = Self.textFields(in: frame)
        if let focused, textFieldFrames[focused] == nil {
            // The focused field went away.
            self.focused = nil
            onTextInput?(false, nil)
        }
        self.frame = frame
        needsLayout = false
        return frame
    }

    private static func textFields(in frame: RenderFrame) -> [RenderNode.ID] {
        var fields: [RenderNode.ID] = []
        func walk(_ box: LayoutBox) {
            if case .textField(let id)? = box.role {
                fields.append(id)
            }
            box.children.forEach(walk)
        }
        frame.root.map(walk)
        frame.overlays.forEach(walk)
        return fields
    }

    // MARK: State for layout

    func isPressed(_ id: RenderNode.ID, _ type: String? = nil) -> Bool {
        guard let pressed, pressInside, pressed.id == id else { return false }
        return type == nil || pressed.type == type
    }

    /// Always: indicators show whenever content overflows, thin and quiet.
    func isScrolling(_ id: RenderNode.ID) -> Bool {
        true
    }

    /// The scroll offset for a viewport, kept within the content.
    func scrollOffset(_ id: RenderNode.ID, content: Size, viewport: Size) -> Point {
        let stored = scrollOffsets[id] ?? .zero
        let clamped = Point(
            x: min(max(stored.x, 0), max(content.width - viewport.width, 0)),
            y: min(max(stored.y, 0), max(content.height - viewport.height, 0))
        )
        if clamped != stored {
            scrollOffsets[id] = clamped
        }
        return clamped
    }

    /// A text field's editor, synced with the IR: the guest's text replaces
    /// what's typed only when it changed since the last sync.
    func editor(_ id: RenderNode.ID, ir: String) -> Editor {
        if var editor = editors[id] {
            if editor.lastIR != ir {
                editor.text = ir
                editor.lastIR = ir
                editor.cursor = min(editor.cursor, ir.count)
                editors[id] = editor
            }
            return editor
        }
        let editor = Editor(text: ir, cursor: ir.count, lastIR: ir)
        editors[id] = editor
        return editor
    }

    /// A slider's value: the dragged one while it's dragged.
    func sliderValue(_ id: RenderNode.ID, ir: Double) -> Double {
        sliderValues[id] ?? ir
    }

    /// The node `id`, in the tree or a lazy container's fetched rows.
    func node(_ id: RenderNode.ID) -> RenderNode? {
        if let node = root?.node(id) {
            return node
        }
        for cache in rows.values {
            for row in cache.rows.values {
                if let node = row.node(id) { return node }
            }
        }
        return nil
    }

    // MARK: Lazy rows

    func rowCount(_ node: RenderNode) -> Int {
        max(node.count ?? 0, 0)
    }

    /// A lazy container's row, fetched once per revision.
    func row(_ node: RenderNode, index: Int) -> RenderNode? {
        guard index >= 0, index < rowCount(node) else { return nil }
        let revision = node.props["revision"]
        if rows[node.id]?.revision != revision {
            rows[node.id] = (revision, [:])
        }
        if let row = rows[node.id]?.rows[index] {
            return row
        }
        guard let delegate else { return nil }
        let bytes = delegate.row(RenderCodec.encode(id: node.id), index: Int32(index))
        guard !bytes.isEmpty, let row = try? RenderCodec.decode(bytes) else { return nil }
        rows[node.id]?.rows[index] = row
        return row
    }

    // MARK: Events

    /// Sends an event to the guest, which updates the tree before this
    /// returns.
    func send(_ id: RenderNode.ID, _ kind: RenderEventKind, _ payload: PropValue? = nil) {
        send(id, kind: kind.rawValue, payload)
    }

    /// `refresh` (5), which only newer `DynamicUI`s name.
    static let refreshEvent: Int32 = 5

    func send(_ id: RenderNode.ID, kind: Int32, _ payload: PropValue? = nil) {
        guard let delegate else { return }
        delegate.event(
            RenderCodec.encode(id: id),
            kind: kind,
            payload: payload.map { RenderCodec.encode(payload: $0) } ?? []
        )
        setNeedsDisplay()
    }

    static func xdgOpen(_ url: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["xdg-open", url]
        do {
            try process.run()
        } catch {
            FileHandle.standardError.write(Data("linux-app-host: can't open \(url): \(error)\n".utf8))
        }
    }
}
