import CSDL3
import Foundation
import LinuxHost
import LinuxUI

/// A window showing one renderer's store: draws it when it changes, and
/// turns SDL's input into the player's.
public final class SDLWindow {

    public let store: RenderStore

    let window: OpaquePointer

    let renderer: OpaquePointer

    let canvas: SDLCanvas

    public let windowID: SDL_WindowID

    private var dirty = true

    private var screenshots: [(path: String, done: (Bool) -> Void)] = []

    init?(store: RenderStore, title: String, size: Size) {
        // SDL_WINDOW_RESIZABLE | SDL_WINDOW_HIGH_PIXEL_DENSITY; the macros
        // don't import.
        let flags: SDL_WindowFlags = 0x20 | 0x2000
        guard let window = SDL_CreateWindow(title, Int32(size.width), Int32(size.height), flags) else {
            HostLog.error("can't open a window: \(SDL.error)")
            return nil
        }
        guard let renderer = SDL_CreateRenderer(window, nil) else {
            HostLog.error("can't draw in the window: \(SDL.error)")
            SDL_DestroyWindow(window)
            return nil
        }
        SDL_SetRenderVSync(renderer, 1)
        guard let canvas = SDLCanvas(renderer: renderer, fonts: .shared) else {
            HostLog.error("can't draw text: \(SDL.error)")
            SDL_DestroyRenderer(renderer)
            SDL_DestroyWindow(window)
            return nil
        }
        self.store = store
        self.window = window
        self.renderer = renderer
        self.canvas = canvas
        self.windowID = SDL_GetWindowID(window)
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
        SDL_DestroyRenderer(renderer)
        SDL_DestroyWindow(window)
    }

    /// The window's size in points.
    public var size: Size {
        var width: Int32 = 0, height: Int32 = 0
        SDL_GetWindowSize(window, &width, &height)
        return Size(width: Double(width), height: Double(height))
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
        canvas.end()
        if !screenshots.isEmpty {
            let requests = screenshots
            screenshots = []
            let surface = SDL_RenderReadPixels(renderer, nil)
            for request in requests {
                let saved = surface.map { SDL_SavePNG($0, request.path) } ?? false
                if !saved {
                    HostLog.error("can't save \(request.path): \(SDL.error)")
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
        let scale = density > 0 ? density : 1
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
            LinuxApplication.setState(.active)
        case SDL_EVENT_WINDOW_FOCUS_LOST:
            LinuxApplication.setState(.inactive)
        case SDL_EVENT_WINDOW_MINIMIZED:
            LinuxApplication.setState(.background)
        case SDL_EVENT_WINDOW_RESTORED:
            LinuxApplication.setState(.active)
        case SDL_EVENT_MOUSE_BUTTON_DOWN, SDL_EVENT_MOUSE_BUTTON_UP:
            let point = Point(x: Double(event.button.x), y: Double(event.button.y))
            guard let button = Self.button(event.button.button) else { break }
            store.handle(event.type == SDL_EVENT_MOUSE_BUTTON_DOWN.rawValue
                ? .pointerDown(point, button: button) : .pointerUp(point, button: button), size: size)
        case SDL_EVENT_MOUSE_MOTION:
            store.handle(.pointerMove(Point(x: Double(event.motion.x), y: Double(event.motion.y))), size: size)
        case SDL_EVENT_MOUSE_WHEEL:
            let flip: Double = event.wheel.direction == SDL_MOUSEWHEEL_FLIPPED ? -1 : 1
            store.handle(.scroll(Point(x: Double(event.wheel.mouse_x), y: Double(event.wheel.mouse_y)),
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

    static func button(_ button: UInt8) -> PointerButton? {
        switch Int32(button) {
        case SDL_BUTTON_LEFT: .primary
        case SDL_BUTTON_RIGHT: .secondary
        default: nil
        }
    }

    static func key(_ code: SDL_Keycode, _ mod: SDL_Keymod) -> (Key, KeyModifiers)? {
        var modifiers: KeyModifiers = []
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
