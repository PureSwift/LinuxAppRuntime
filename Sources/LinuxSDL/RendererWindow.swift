import CSDL3
import Foundation
import SDL3Swift
import LinuxHost
import LinuxUI

/// A window showing one renderer's store: draws it when it changes, and
/// turns SDL's input into the player's.
public final class RendererWindow {

    public let store: RenderStore

    // Destroyed in this order: the text engine, the renderer, the window.
    let canvas: SDLCanvas

    let sdlRenderer: SDLRenderer

    let sdlWindow: SDL3Swift.SDLWindow

    var window: OpaquePointer { sdlWindow.unsafePointer }

    var renderer: OpaquePointer { sdlRenderer.unsafePointer }

    public let windowID: SDL_WindowID

    private var dirty = true

    private var screenshots: [(path: String, done: (Bool) -> Void)] = []

    /// Pixels per point beyond the display's own density: handhelds use it to
    /// fit phone-sized layouts on small screens (`PortMaster.md` §2).
    let uiScale: Double

    /// Draws a pointer, for screens with no system cursor.
    let drawsCursor: Bool

    /// Where the pointer is, in points, for the drawn cursor.
    private var pointer: Point?

    init?(store: RenderStore, title: String, size: Size, options: SDLApp.DisplayOptions = .init()) {
        uiScale = options.scale
        drawsCursor = options.cursor
        var flags: BitMaskOptionSet<SDL3Swift.SDLWindow.Option> = [.resizable, .highPixelDensity]
        if options.fullscreen {
            flags.insert(.fullscreen)
        }
        let window: SDL3Swift.SDLWindow, renderer: SDLRenderer
        do {
            window = try SDL3Swift.SDLWindow(title: title, frame: (x: .centered, y: .centered, width: Int(size.width),
                                                                  height: Int(size.height)), options: flags)
            renderer = try SDLRenderer(window: window)
        } catch {
            HostLog.error("can't open a window: \(error)")
            return nil
        }
        try? renderer.setVSync(SDLRenderer.VSync(rawValue: 1))
        guard let canvas = SDLCanvas(renderer: renderer.unsafePointer, fonts: .shared) else {
            HostLog.error("can't draw text: \(lastSDLError())")
            return nil
        }
        self.store = store
        self.sdlWindow = window
        self.sdlRenderer = renderer
        self.canvas = canvas
        self.windowID = SDL_WindowID(window.id)
        updateScale()
        store.onNeedsDisplay = { [weak self] in
            self?.dirty = true
        }
        store.onTextInput = { [weak self] active, caret in
            self?.textInput(active, caret: caret)
        }
        store.clipboard = (
            get: {
                guard let text = SDL_GetClipboardText() else { return nil }
                defer { SDL_free(text) }
                return String(cString: text)
            },
            set: { _ = SDL_SetClipboardText($0) }
        )
    }

    deinit {
        store.onNeedsDisplay = nil
        store.onTextInput = nil
    }

    /// The window's size in points.
    public var size: Size {
        var width: Int32 = 0, height: Int32 = 0
        SDL_GetWindowSize(window, &width, &height)
        return Size(width: Double(width) / uiScale, height: Double(height) / uiScale)
    }

    public func setTitle(_ title: String) {
        SDL_SetWindowTitle(window, title)
    }

    /// Saves the next frame as a PNG, then calls `done` with whether it
    /// could.
    public func screenshot(_ path: String, done: @escaping (Bool) -> Void = { _ in }) {
        screenshots.append((path, done))
        dirty = true
    }

    /// Input as if the user gave it, for scripts and tests.
    public func inject(_ event: InputEvent) {
        store.handle(event, size: size)
    }

    // MARK: Drawing

    /// Draws if anything changed. The main loop calls it every turn.
    func drawIfNeeded() {
        guard dirty || store.needsLayout || !screenshots.isEmpty else { return }
        dirty = false
        draw()
    }

    private func draw() {
        let size = self.size
        let frame = store.layout(size: size)
        canvas.begin()
        SDL_SetRenderDrawColorFloat(renderer, 0, 0, 0, 1)
        SDL_RenderClear(renderer)
        Painter.draw(frame, on: canvas)
        if drawsCursor, let pointer {
            Self.drawCursor(at: pointer, on: canvas)
        }
        canvas.end()
        if !screenshots.isEmpty {
            let requests = screenshots
            screenshots = []
            let surface = SDL_RenderReadPixels(renderer, nil)
            for request in requests {
                let saved = surface.map { SDL_SavePNG($0, request.path) } ?? false
                if !saved {
                    HostLog.error("can't save \(request.path): \(lastSDLError())")
                }
                request.done(saved)
            }
            if let surface {
                SDL_DestroySurface(surface)
            }
        }
        SDL_RenderPresent(renderer)
    }

    private func updateScale() {
        let density = Double(SDL_GetWindowPixelDensity(window))
        let scale = (density > 0 ? density : 1) * uiScale
        canvas.scale = scale
        SDLTextEngine.shared.setScale(scale)
        store.setNeedsDisplay()
    }

    private func textInput(_ active: Bool, caret: Rect?) {
        if active {
            if let caret {
                var area = SDL_Rect(x: Int32(caret.minX), y: Int32(caret.minY), w: Int32(caret.width), h: Int32(caret.height))
                SDL_SetTextInputArea(window, &area, 0)
            }
            SDL_StartTextInput(window)
        } else {
            SDL_StopTextInput(window)
        }
    }

    // MARK: Events

    /// Handles an SDL event for this window. Returns false when the window
    /// should close.
    func handle(_ event: inout SDL_Event) -> Bool {
        let size = self.size
        switch SDL_EventType(rawValue: event.type) {
        case SDL_EVENT_WINDOW_CLOSE_REQUESTED:
            return false
        case SDL_EVENT_WINDOW_RESIZED, SDL_EVENT_WINDOW_EXPOSED, SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED:
            dirty = true
        case SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED:
            updateScale()
        case SDL_EVENT_WINDOW_FOCUS_GAINED:
            HostApplication.setState(.active)
        case SDL_EVENT_WINDOW_FOCUS_LOST:
            HostApplication.setState(.inactive)
        case SDL_EVENT_WINDOW_MINIMIZED:
            HostApplication.setState(.background)
        case SDL_EVENT_WINDOW_RESTORED:
            HostApplication.setState(.active)
        case SDL_EVENT_MOUSE_BUTTON_DOWN, SDL_EVENT_MOUSE_BUTTON_UP:
            let point = points(event.button.x, event.button.y)
            guard let button = Self.button(event.button.button) else { break }
            store.handle(event.type == SDL_EVENT_MOUSE_BUTTON_DOWN.rawValue
                ? .pointerDown(point, button: button) : .pointerUp(point, button: button), size: size)
        case SDL_EVENT_MOUSE_MOTION:
            let point = points(event.motion.x, event.motion.y)
            if drawsCursor {
                pointer = point
                dirty = true
            }
            store.handle(.pointerMove(point), size: size)
        case SDL_EVENT_MOUSE_WHEEL:
            let flip: Double = event.wheel.direction == SDL_MOUSEWHEEL_FLIPPED ? -1 : 1
            store.handle(.scroll(points(event.wheel.mouse_x, event.wheel.mouse_y),
                                 dx: Double(event.wheel.x) * 40 * flip, dy: -Double(event.wheel.y) * 40 * flip), size: size)
        case SDL_EVENT_KEY_DOWN:
            if let (key, modifiers) = Self.key(event.key.key, event.key.mod) {
                store.handle(.key(key, modifiers), size: size)
            }
        case SDL_EVENT_TEXT_INPUT:
            if let text = event.text.text {
                store.handle(.text(String(cString: text)), size: size)
            }
        default:
            break
        }
        return true
    }

    /// Window coordinates in points.
    private func points(_ x: Float, _ y: Float) -> Point {
        Point(x: Double(x) / uiScale, y: Double(y) / uiScale)
    }

    /// An arrow with a dark outline, its tip at `point`.
    static func drawCursor(at point: Point, on canvas: Canvas) {
        // Rows of the arrow, as (offset, length), outline first.
        let rows: [(Double, Double)] = (0..<14).map { row in (0, Double(min(row, 9)) + 1) }
        for (index, row) in rows.enumerated() {
            let y = point.y + Double(index)
            canvas.fill(Rect(x: point.x + row.0 - 1, y: y - 1, width: row.1 + 2, height: 3), color: Color.black.opacity(0.7), radius: 0)
        }
        for (index, row) in rows.enumerated() where index > 0 && index < 13 {
            canvas.fill(Rect(x: point.x + row.0, y: point.y + Double(index), width: max(row.1 - 1, 1), height: 1), color: .white, radius: 0)
        }
    }

    static func button(_ button: UInt8) -> PointerButton? {
        switch Int32(button) {
        case SDL_BUTTON_LEFT: .primary
        case SDL_BUTTON_RIGHT: .secondary
        default: nil
        }
    }

    static func key(_ code: SDL_Keycode, _ mod: SDL_Keymod) -> (Key, LinuxUI.KeyModifiers)? {
        var modifiers: LinuxUI.KeyModifiers = []
        if mod & SDL_Keymod(SDL_KMOD_LSHIFT | SDL_KMOD_RSHIFT) != 0 { modifiers.insert(.shift) }
        if mod & SDL_Keymod(SDL_KMOD_LCTRL | SDL_KMOD_RCTRL) != 0 { modifiers.insert(.control) }
        if mod & SDL_Keymod(SDL_KMOD_LALT | SDL_KMOD_RALT) != 0 { modifiers.insert(.alt) }
        let key: Key
        switch code {
        case SDL_Keycode(SDLK_BACKSPACE): key = .backspace
        case SDL_Keycode(SDLK_DELETE): key = .delete
        case SDL_Keycode(SDLK_LEFT): key = .left
        case SDL_Keycode(SDLK_RIGHT): key = .right
        case SDL_Keycode(SDLK_UP): key = .up
        case SDL_Keycode(SDLK_DOWN): key = .down
        case SDL_Keycode(SDLK_HOME): key = .home
        case SDL_Keycode(SDLK_END): key = .end
        case SDL_Keycode(SDLK_RETURN), SDL_Keycode(SDLK_KP_ENTER): key = .enter
        case SDL_Keycode(SDLK_ESCAPE): key = .escape
        case SDL_Keycode(SDLK_TAB): key = .tab
        case SDL_Keycode(SDLK_PAGEUP): key = .pageUp
        case SDL_Keycode(SDLK_PAGEDOWN): key = .pageDown
        case SDL_Keycode(SDLK_A)...SDL_Keycode(SDLK_Z) where modifiers.contains(.control):
            key = .character(Character(UnicodeScalar(UInt8(code))))
        default:
            return nil
        }
        return (key, modifiers)
    }
}
