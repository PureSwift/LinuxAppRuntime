import DynamicUI
import Foundation
import LinuxHost
import LinuxUI
import Testing
@testable import LinuxSDL

/// SDL with its `offscreen` video driver, as the Docker image sets: a real
/// window, renderer and fonts, without a display. Skipped where SDL can't
/// start.
@Suite(.serialized) struct SDLTests {

    static let app: SDLApp? = {
        if ProcessInfo.processInfo.environment["SDL_VIDEO_DRIVER"] == nil {
            setenv("SDL_VIDEO_DRIVER", "offscreen", 1)
        }
        return SDLApp.start(title: "Tests", loop: MainLoop())
    }()

    @Test func fontsMeasureText() throws {
        try #require(Self.app != nil)
        let engine = SDLTextEngine.shared
        let one = engine.measure("Hello", font: .body, maxWidth: nil, lineLimit: nil)
        #expect(one.width > 20 && one.height >= engine.lineHeight(.body))
        let wrapped = engine.measure("Hello there, wrapping world", font: .body, maxWidth: 60, lineLimit: nil)
        #expect(wrapped.height > one.height)
        #expect(wrapped.width <= 61)
        let limited = engine.measure("Hello there, wrapping world", font: .body, maxWidth: 60, lineLimit: 1)
        #expect(limited.height == engine.lineHeight(.body))
        let bold = FontSpec(size: 15, weight: 700)
        #expect(engine.width("Hello", font: bold) >= engine.width("Hello", font: .body))
    }

    @Test func windowsDrawAndSaveScreenshots() throws {
        let app = try #require(Self.app)
        let store = RenderStore(textEngine: app.textEngine, palette: Palette(scheme: .light))
        store.apply(RenderNode("VStack", id: 1, children: [
            RenderNode("Text", id: 2, props: ["text": "Screenshot"]),
            RenderNode("Color", id: 3, props: ["color": "red"], modifiers: [
                ModifierNode("frame", ["width": 80.0, "height": 40.0]), ModifierNode("cornerRadius", ["radius": 8.0]),
            ]),
        ]))
        app.present(store)
        let window = try #require(app.windows.last)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("sdl-\(UUID().uuidString).png").path
        var saved: Bool?
        window.screenshot(path) { saved = $0 }
        window.drawIfNeeded()
        #expect(saved == true)
        let size = (try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        #expect(size > 500)
        #expect(store.frame?.rect(ofText: "Screenshot") != nil)

        // Input reaches the store through the window.
        window.inject(.pointerMove(Point(x: 1, y: 1)))
        app.dismiss(store)
        #expect(!app.windows.contains { $0.store === store })
    }

    @Test func keysTranslate() {
        #expect(SDLWindow.key(SDL_Keycode(SDLK_BACKSPACE), 0)?.0 == .backspace)
        let paste = SDLWindow.key(SDL_Keycode(SDLK_V), SDL_Keymod(SDL_KMOD_LCTRL))
        #expect(paste?.0 == .character("v") && paste?.1 == .control)
        #expect(SDLWindow.key(SDL_Keycode(SDLK_V), 0) == nil, "plain letters arrive as text")
    }
}

import CSDL3
