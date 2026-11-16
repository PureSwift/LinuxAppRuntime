import DynamicGraphics
import Foundation
import LinuxHost

/// A surface's pixels after a frame: 8-bit RGBA, premultiplied, rows top to
/// bottom.
public struct SurfacePixels: Sendable {

    public var data: Data

    public var width: Int

    public var height: Int
}

/// The `Surface` contract (`Graphics.md`): a GL drawable in the window,
/// where a `GLSurface` view with its identifier is.
///
/// The player's view attaches it when it appears, with its size in pixels,
/// and detaches it when it goes. While it's attached, the display link
/// calls `frame` each refresh and hands the pixels to `display`, and the
/// view's pointer and key input goes to the delegate. Main thread only.
public final class LinuxSurface: Surface {

    public let delegate: any SurfaceDelegate

    private let id: Int32

    /// Called with each frame's pixels, for the view to show.
    public var display: ((SurfacePixels) -> Void)?

    /// The drawable's size in pixels, and pixels per point, while attached.
    public private(set) var size: (width: Int32, height: Int32, scale: Float)?

    public var isAttached: Bool { size != nil }

    private var pbuffer: GLLibrary.EGLSurface?

    /// Moves since the last frame, one per pointer, in arrival order.
    private var pendingMoves: [(id: Int32, kind: Int32, x: Float, y: Float, buttons: Int32, timestamp: Int64)] = []

    /// Pointers in contact, by id: their kind and where they last were.
    private var contacts: [Int32: (kind: Int32, x: Float, y: Float)] = [:]

    /// Keys down, which alone get key-ups: after focus is lost, none does.
    private var pressedKeys: Set<Int32> = []

    private var isFocused = false

    private init(delegate: any SurfaceDelegate, id: Int32) {
        self.delegate = delegate
        self.id = id
    }

    deinit {
        if let pbuffer, let display = GLDisplay.shared {
            display.destroy(pbuffer)
        }
        let id = self.id
        Self.surfaces[id] = nil
    }

    // MARK: Surface

    public static func make(_ delegate: any SurfaceDelegate) -> LinuxSurface {
        let surface = LinuxSurface(delegate: delegate, id: nextID)
        nextID &+= 1
        surfaces[surface.id] = Weak(surface)
        return surface
    }

    public func identifier() -> Int32 {
        id
    }

    /// There's no relative mouse mode in the window yet.
    public func setPointerCaptured(_ captured: Bool) -> Bool {
        false
    }

    // MARK: Surfaces

    private struct Weak {
        weak var surface: LinuxSurface?
        init(_ surface: LinuxSurface) { self.surface = surface }
    }

    nonisolated(unsafe) private static var surfaces: [Int32: Weak] = [:]

    nonisolated(unsafe) private static var nextID: Int32 = 1

    /// The live surface whose `identifier()` a `GLSurface` node carries.
    public static func surface(identifier: Int32) -> LinuxSurface? {
        surfaces[identifier]?.surface
    }

    /// Surfaces attached to a view, which get frames.
    static var attached: [LinuxSurface] {
        surfaces.values.compactMap(\.surface).filter(\.isAttached).sorted { $0.id < $1.id }
    }

    // MARK: The view

    /// Puts the surface on screen at a size in pixels: it gets `resize`,
    /// then frames and input.
    public func attach(width: Int32, height: Int32, scale: Float) {
        size = (max(1, width), max(1, height), scale)
        makeDrawable()
        delegate.resize(self, width: max(1, width), height: max(1, height), scale: scale)
        DisplayLink.shared.update()
    }

    /// The view's size or scale changed.
    public func resize(width: Int32, height: Int32, scale: Float) {
        guard let size else { return }
        let width = max(1, width), height = max(1, height)
        guard size.width != width || size.height != height || size.scale != scale else { return }
        self.size = (width, height, scale)
        if size.width != width || size.height != height {
            destroyDrawable()
            makeDrawable()
        }
        delegate.resize(self, width: width, height: height, scale: scale)
    }

    /// The view is gone: pointers in contact are cancelled and focus lost,
    /// and frames stop.
    public func detach() {
        guard isAttached else { return }
        cancelContacts()
        focus(false)
        destroyDrawable()
        size = nil
        DisplayLink.shared.update()
    }

    private func makeDrawable() {
        guard pbuffer == nil, let size, let display = GLDisplay.shared, display.makeContext() else { return }
        pbuffer = display.makeSurface(width: size.width, height: size.height)
    }

    private func destroyDrawable() {
        if let pbuffer, let display = GLDisplay.shared {
            display.destroy(pbuffer)
        }
        pbuffer = nil
    }

    // MARK: Frames

    /// Sends the moves since the last frame, makes the context current on
    /// the surface, has the delegate draw, and reads the frame back. `nil`
    /// without GL, or when the context was lost: the delegate has been told,
    /// and the next frame is in a new one.
    @discardableResult
    public func frame(timestamp: Int64) -> SurfacePixels? {
        guard let size else { return nil }
        flushMoves()
        guard let display = GLDisplay.shared, let pbuffer else { return nil }
        switch display.makeCurrent(pbuffer) {
        case .success:
            break
        case let .failure(error):
            if error.isContextLost {
                Self.replaceContext()
            } else {
                HostLog.warning("graphics: can't draw surface \(id): \(error)")
            }
            return nil
        }
        delegate.frame(self, timestamp: timestamp, width: size.width, height: size.height)
        let pixels = SurfacePixels(
            data: display.readPixels(width: size.width, height: size.height),
            width: Int(size.width),
            height: Int(size.height)
        )
        display.restoreCurrent()
        self.display?(pixels)
        return pixels
    }

    /// The context is gone: every surface's delegate hears so, a new
    /// context replaces it, and they hear that too (`Graphics.md`, step 6).
    static func replaceContext() {
        guard let display = GLDisplay.shared else { return }
        let surfaces = surfaces.values.compactMap(\.surface).sorted { $0.id < $1.id }
        for surface in surfaces {
            surface.delegate.contextLost(surface)
        }
        for surface in surfaces {
            surface.destroyDrawable()
        }
        display.destroyContext()
        guard display.makeContext() else { return }
        for surface in surfaces where surface.isAttached {
            surface.makeDrawable()
        }
        for surface in surfaces {
            surface.delegate.contextRestored(surface)
        }
    }

    // MARK: Input

    /// A pointer event, in pixels of the drawable from its top left. Moves
    /// wait for the next frame, one per pointer.
    public func pointer(id pointer: Int32, kind: PointerKind, phase: PointerPhase, x: Float, y: Float, buttons: PointerButtons, timestamp: Int64) {
        guard isAttached else { return }
        if phase == .move {
            contacts[pointer]?.x = x
            contacts[pointer]?.y = y
            let move = (pointer, kind.rawValue, x, y, buttons.rawValue, timestamp)
            if let index = pendingMoves.firstIndex(where: { $0.id == pointer }) {
                pendingMoves[index] = move
            } else {
                pendingMoves.append(move)
            }
            return
        }
        // Its own move comes first, so the delegate sees them in order.
        if let index = pendingMoves.firstIndex(where: { $0.id == pointer }) {
            let move = pendingMoves.remove(at: index)
            delegate.pointer(self, id: move.id, kind: move.kind, phase: PointerPhase.move.rawValue, x: move.x, y: move.y, buttons: move.buttons, timestamp: move.timestamp)
        }
        switch phase {
        case .down: contacts[pointer] = (kind.rawValue, x, y)
        case .up, .cancel: contacts[pointer] = nil
        case .move: break
        }
        delegate.pointer(self, id: pointer, kind: kind.rawValue, phase: phase.rawValue, x: x, y: y, buttons: buttons.rawValue, timestamp: timestamp)
    }

    private func flushMoves() {
        let moves = pendingMoves
        pendingMoves.removeAll()
        for move in moves {
            delegate.pointer(self, id: move.id, kind: move.kind, phase: PointerPhase.move.rawValue, x: move.x, y: move.y, buttons: move.buttons, timestamp: move.timestamp)
        }
    }

    /// A wheel or trackpad scroll, in pixels.
    public func scroll(x: Float, y: Float) {
        guard isAttached else { return }
        delegate.scroll(self, x: x, y: y)
    }

    /// A key, by its USB HID usage ID. Only while focused; a key-up only
    /// for a key that went down since focus came.
    public func key(code: Int32, pressed: Bool, modifiers: KeyModifiers, isRepeat: Bool, timestamp: Int64) {
        guard isAttached, isFocused else { return }
        if pressed {
            pressedKeys.insert(code)
        } else if pressedKeys.remove(code) == nil {
            return
        }
        delegate.key(self, code: code, pressed: pressed, modifiers: modifiers.rawValue, isRepeat: isRepeat, timestamp: timestamp)
    }

    /// Keyboard focus came or went. Before it goes, pointers in contact
    /// are cancelled; after, every key counts as released.
    public func focus(_ focused: Bool) {
        guard focused != isFocused else { return }
        if !focused {
            cancelContacts()
            pressedKeys.removeAll()
        }
        isFocused = focused
        delegate.focus(self, focused: focused)
    }

    /// Cancels every pointer in contact, where it last was.
    private func cancelContacts() {
        pendingMoves.removeAll()
        let timestamp = MainLoop.now()
        for (pointer, contact) in contacts.sorted(by: { $0.key < $1.key }) {
            delegate.pointer(self, id: pointer, kind: contact.kind, phase: PointerPhase.cancel.rawValue, x: contact.x, y: contact.y, buttons: 0, timestamp: timestamp)
        }
        contacts.removeAll()
    }
}
