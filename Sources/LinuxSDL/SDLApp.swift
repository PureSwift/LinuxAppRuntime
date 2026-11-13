import CSDL3
import Foundation
import LinuxHost
import LinuxUI

/// SDL3 on the main loop (`Plan.md` §2.1): starts SDL's video and SDL3_ttf,
/// waits for events in `SDL_WaitEventTimeout`, wakes it with
/// `SDL_PushEvent`, routes events to windows, and opens a window for each
/// renderer the guest makes.
public final class SDLApp: MainLoopDriver, RendererPresenter {

    nonisolated(unsafe) public static var shared: SDLApp?

    public let loop: MainLoop

    /// The title new windows get.
    public var title: String

    /// The size new windows open at, in points: `LINUXAPPRUNTIME_WINDOW_SIZE`
    /// (`WIDTHxHEIGHT`), or a phone-like 420 × 760.
    public var windowSize: Size

    public private(set) var windows: [SDLWindow] = []

    /// Called when the last window closes; stops the loop by default.
    public var onLastWindowClosed: (() -> Void)?

    private let wakeEvent: UInt32

    /// Starts SDL. `nil` without a display or SDL3_ttf, or with no font.
    /// `identifier` becomes the windows' Wayland app ID and X11 class, which
    /// the app's desktop entry matches.
    public static func start(title: String, identifier: String? = nil, version: String? = nil,
                             loop: MainLoop = .shared) -> SDLApp? {
        if let shared { return shared }
        _ = SDL_SetAppMetadata(title, version, identifier)
        // SDL_INIT_VIDEO.
        guard SDL_Init(0x20) else {
            HostLog.error("SDL video didn't start: \(SDL.error)")
            return nil
        }
        guard SDLTextEngine.shared.start() else {
            return nil
        }
        let app = SDLApp(title: title, loop: loop, wakeEvent: SDL_RegisterEvents(1))
        loop.driver = app
        loop.addObserver { [weak app] in
            app?.windows.forEach { $0.drawIfNeeded() }
        }
        app.onLastWindowClosed = { [weak loop] in loop?.stop() }
        shared = app
        return app
    }

    private init(title: String, loop: MainLoop, wakeEvent: UInt32) {
        self.title = title
        self.loop = loop
        self.wakeEvent = wakeEvent
        self.windowSize = Self.defaultSize()
    }

    private static func defaultSize() -> Size {
        if let value = ProcessInfo.processInfo.environment["LINUXAPPRUNTIME_WINDOW_SIZE"] {
            let parts = value.split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 {
                return Size(width: parts[0], height: parts[1])
            }
        }
        return Size(width: 420, height: 760)
    }

    // MARK: RendererPresenter

    public var textEngine: TextEngine {
        SDLTextEngine.shared
    }

    /// Dark if the system is, or `LINUXAPPRUNTIME_APPEARANCE` says so.
    public var palette: Palette {
        switch ProcessInfo.processInfo.environment["LINUXAPPRUNTIME_APPEARANCE"] {
        case "dark": return Palette(scheme: .dark)
        case "light": return Palette(scheme: .light)
        default: return Palette(scheme: SDL_GetSystemTheme() == SDL_SYSTEM_THEME_DARK ? .dark : .light)
        }
    }

    public func present(_ store: RenderStore) {
        guard let window = SDLWindow(store: store, title: title, size: windowSize) else { return }
        windows.append(window)
    }

    public func dismiss(_ store: RenderStore) {
        windows.removeAll { $0.store === store }
    }

    // MARK: MainLoopDriver

    public func wait(timeout: Int64?) {
        var event = SDL_Event()
        let milliseconds = timeout.map { Int32(clamping: ($0 + 999_999) / 1_000_000) } ?? -1
        guard SDL_WaitEventTimeout(&event, milliseconds) else { return }
        dispatch(&event)
        while SDL_PollEvent(&event) {
            dispatch(&event)
        }
    }

    public func wake() {
        var event = SDL_Event()
        event.type = wakeEvent
        _ = SDL_PushEvent(&event)
    }

    private func dispatch(_ event: inout SDL_Event) {
        switch SDL_EventType(rawValue: event.type) {
        case SDL_EVENT_QUIT:
            closeAll()
            return
        case SDL_EVENT_SYSTEM_THEME_CHANGED:
            let palette = self.palette
            windows.forEach { $0.store.palette = palette }
            return
        default:
            break
        }
        guard event.type != wakeEvent else { return }
        let id = SDL_GetWindowFromEvent(&event).map { SDL_GetWindowID($0) }
        guard let id, let index = windows.firstIndex(where: { $0.windowID == id }) else { return }
        if !windows[index].handle(&event) {
            windows.remove(at: index)
            if windows.isEmpty {
                onLastWindowClosed?()
            }
        }
    }

    private func closeAll() {
        windows = []
        onLastWindowClosed?()
    }
}
