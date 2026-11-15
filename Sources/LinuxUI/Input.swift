import DynamicUI

/// Input, in window points, as the window translates it from SDL.
public enum InputEvent: Equatable {
    case pointerDown(Point, button: PointerButton)
    case pointerMove(Point)
    case pointerUp(Point, button: PointerButton)
    /// Wheel or touchpad: points to scroll by, positive down and right.
    case scroll(Point, dx: Double, dy: Double)
    case key(Key, KeyModifiers)
    /// Text typed or committed by an input method.
    case text(String)
}

public enum PointerButton: Equatable, Sendable {
    case primary
    case secondary
}

public enum Key: Equatable, Sendable {
    case backspace, delete, left, right, up, down, home, end, enter, escape, tab, pageUp, pageDown
    /// A letter with a modifier, for shortcuts: `a`, `c`, `v`, `x`.
    case character(Character)
}

public struct KeyModifiers: OptionSet, Sendable {

    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let shift = KeyModifiers(rawValue: 1)
    public static let control = KeyModifiers(rawValue: 2)
    public static let alt = KeyModifiers(rawValue: 4)
}

/// Input handling (`Plan.md` §5.4): hit testing the last layout, pressing
/// and releasing, dragging sliders, text editing, scrolling, menus and
/// keyboard shortcuts.
extension RenderStore {

    /// Handles one input event against the current layout. Lays out first if
    /// the tree changed; `size` is the window's.
    public func handle(_ event: InputEvent, size: Size) {
        if needsLayout || frame == nil {
            layout(size: size)
        }
        switch event {
        case .pointerDown(let point, let button):
            pointerLocation = point
            pointerDown(point, button: button)
        case .pointerMove(let point):
            pointerLocation = point
            pointerMove(point)
        case .pointerUp(let point, let button):
            pointerUp(point, button: button)
        case .scroll(let point, let dx, let dy):
            scroll(at: point, dx: dx, dy: dy)
        case .key(let key, let modifiers):
            keyDown(key, modifiers)
        case .text(let text):
            insert(text)
        }
    }

    // MARK: Hit testing

    /// The box that takes input at `point`: overlays first, deepest first.
    func hitTest(_ point: Point) -> LayoutBox? {
        guard let frame else { return nil }
        for overlay in frame.overlays.reversed() {
            if let box = hit(overlay, point, clip: frame.bounds) {
                return box
            }
        }
        return frame.root.flatMap { hit($0, point, clip: frame.bounds) }
    }

    private func hit(_ box: LayoutBox, _ point: Point, clip: Rect) -> LayoutBox? {
        guard !box.disabled else { return nil }
        let inner = box.clip.map { clip.intersection($0) } ?? clip
        if inner.contains(point) {
            for child in box.children.reversed() {
                if let found = hit(child, point, clip: inner) {
                    return found
                }
            }
        }
        if box.role != nil, (box.hitRect ?? box.frame).contains(point), clip.contains(point) {
            return box
        }
        return nil
    }

    /// The boxes under `point`, outermost first.
    private func path(to point: Point) -> [LayoutBox] {
        guard let frame else { return [] }
        func walk(_ box: LayoutBox, clip: Rect) -> [LayoutBox]? {
            guard clip.contains(point) else { return nil }
            let inner = box.clip.map { clip.intersection($0) } ?? clip
            for child in box.children.reversed() {
                if let path = walk(child, clip: inner) {
                    return [box] + path
                }
            }
            return box.frame.contains(point) ? [box] : nil
        }
        for overlay in frame.overlays.reversed() {
            if let path = walk(overlay, clip: frame.bounds) {
                return path
            }
        }
        return frame.root.flatMap { walk($0, clip: frame.bounds) } ?? []
    }

    // MARK: Pointer

    private func pointerDown(_ point: Point, button: PointerButton) {
        let target = hitTest(point)
        if button == .secondary {
            // Context menus and swipe actions under the pointer, innermost
            // first.
            let menus = path(to: point).reversed().compactMap(\.contextMenu).filter { !$0.isEmpty }
            if !menus.isEmpty {
                let items = menus.dropFirst().reduce(menus[0]) { $0 + [.divider] + $1 }
                popup = Popup(anchor: Rect(origin: point, size: .zero), items: items)
                setNeedsDisplay()
            }
            return
        }
        guard let target, let role = target.role else {
            blur()
            return
        }
        switch role {
        case .textField(let id):
            focus(id)
            placeCaret(id, at: point)
            return
        case .slider(let id, let value, let minimum, let maximum, let step, let track):
            blur()
            dragging = (id, value, minimum, maximum, step, track)
            drag(to: point)
            return
        case .scroll, .blocker:
            blur()
            return
        default:
            break
        }
        blur()
        pressed = (target.id, target.type)
        pressInside = true
        pressedRole = role
        pressedFrame = target.hitRect ?? target.frame
        setNeedsDisplay()
    }

    private func pointerMove(_ point: Point) {
        if dragging != nil {
            drag(to: point)
            return
        }
        if pressed != nil, let pressedFrame {
            let inside = pressedFrame.contains(point)
            if inside != pressInside {
                pressInside = inside
                setNeedsDisplay()
            }
            return
        }
        if var popup {
            var highlighted: Int?
            if let box = hitTest(point), case .popupItem? = box.role {
                highlighted = Int(box.id)
            }
            if highlighted != popup.highlighted {
                popup.highlighted = highlighted
                self.popup = popup
                setNeedsDisplay()
            }
        }
    }

    private func pointerUp(_ point: Point, button: PointerButton) {
        if let dragging {
            drag(to: point)
            self.dragging = nil
            sliderValues[dragging.id] = nil
            setNeedsDisplay()
            return
        }
        guard let role = pressedRole else { return }
        let inside = pressedFrame?.contains(point) ?? false
        lastPressedFrame = pressedFrame
        pressed = nil
        pressedRole = nil
        pressedFrame = nil
        pressInside = false
        setNeedsDisplay()
        if inside {
            activate(role)
        }
    }

    /// What a release inside a box does.
    func activate(_ role: Role) {
        switch role {
        case .tap(let id):
            send(id, .tap)
        case .link(let url):
            openURL(url)
        case .toggle(let id, let isOn):
            send(id, .change, .bool(!isOn))
        case .select(let id, let index):
            send(id, .change, .int(index))
        case .disclosure(let id, let isExpanded):
            send(id, .change, .bool(!isExpanded))
        case .back(let id, let levels):
            send(id, .pop, .int(levels))
        case .stepper(let id, let value, _, _, _):
            send(id, .change, .int(value))
        case .menu(let items):
            popup = Popup(anchor: lastPressedFrame ?? .zero, items: items)
            setNeedsDisplay()
        case .popupItem(let item):
            popup = nil
            setNeedsDisplay()
            switch item.action {
            case .tap(let id): send(id, .tap)
            case .select(let id, let index): send(id, .change, .int(index))
            case .none: break
            }
        case .alertButton(let button, let alert):
            if let button {
                send(button, .tap)
            }
            send(alert, .change, .bool(false))
        case .backdrop(let id):
            if let id {
                send(id, .change, .bool(false))
            } else {
                popup = nil
                setNeedsDisplay()
            }
        case .textField, .slider, .scroll, .contextMenu, .blocker:
            break
        }
    }

    // MARK: Sliders

    private func drag(to point: Point) {
        guard let dragging else { return }
        let track = dragging.track
        let fraction = track.width > 0 ? min(max((point.x - track.minX) / track.width, 0), 1) : 0
        var value = dragging.min + (dragging.max - dragging.min) * fraction
        if let step = dragging.step, step > 0 {
            value = dragging.min + ((value - dragging.min) / step).rounded() * step
            value = min(max(value, dragging.min), dragging.max)
        }
        guard value != (sliderValues[dragging.id] ?? dragging.start) else { return }
        sliderValues[dragging.id] = value
        send(dragging.id, .change, .double(value))
    }

    // MARK: Scrolling

    /// How far past the top a pull goes before it refreshes.
    static let pullDistance = 70.0

    private func scroll(at point: Point, dx: Double, dy: Double) {
        let path = path(to: point)
        for (depth, box) in path.enumerated().reversed() {
            guard case .scroll(let id, let content, let viewport)? = box.role else { continue }
            let maxX = max(content.width - viewport.width, 0), maxY = max(content.height - viewport.height, 0)
            let current = scrollOffsets[id] ?? .zero
            let next = Point(x: min(max(current.x + dx, 0), maxX), y: min(max(current.y + dy, 0), maxY))
            if next != current {
                overscroll = 0
                scrollOffsets[id] = next
                setNeedsDisplay()
                return
            }
            // At the top and pulled further: refresh, if a Refreshable holds
            // this list.
            if dy < 0, current.y == 0,
               let refreshable = path[..<depth].last(where: { $0.type == "Refreshable" }) {
                overscroll -= dy
                if overscroll >= Self.pullDistance {
                    overscroll = 0
                    refresh(refreshable.id)
                }
                return
            }
        }
    }

    /// Asks a `Refreshable` to refresh, unless it already is.
    func refresh(_ id: RenderNode.ID) {
        guard root?.node(id)?.props["refreshing"]?.bool != true else { return }
        send(id, kind: Self.refreshEvent)
    }

    // MARK: Text fields

    func focus(_ id: RenderNode.ID) {
        guard focused != id else { return }
        focused = id
        setNeedsDisplay()
        onTextInput?(true, textFieldFrames[id]?.rect)
    }

    func blur() {
        guard focused != nil else { return }
        focused = nil
        setNeedsDisplay()
        onTextInput?(false, nil)
    }

    private func placeCaret(_ id: RenderNode.ID, at point: Point) {
        guard var editor = editors[id], let field = textFieldFrames[id] else { return }
        let font = fontForField(id)
        let x = point.x - field.rect.minX + field.shift
        var best = editor.text.count
        var previous = 0.0
        for index in 0...editor.text.count {
            let width = textEngine.width(String(editor.text.prefix(index)), font: font)
            if width >= x {
                best = (width - x) < (x - previous) ? index : max(index - 1, 0)
                break
            }
            previous = width
        }
        editor.cursor = best
        editors[id] = editor
        setNeedsDisplay()
    }

    private func fontForField(_ id: RenderNode.ID) -> FontSpec {
        if let box = frame?.root?.box(id) ?? frame?.overlays.lazy.compactMap({ $0.box(id) }).first {
            for op in box.ops {
                if case .text(_, let font, _, _, _, _) = op { return font }
            }
        }
        return .body
    }

    /// Replaces the focused field's text and tells the guest.
    private func edit(_ change: (inout Editor) -> Void) {
        guard let id = focused, var editor = editors[id] else { return }
        let before = editor.text
        change(&editor)
        editor.cursor = min(max(editor.cursor, 0), editor.text.count)
        editors[id] = editor
        setNeedsDisplay()
        if editor.text != before {
            send(id, .change, .string(editor.text))
        }
    }

    private func insert(_ text: String) {
        guard focused != nil else { return }
        // A single-line field: line breaks become spaces.
        let text = text.replacingOccurrences(of: "\n", with: " ")
        edit { editor in
            let index = editor.text.index(editor.text.startIndex, offsetBy: editor.cursor)
            editor.text.insert(contentsOf: text, at: index)
            editor.cursor += text.count
        }
    }

    private func keyDown(_ key: Key, _ modifiers: KeyModifiers) {
        if popup != nil, handlePopupKey(key) {
            return
        }
        if let id = focused, handleFieldKey(key, modifiers, id) {
            return
        }
        switch key {
        case .escape:
            dismissTopmost()
        case .left where modifiers.contains(.alt):
            goBack()
        case .tab:
            moveFocus(backwards: modifiers.contains(.shift))
        case .up, .down, .pageUp, .pageDown:
            // A gamepad's D-pad: scroll what's under the pointer.
            let point = pointerLocation ?? frame.map { Point(x: $0.bounds.midX, y: $0.bounds.midY) } ?? .zero
            let page = max((frame?.bounds.height ?? 400) - 80, 40)
            let distance: Double = switch key {
            case .up: -40
            case .down: 40
            case .pageUp: -page
            default: page
            }
            scroll(at: point, dx: 0, dy: distance)
        default:
            break
        }
    }

    private func handleFieldKey(_ key: Key, _ modifiers: KeyModifiers, _ id: RenderNode.ID) -> Bool {
        switch key {
        case .backspace:
            edit { editor in
                guard editor.cursor > 0 else { return }
                let index = editor.text.index(editor.text.startIndex, offsetBy: editor.cursor - 1)
                editor.text.remove(at: index)
                editor.cursor -= 1
            }
        case .delete:
            edit { editor in
                guard editor.cursor < editor.text.count else { return }
                editor.text.remove(at: editor.text.index(editor.text.startIndex, offsetBy: editor.cursor))
            }
        case .left:
            edit { $0.cursor -= 1 }
        case .right:
            edit { $0.cursor += 1 }
        case .home:
            edit { $0.cursor = 0 }
        case .end:
            edit { $0.cursor = $0.text.count }
        case .enter:
            send(id, .submit)
        case .escape:
            blur()
        case .character(let character) where modifiers.contains(.control):
            switch character {
            case "a":
                edit { $0.cursor = $0.text.count }
            case "c":
                if let text = editors[id]?.text { clipboard?.set(text) }
            case "x":
                if let text = editors[id]?.text { clipboard?.set(text) }
                edit { $0.text = ""; $0.cursor = 0 }
            case "v":
                if let text = clipboard?.get() { insert(text) }
            default:
                return false
            }
        default:
            return false
        }
        return true
    }

    private func handlePopupKey(_ key: Key) -> Bool {
        guard var popup else { return false }
        let choosable = popup.items.indices.filter { !popup.items[$0].separator && !popup.items[$0].header && popup.items[$0].enabled }
        switch key {
        case .escape:
            self.popup = nil
        case .down, .up:
            guard !choosable.isEmpty else { return true }
            let current = popup.highlighted.flatMap { choosable.firstIndex(of: $0) }
            let next = key == .down ? (current.map { min($0 + 1, choosable.count - 1) } ?? 0)
                                    : (current.map { max($0 - 1, 0) } ?? choosable.count - 1)
            popup.highlighted = choosable[next]
            self.popup = popup
        case .enter:
            if let index = popup.highlighted {
                activate(.popupItem(popup.items[index]))
            }
            return true
        default:
            return false
        }
        setNeedsDisplay()
        return true
    }

    /// Escape: the popup, else the topmost sheet or alert.
    private func dismissTopmost() {
        if popup != nil {
            popup = nil
            setNeedsDisplay()
            return
        }
        guard let overlay = frame?.overlays.last(where: { $0.type == "SheetOverlay" || $0.type == "AlertOverlay" }) else { return }
        send(overlay.id, .change, .bool(false))
    }

    /// Alt+Left: the visible navigation stack's back button.
    private func goBack() {
        guard let frame else { return }
        let back = frame.overlays.reversed().lazy.compactMap { $0.find("NavBar.back") }.first ?? frame.root?.find("NavBar.back")
        if let role = back?.role {
            activate(role)
        }
    }

    private func moveFocus(backwards: Bool) {
        guard !textFieldOrder.isEmpty else { return }
        let current = focused.flatMap { textFieldOrder.firstIndex(of: $0) }
        let next: Int
        if let current {
            next = (current + (backwards ? -1 : 1) + textFieldOrder.count) % textFieldOrder.count
        } else {
            next = backwards ? textFieldOrder.count - 1 : 0
        }
        focus(textFieldOrder[next])
        if var editor = editors[textFieldOrder[next]] {
            editor.cursor = editor.text.count
            editors[textFieldOrder[next]] = editor
        }
    }
}
