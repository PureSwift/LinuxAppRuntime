import DynamicGraphics
import DynamicRuntime
import LinuxHost
import RuntimeABI

/// The graphics contracts (`Graphics.md`, `Plan.md` §7): GL surfaces over
/// EGL, drawn into pbuffers and shown by the player's `GLSurface` view.
/// Main loop only.
public enum LinuxGraphics: HostModule {

    public static var contracts: [ContractDescriptor] {
        [SurfaceProxy.descriptor, SurfaceDelegateProxy.descriptor]
    }

    public static func register(in registrar: some ContractRegistrar) {
        SurfaceProxy.register(LinuxSurface.self, in: registrar)
        SurfaceDelegateProxy.registerInterface(in: registrar)
    }

    /// `graphics` is granted where EGL and GLES 2.0 are installed, and
    /// unavailable elsewhere.
    public static func permissionProviders() -> [Capability: any PermissionProvider] {
        [.graphics: isAvailable ? GrantedPermission() : UnavailablePermission()]
    }

    /// GLES 2.0's library, by soname: an app that draws binds its `gl*`
    /// calls to it.
    public static let gles = "libGLESv2.so.2"

    /// Whether `libEGL` and `libGLESv2` load.
    public static var isAvailable: Bool {
        GLLibrary.shared != nil
    }
}
