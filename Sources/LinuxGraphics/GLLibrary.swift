#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// EGL, and the few GLES 2.0 functions the host calls itself, looked up at
/// run time (`Plan.md` §7).
///
/// The host links no GL. For an app that draws, the runner loads
/// `libGLESv2` into the global scope before the app's library, which binds
/// its own `gl*` calls to it, and the host opens the same libraries by
/// name. Without them, `Surface` is unavailable and the rest of the host
/// works as before.
struct GLLibrary {

    typealias EGLDisplay = UnsafeMutableRawPointer
    typealias EGLConfig = UnsafeMutableRawPointer
    typealias EGLSurface = UnsafeMutableRawPointer
    typealias EGLContext = UnsafeMutableRawPointer
    typealias EGLBoolean = UInt32
    typealias EGLint = Int32

    // MARK: EGL

    let eglGetProcAddress: @convention(c) (UnsafePointer<CChar>) -> UnsafeMutableRawPointer?
    let eglGetDisplay: @convention(c) (UnsafeMutableRawPointer?) -> EGLDisplay?
    let eglInitialize: @convention(c) (EGLDisplay?, UnsafeMutablePointer<EGLint>?, UnsafeMutablePointer<EGLint>?) -> EGLBoolean
    let eglBindAPI: @convention(c) (UInt32) -> EGLBoolean
    let eglChooseConfig: @convention(c) (EGLDisplay?, UnsafePointer<EGLint>?, UnsafeMutablePointer<EGLConfig?>?, EGLint, UnsafeMutablePointer<EGLint>?) -> EGLBoolean
    let eglCreatePbufferSurface: @convention(c) (EGLDisplay?, EGLConfig?, UnsafePointer<EGLint>?) -> EGLSurface?
    let eglCreateContext: @convention(c) (EGLDisplay?, EGLConfig?, EGLContext?, UnsafePointer<EGLint>?) -> EGLContext?
    let eglMakeCurrent: @convention(c) (EGLDisplay?, EGLSurface?, EGLSurface?, EGLContext?) -> EGLBoolean
    let eglDestroySurface: @convention(c) (EGLDisplay?, EGLSurface?) -> EGLBoolean
    let eglDestroyContext: @convention(c) (EGLDisplay?, EGLContext?) -> EGLBoolean
    let eglGetError: @convention(c) () -> EGLint
    let eglGetCurrentDisplay: @convention(c) () -> EGLDisplay?
    let eglGetCurrentContext: @convention(c) () -> EGLContext?
    let eglGetCurrentSurface: @convention(c) (EGLint) -> EGLSurface?

    /// EGL 1.5's, or `EGL_EXT_platform_base`'s; `nil` before either.
    let eglGetPlatformDisplay: (@convention(c) (UInt32, UnsafeMutableRawPointer?, UnsafePointer<Int>?) -> EGLDisplay?)?

    // MARK: GLES 2.0

    let glReadPixels: @convention(c) (Int32, Int32, Int32, Int32, UInt32, UInt32, UnsafeMutableRawPointer?) -> Void
    let glGetIntegerv: @convention(c) (UInt32, UnsafeMutablePointer<Int32>?) -> Void
    let glBindFramebuffer: @convention(c) (UInt32, UInt32) -> Void
    let glPixelStorei: @convention(c) (UInt32, Int32) -> Void
    let glGetError: @convention(c) () -> UInt32
    let glClearColor: @convention(c) (Float, Float, Float, Float) -> Void
    let glClear: @convention(c) (UInt32) -> Void
    let glScissor: @convention(c) (Int32, Int32, Int32, Int32) -> Void
    let glEnable: @convention(c) (UInt32) -> Void
    let glDisable: @convention(c) (UInt32) -> Void

    /// The libraries, opened once; `nil` where they aren't installed.
    static let shared: GLLibrary? = GLLibrary()

    private init?() {
        guard let egl = Self.open(["libEGL.so.1", "libEGL.so"]),
              let gles = Self.open([LinuxGraphics.gles, "libGLESv2.so"]) else {
            return nil
        }
        func load<T>(_ library: UnsafeMutableRawPointer, _ name: String, as type: T.Type = T.self) -> T? {
            dlsym(library, name).map { unsafeBitCast($0, to: type) }
        }
        guard let eglGetProcAddress = load(egl, "eglGetProcAddress", as: (@convention(c) (UnsafePointer<CChar>) -> UnsafeMutableRawPointer?).self),
              let eglGetDisplay = load(egl, "eglGetDisplay", as: (@convention(c) (UnsafeMutableRawPointer?) -> EGLDisplay?).self),
              let eglInitialize = load(egl, "eglInitialize", as: (@convention(c) (EGLDisplay?, UnsafeMutablePointer<EGLint>?, UnsafeMutablePointer<EGLint>?) -> EGLBoolean).self),
              let eglBindAPI = load(egl, "eglBindAPI", as: (@convention(c) (UInt32) -> EGLBoolean).self),
              let eglChooseConfig = load(egl, "eglChooseConfig", as: (@convention(c) (EGLDisplay?, UnsafePointer<EGLint>?, UnsafeMutablePointer<EGLConfig?>?, EGLint, UnsafeMutablePointer<EGLint>?) -> EGLBoolean).self),
              let eglCreatePbufferSurface = load(egl, "eglCreatePbufferSurface", as: (@convention(c) (EGLDisplay?, EGLConfig?, UnsafePointer<EGLint>?) -> EGLSurface?).self),
              let eglCreateContext = load(egl, "eglCreateContext", as: (@convention(c) (EGLDisplay?, EGLConfig?, EGLContext?, UnsafePointer<EGLint>?) -> EGLContext?).self),
              let eglMakeCurrent = load(egl, "eglMakeCurrent", as: (@convention(c) (EGLDisplay?, EGLSurface?, EGLSurface?, EGLContext?) -> EGLBoolean).self),
              let eglDestroySurface = load(egl, "eglDestroySurface", as: (@convention(c) (EGLDisplay?, EGLSurface?) -> EGLBoolean).self),
              let eglDestroyContext = load(egl, "eglDestroyContext", as: (@convention(c) (EGLDisplay?, EGLContext?) -> EGLBoolean).self),
              let eglGetError = load(egl, "eglGetError", as: (@convention(c) () -> EGLint).self),
              let eglGetCurrentDisplay = load(egl, "eglGetCurrentDisplay", as: (@convention(c) () -> EGLDisplay?).self),
              let eglGetCurrentContext = load(egl, "eglGetCurrentContext", as: (@convention(c) () -> EGLContext?).self),
              let eglGetCurrentSurface = load(egl, "eglGetCurrentSurface", as: (@convention(c) (EGLint) -> EGLSurface?).self),
              let glReadPixels = load(gles, "glReadPixels", as: (@convention(c) (Int32, Int32, Int32, Int32, UInt32, UInt32, UnsafeMutableRawPointer?) -> Void).self),
              let glGetIntegerv = load(gles, "glGetIntegerv", as: (@convention(c) (UInt32, UnsafeMutablePointer<Int32>?) -> Void).self),
              let glBindFramebuffer = load(gles, "glBindFramebuffer", as: (@convention(c) (UInt32, UInt32) -> Void).self),
              let glPixelStorei = load(gles, "glPixelStorei", as: (@convention(c) (UInt32, Int32) -> Void).self),
              let glGetError = load(gles, "glGetError", as: (@convention(c) () -> UInt32).self),
              let glClearColor = load(gles, "glClearColor", as: (@convention(c) (Float, Float, Float, Float) -> Void).self),
              let glClear = load(gles, "glClear", as: (@convention(c) (UInt32) -> Void).self),
              let glScissor = load(gles, "glScissor", as: (@convention(c) (Int32, Int32, Int32, Int32) -> Void).self),
              let glEnable = load(gles, "glEnable", as: (@convention(c) (UInt32) -> Void).self),
              let glDisable = load(gles, "glDisable", as: (@convention(c) (UInt32) -> Void).self)
        else {
            return nil
        }
        self.eglGetProcAddress = eglGetProcAddress
        self.eglGetDisplay = eglGetDisplay
        self.eglInitialize = eglInitialize
        self.eglBindAPI = eglBindAPI
        self.eglChooseConfig = eglChooseConfig
        self.eglCreatePbufferSurface = eglCreatePbufferSurface
        self.eglCreateContext = eglCreateContext
        self.eglMakeCurrent = eglMakeCurrent
        self.eglDestroySurface = eglDestroySurface
        self.eglDestroyContext = eglDestroyContext
        self.eglGetError = eglGetError
        self.eglGetCurrentDisplay = eglGetCurrentDisplay
        self.eglGetCurrentContext = eglGetCurrentContext
        self.eglGetCurrentSurface = eglGetCurrentSurface
        self.eglGetPlatformDisplay = (dlsym(egl, "eglGetPlatformDisplay") ?? eglGetProcAddress("eglGetPlatformDisplayEXT"))
            .map { unsafeBitCast($0, to: (@convention(c) (UInt32, UnsafeMutableRawPointer?, UnsafePointer<Int>?) -> EGLDisplay?).self) }
        self.glReadPixels = glReadPixels
        self.glGetIntegerv = glGetIntegerv
        self.glBindFramebuffer = glBindFramebuffer
        self.glPixelStorei = glPixelStorei
        self.glGetError = glGetError
        self.glClearColor = glClearColor
        self.glClear = glClear
        self.glScissor = glScissor
        self.glEnable = glEnable
        self.glDisable = glDisable
    }

    private static func open(_ names: [String]) -> UnsafeMutableRawPointer? {
        for name in names {
            if let handle = dlopen(name, RTLD_NOW | RTLD_GLOBAL) {
                return handle
            }
        }
        return nil
    }
}

/// The EGL and GL constants the host uses.
enum GL {
    // EGL
    static let EGL_SUCCESS: Int32 = 0x3000
    static let EGL_CONTEXT_LOST: Int32 = 0x300E
    static let EGL_ALPHA_SIZE: Int32 = 0x3021
    static let EGL_BLUE_SIZE: Int32 = 0x3022
    static let EGL_GREEN_SIZE: Int32 = 0x3023
    static let EGL_RED_SIZE: Int32 = 0x3024
    static let EGL_DEPTH_SIZE: Int32 = 0x3025
    static let EGL_STENCIL_SIZE: Int32 = 0x3026
    static let EGL_SURFACE_TYPE: Int32 = 0x3033
    static let EGL_NONE: Int32 = 0x3038
    static let EGL_RENDERABLE_TYPE: Int32 = 0x3040
    static let EGL_HEIGHT: Int32 = 0x3056
    static let EGL_WIDTH: Int32 = 0x3057
    static let EGL_DRAW: Int32 = 0x3059
    static let EGL_READ: Int32 = 0x305A
    static let EGL_CONTEXT_CLIENT_VERSION: Int32 = 0x3098
    static let EGL_PBUFFER_BIT: Int32 = 0x0001
    static let EGL_OPENGL_ES2_BIT: Int32 = 0x0004
    static let EGL_OPENGL_ES_API: UInt32 = 0x30A0
    static let EGL_PLATFORM_SURFACELESS_MESA: UInt32 = 0x31DD

    // GLES 2.0
    static let GL_COLOR_BUFFER_BIT: UInt32 = 0x4000
    static let GL_SCISSOR_TEST: UInt32 = 0x0C11
    static let GL_PACK_ALIGNMENT: UInt32 = 0x0D05
    static let GL_RGBA: UInt32 = 0x1908
    static let GL_UNSIGNED_BYTE: UInt32 = 0x1401
    static let GL_FRAMEBUFFER: UInt32 = 0x8D40
    static let GL_FRAMEBUFFER_BINDING: UInt32 = 0x8CA6
}
