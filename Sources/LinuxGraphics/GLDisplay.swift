import Foundation
import LinuxHost

/// The app's one GL context, and a pbuffer for each surface on screen.
///
/// Surfaces share the context, so the guest's GL objects are the app's, as
/// in one WebGL context per page, and the wasm shim's buffer bindings stay
/// right from one surface to the next. Drawing goes into the surface's
/// pbuffer, its default framebuffer, and is read back for the window,
/// which Cacao composites. Whatever context was current before, such as
/// SDL's renderer's on the same thread, is current again after. Main
/// thread only.
final class GLDisplay {

    /// Opened on first use; `nil` without EGL and GLES 2.0.
    static let shared: GLDisplay? = GLDisplay()

    /// What `rt_gl_context_generation` returns: it changes whenever the
    /// context is a new one, so the wasm2c shim forgets its bindings.
    nonisolated(unsafe) static var generation: UInt32 = 0

    let gl: GLLibrary

    let display: GLLibrary.EGLDisplay

    let config: GLLibrary.EGLConfig

    private(set) var context: GLLibrary.EGLContext?

    /// What was current before `makeCurrent`, for `restoreCurrent`.
    private var previous: (display: GLLibrary.EGLDisplay, draw: GLLibrary.EGLSurface?, read: GLLibrary.EGLSurface?, context: GLLibrary.EGLContext)?

    private init?() {
        guard let gl = GLLibrary.shared else {
            HostLog.debug("graphics: no libEGL and libGLESv2")
            return nil
        }
        self.gl = gl
        // Without a window system first: Mesa's surfaceless platform needs
        // no display server. Other drivers have their default display.
        var display: GLLibrary.EGLDisplay?
        var major: Int32 = 0, minor: Int32 = 0
        if let platformDisplay = gl.eglGetPlatformDisplay,
           let surfaceless = platformDisplay(GL.EGL_PLATFORM_SURFACELESS_MESA, nil, nil),
           gl.eglInitialize(surfaceless, &major, &minor) != 0 {
            display = surfaceless
        } else if let fallback = gl.eglGetDisplay(nil), gl.eglInitialize(fallback, &major, &minor) != 0 {
            display = fallback
        }
        guard let display else {
            HostLog.warning("graphics: no EGL display (0x\(String(gl.eglGetError(), radix: 16)))")
            return nil
        }
        _ = gl.eglBindAPI(GL.EGL_OPENGL_ES_API)
        let attributes: [Int32] = [
            GL.EGL_SURFACE_TYPE, GL.EGL_PBUFFER_BIT,
            GL.EGL_RENDERABLE_TYPE, GL.EGL_OPENGL_ES2_BIT,
            GL.EGL_RED_SIZE, 8, GL.EGL_GREEN_SIZE, 8, GL.EGL_BLUE_SIZE, 8, GL.EGL_ALPHA_SIZE, 8,
            GL.EGL_DEPTH_SIZE, 24, GL.EGL_STENCIL_SIZE, 8,
            GL.EGL_NONE,
        ]
        var config: GLLibrary.EGLConfig?
        var count: Int32 = 0
        guard gl.eglChooseConfig(display, attributes, &config, 1, &count) != 0, count > 0, let config else {
            HostLog.warning("graphics: no EGL config for GLES 2.0 pbuffers")
            return nil
        }
        self.display = display
        self.config = config
        HostLog.debug("graphics: EGL \(major).\(minor)")
    }

    /// Makes the context if there's none. `false` if EGL refuses.
    func makeContext() -> Bool {
        if context != nil {
            return true
        }
        let attributes: [Int32] = [GL.EGL_CONTEXT_CLIENT_VERSION, 2, GL.EGL_NONE]
        guard let context = gl.eglCreateContext(display, config, nil, attributes) else {
            HostLog.warning("graphics: can't make a GLES 2.0 context (0x\(String(gl.eglGetError(), radix: 16)))")
            return false
        }
        self.context = context
        Self.generation &+= 1
        return true
    }

    /// Destroys the context, with every GL object in it.
    func destroyContext() {
        guard let context else { return }
        if gl.eglGetCurrentContext() == context {
            _ = gl.eglMakeCurrent(display, nil, nil, nil)
        }
        _ = gl.eglDestroyContext(display, context)
        self.context = nil
    }

    func makeSurface(width: Int32, height: Int32) -> GLLibrary.EGLSurface? {
        let attributes: [Int32] = [GL.EGL_WIDTH, max(1, width), GL.EGL_HEIGHT, max(1, height), GL.EGL_NONE]
        let surface = gl.eglCreatePbufferSurface(display, config, attributes)
        if surface == nil {
            HostLog.warning("graphics: can't make a \(width) × \(height) pbuffer (0x\(String(gl.eglGetError(), radix: 16)))")
        }
        return surface
    }

    func destroy(_ surface: GLLibrary.EGLSurface) {
        _ = gl.eglDestroySurface(display, surface)
    }

    /// Makes the context current on `surface`. Fails with
    /// `EGL_CONTEXT_LOST` when the context is gone.
    func makeCurrent(_ surface: GLLibrary.EGLSurface) -> Result<Void, EGLError> {
        guard let context else {
            return .failure(EGLError(code: GL.EGL_CONTEXT_LOST))
        }
        if let current = gl.eglGetCurrentContext(), current != context, let currentDisplay = gl.eglGetCurrentDisplay() {
            previous = (currentDisplay, gl.eglGetCurrentSurface(GL.EGL_DRAW), gl.eglGetCurrentSurface(GL.EGL_READ), current)
        }
        if gl.eglMakeCurrent(display, surface, surface, context) == 0 {
            let error = EGLError(code: gl.eglGetError())
            restoreCurrent()
            return .failure(error)
        }
        return .success(())
    }

    /// Makes current again what was before `makeCurrent`, or nothing.
    func restoreCurrent() {
        if let previous {
            self.previous = nil
            if gl.eglMakeCurrent(previous.display, previous.draw, previous.read, previous.context) != 0 {
                return
            }
        }
        _ = gl.eglMakeCurrent(display, nil, nil, nil)
    }

    /// The current surface's pixels, `width` × `height`, as 8-bit RGBA rows
    /// top to bottom with premultiplied alpha: the default framebuffer,
    /// whatever the guest left bound.
    func readPixels(width: Int32, height: Int32) -> Data {
        let rowBytes = Int(width) * 4
        var framebuffer: Int32 = 0
        var alignment: Int32 = 4
        gl.glGetIntegerv(GL.GL_FRAMEBUFFER_BINDING, &framebuffer)
        gl.glGetIntegerv(GL.GL_PACK_ALIGNMENT, &alignment)
        if framebuffer != 0 {
            gl.glBindFramebuffer(GL.GL_FRAMEBUFFER, 0)
        }
        gl.glPixelStorei(GL.GL_PACK_ALIGNMENT, 4)
        var bottomUp = [UInt8](repeating: 0, count: rowBytes * Int(height))
        bottomUp.withUnsafeMutableBytes { bytes in
            gl.glReadPixels(0, 0, width, height, GL.GL_RGBA, GL.GL_UNSIGNED_BYTE, bytes.baseAddress)
        }
        gl.glPixelStorei(GL.GL_PACK_ALIGNMENT, alignment)
        if framebuffer != 0 {
            gl.glBindFramebuffer(GL.GL_FRAMEBUFFER, UInt32(framebuffer))
        }
        return Self.topDown(bottomUp, rowBytes: rowBytes, height: Int(height))
    }

    /// GL's rows run bottom to top; the window's top to bottom. Its color is
    /// taken as premultiplied, as WebGL's is by default, so no channel may
    /// exceed alpha.
    static func topDown(_ pixels: [UInt8], rowBytes: Int, height: Int) -> Data {
        var data = Data(count: pixels.count)
        data.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
            let output = output.bindMemory(to: UInt8.self)
            for row in 0..<height {
                let source = (height - 1 - row) * rowBytes
                let destination = row * rowBytes
                var offset = 0
                while offset < rowBytes {
                    let alpha = pixels[source + offset + 3]
                    output[destination + offset] = min(pixels[source + offset], alpha)
                    output[destination + offset + 1] = min(pixels[source + offset + 1], alpha)
                    output[destination + offset + 2] = min(pixels[source + offset + 2], alpha)
                    output[destination + offset + 3] = alpha
                    offset += 4
                }
            }
        }
        return data
    }
}

/// An EGL error code.
struct EGLError: Error, CustomStringConvertible {

    var code: Int32

    var isContextLost: Bool { code == GL.EGL_CONTEXT_LOST }

    var description: String { "EGL error 0x\(String(code, radix: 16))" }
}

/// What a wasm2c slice that draws asks of its host (`gl_shim.h`): a number
/// that changes whenever the GL context is a new one.
@_cdecl("rt_gl_context_generation")
public func rt_gl_context_generation() -> UInt32 {
    GLDisplay.generation
}
