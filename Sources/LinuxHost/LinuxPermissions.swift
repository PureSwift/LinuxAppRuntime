import DynamicRuntime

/// The built-in `Permissions` contract, routing each capability to the
/// `PermissionProvider` of the module whose service gates it.
///
/// - A capability the app doesn't declare is `denied`.
/// - A declared capability no module covers is `unavailable`.
public final class LinuxPermissions: Permissions {

    /// The app's declared capabilities, from `RTCapabilities`.
    nonisolated(unsafe) public static var declared: Set<Capability> = []

    nonisolated(unsafe) public static var providers: [Capability: any PermissionProvider] = [:]

    public static func status(_ capability: Capability) -> Int32 {
        resolve(capability).status().rawValue
    }

    public static func request(_ capability: Capability, delegate: any PermissionsDelegate) {
        // The provider calls back later, on the main loop; the closure holds
        // the delegate until then.
        resolve(capability).request { status in
            delegate.didRequest(capability, status: status.rawValue)
        }
    }

    private static func resolve(_ capability: Capability) -> any PermissionProvider {
        guard declared.contains(capability) else {
            return DeniedPermission()
        }
        return providers[capability] ?? UnavailablePermission()
    }
}

/// An undeclared capability.
private final class DeniedPermission: PermissionProvider {

    func status() -> PermissionStatus {
        .denied
    }

    func request(_ completion: @escaping (PermissionStatus) -> Void) {
        completion(.denied)
    }
}
