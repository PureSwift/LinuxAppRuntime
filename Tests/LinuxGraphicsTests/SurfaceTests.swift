import DynamicGraphics
import Foundation
import Testing
@testable import LinuxGraphics

/// Records what a surface tells its delegate, and draws what `draw` says.
final class RecordingDelegate: SurfaceDelegate {

    var events: [String] = []

    var draw: ((Int32, Int32) -> Void)?

    func frame(_ surface: Surface, timestamp: Int64, width: Int32, height: Int32) {
        events.append("frame \(width)x\(height)")
        draw?(width, height)
    }

    func resize(_ surface: Surface, width: Int32, height: Int32, scale: Float) {
        events.append("resize \(width)x\(height)@\(scale)")
    }

    func contextLost(_ surface: Surface) {
        events.append("lost")
    }

    func contextRestored(_ surface: Surface) {
        events.append("restored")
    }

    func pointer(_ surface: Surface, id: Int32, kind: Int32, phase: Int32, x: Float, y: Float, buttons: Int32, timestamp: Int64) {
        let name = ["down", "move", "up", "cancel"][Int(phase)]
        events.append("pointer \(id) \(name) \(Int(x)),\(Int(y)) \(buttons)")
    }

    func pointerDelta(_ surface: Surface, x: Float, y: Float, timestamp: Int64) {
        events.append("delta")
    }

    func scroll(_ surface: Surface, x: Float, y: Float) {
        events.append("scroll \(Int(x)),\(Int(y))")
    }

    func key(_ surface: Surface, code: Int32, pressed: Bool, modifiers: Int32, isRepeat: Bool, timestamp: Int64) {
        events.append("key \(code) \(pressed ? "down" : "up")\(isRepeat ? " repeat" : "") \(modifiers)")
    }

    func focus(_ surface: Surface, focused: Bool) {
        events.append("focus \(focused)")
    }

    func pointerCapture(_ surface: Surface, captured: Bool) {
        events.append("capture \(captured)")
    }
}

/// Surfaces share the GL context and the display link: one at a time.
@Suite(.serialized) struct SurfaceTests {

    static var hasGL: Bool {
        GLDisplay.shared != nil
    }

    @Test func identifiersFindLiveSurfaces() {
        let delegate = RecordingDelegate()
        var first: LinuxSurface? = LinuxSurface.make(delegate)
        let second = LinuxSurface.make(delegate)
        let id = first!.identifier()
        #expect(id != second.identifier())
        #expect(LinuxSurface.surface(identifier: id) === first)
        first = nil
        #expect(LinuxSurface.surface(identifier: id) == nil)
        #expect(LinuxSurface.surface(identifier: second.identifier()) === second)
        #expect(!second.setPointerCaptured(true))
    }

    @Test func noInputWithoutAView() {
        let delegate = RecordingDelegate()
        let surface = LinuxSurface.make(delegate)
        surface.pointer(id: 0, kind: .mouse, phase: .down, x: 1, y: 1, buttons: .primary, timestamp: 0)
        surface.scroll(x: 0, y: 10)
        surface.focus(true)
        surface.key(code: KeyCode.space.rawValue, pressed: true, modifiers: [], isRepeat: false, timestamp: 0)
        #expect(!delegate.events.contains { $0.hasPrefix("pointer") || $0.hasPrefix("scroll") || $0.hasPrefix("key") })
    }

    @Test func movesWaitForTheFrameOnePerPointer() {
        let delegate = RecordingDelegate()
        let surface = LinuxSurface.make(delegate)
        surface.attach(width: 8, height: 4, scale: 2)
        defer { surface.detach() }
        delegate.events.removeAll()

        surface.pointer(id: 0, kind: .mouse, phase: .move, x: 1, y: 1, buttons: [], timestamp: 1)
        surface.pointer(id: 0, kind: .mouse, phase: .move, x: 2, y: 2, buttons: [], timestamp: 2)
        surface.pointer(id: 1, kind: .touch, phase: .down, x: 5, y: 5, buttons: .primary, timestamp: 3)
        surface.pointer(id: 1, kind: .touch, phase: .move, x: 6, y: 6, buttons: .primary, timestamp: 4)
        surface.pointer(id: 0, kind: .mouse, phase: .move, x: 3, y: 3, buttons: [], timestamp: 5)
        #expect(delegate.events == ["pointer 1 down 5,5 1"])

        surface.frame(timestamp: 6)
        #expect(Array(delegate.events.prefix(3)) == ["pointer 1 down 5,5 1", "pointer 0 move 3,3 0", "pointer 1 move 6,6 1"])

        // A pointer's own move goes before its up.
        delegate.events.removeAll()
        surface.pointer(id: 1, kind: .touch, phase: .move, x: 7, y: 7, buttons: .primary, timestamp: 7)
        surface.pointer(id: 1, kind: .touch, phase: .up, x: 7, y: 7, buttons: [], timestamp: 8)
        #expect(delegate.events == ["pointer 1 move 7,7 1", "pointer 1 up 7,7 0"])
    }

    @Test func losingFocusCancelsContactsAndReleasesKeys() {
        let delegate = RecordingDelegate()
        let surface = LinuxSurface.make(delegate)
        surface.attach(width: 8, height: 4, scale: 1)
        defer { surface.detach() }
        surface.focus(true)
        delegate.events.removeAll()

        surface.pointer(id: 0, kind: .mouse, phase: .down, x: 2, y: 3, buttons: .primary, timestamp: 1)
        surface.pointer(id: 0, kind: .mouse, phase: .move, x: 4, y: 3, buttons: .primary, timestamp: 2)
        surface.key(code: KeyCode.w.rawValue, pressed: true, modifiers: [.shift], isRepeat: false, timestamp: 3)
        surface.key(code: KeyCode.w.rawValue, pressed: true, modifiers: [.shift], isRepeat: true, timestamp: 4)
        surface.focus(false)
        // Every key counts as released: no key-up follows, nor any key.
        surface.key(code: KeyCode.w.rawValue, pressed: false, modifiers: [], isRepeat: false, timestamp: 5)
        surface.key(code: KeyCode.a.rawValue, pressed: true, modifiers: [], isRepeat: false, timestamp: 6)
        #expect(delegate.events == [
            "pointer 0 down 2,3 1",
            "key 26 down 1",
            "key 26 down repeat 1",
            "pointer 0 cancel 4,3 0",
            "focus false",
        ])
    }

    @Test func detachingCancelsContactsAndStopsFrames() {
        let delegate = RecordingDelegate()
        let surface = LinuxSurface.make(delegate)
        surface.attach(width: 8, height: 4, scale: 1)
        #expect(LinuxSurface.attached.contains { $0 === surface })
        surface.pointer(id: 0, kind: .mouse, phase: .down, x: 1, y: 1, buttons: .primary, timestamp: 1)
        surface.detach()
        #expect(delegate.events.last == "pointer 0 cancel 1,1 0")
        #expect(!LinuxSurface.attached.contains { $0 === surface })
        #expect(surface.frame(timestamp: 2) == nil)
    }

    @Test func resizeComesFirstAndOnChange() {
        let delegate = RecordingDelegate()
        let surface = LinuxSurface.make(delegate)
        surface.attach(width: 8, height: 4, scale: 2)
        defer { surface.detach() }
        surface.resize(width: 8, height: 4, scale: 2)
        surface.resize(width: 10, height: 6, scale: 2)
        #expect(delegate.events.filter { $0.hasPrefix("resize") } == ["resize 8x4@2.0", "resize 10x6@2.0"])
        #expect(delegate.events.first == "resize 8x4@2.0")
    }

    @Test func pixelsTurnTopDownAndPremultiplied() {
        // Two rows bottom to top: green, then a red over-bright for its alpha.
        let bottomUp: [UInt8] = [0, 255, 0, 255, 200, 10, 10, 128]
        let data = GLDisplay.topDown(bottomUp, rowBytes: 4, height: 2)
        #expect(Array(data) == [128, 10, 10, 128, 0, 255, 0, 255])
    }

    // MARK: On a real GL

    @Test(.enabled(if: SurfaceTests.hasGL)) func drawsAFrame() throws {
        let gl = try #require(GLLibrary.shared)
        let delegate = RecordingDelegate()
        // Blue, with the top half red: GL's y runs up, so that's its upper
        // rows, which come first in the frame.
        delegate.draw = { width, height in
            gl.glClearColor(0, 0, 1, 1)
            gl.glClear(GL.GL_COLOR_BUFFER_BIT)
            gl.glEnable(GL.GL_SCISSOR_TEST)
            gl.glScissor(0, height / 2, width, height / 2)
            gl.glClearColor(1, 0, 0, 1)
            gl.glClear(GL.GL_COLOR_BUFFER_BIT)
            gl.glDisable(GL.GL_SCISSOR_TEST)
        }
        let surface = LinuxSurface.make(delegate)
        var shown: SurfacePixels?
        surface.display = { shown = $0 }
        surface.attach(width: 8, height: 4, scale: 1)
        defer { surface.detach() }

        let pixels = try #require(surface.frame(timestamp: 1))
        #expect(shown?.data == pixels.data)
        #expect(pixels.width == 8 && pixels.height == 4 && pixels.data.count == 8 * 4 * 4)
        #expect(Array(pixels.data.prefix(4)) == [255, 0, 0, 255])
        #expect(Array(pixels.data.suffix(4)) == [0, 0, 255, 255])
        #expect(gl.glGetError() == 0)
        #expect(delegate.events == ["resize 8x4@1.0", "frame 8x4"])

        // A new size is a new drawable.
        surface.resize(width: 6, height: 2, scale: 1)
        let resized = try #require(surface.frame(timestamp: 2))
        #expect(resized.width == 6 && resized.height == 2 && resized.data.count == 6 * 2 * 4)
    }

    /// SDL's renderer may draw with EGL on the same thread: its context is
    /// current again after a frame.
    @Test(.enabled(if: SurfaceTests.hasGL)) func theCurrentContextIsRestored() throws {
        let display = try #require(GLDisplay.shared)
        let gl = display.gl
        let attributes: [Int32] = [GL.EGL_CONTEXT_CLIENT_VERSION, 2, GL.EGL_NONE]
        let other = try #require(gl.eglCreateContext(display.display, display.config, nil, attributes))
        let otherSurface = try #require(display.makeSurface(width: 2, height: 2))
        defer {
            _ = gl.eglMakeCurrent(display.display, nil, nil, nil)
            display.destroy(otherSurface)
            _ = gl.eglDestroyContext(display.display, other)
        }
        #expect(gl.eglMakeCurrent(display.display, otherSurface, otherSurface, other) != 0)

        let delegate = RecordingDelegate()
        var drewIn: GLLibrary.EGLContext?
        delegate.draw = { _, _ in drewIn = gl.eglGetCurrentContext() }
        let surface = LinuxSurface.make(delegate)
        surface.attach(width: 4, height: 4, scale: 1)
        defer { surface.detach() }
        #expect(surface.frame(timestamp: 1) != nil)
        #expect(drewIn != nil && drewIn != other)
        #expect(gl.eglGetCurrentContext() == other)
        #expect(gl.eglGetCurrentSurface(GL.EGL_DRAW) == otherSurface)
    }

    @Test(.enabled(if: SurfaceTests.hasGL)) func aLostContextIsReplaced() throws {
        let gl = try #require(GLLibrary.shared)
        let delegate = RecordingDelegate()
        delegate.draw = { _, _ in
            gl.glClearColor(0, 1, 0, 1)
            gl.glClear(GL.GL_COLOR_BUFFER_BIT)
        }
        let surface = LinuxSurface.make(delegate)
        surface.attach(width: 4, height: 4, scale: 1)
        defer { surface.detach() }
        #expect(surface.frame(timestamp: 1) != nil)
        let generation = rt_gl_context_generation()

        LinuxSurface.replaceContext()
        #expect(rt_gl_context_generation() != generation)
        let pixels = try #require(surface.frame(timestamp: 2))
        #expect(Array(pixels.data.prefix(4)) == [0, 255, 0, 255])
        #expect(delegate.events == ["resize 4x4@1.0", "frame 4x4", "lost", "restored", "frame 4x4"])
    }
}
