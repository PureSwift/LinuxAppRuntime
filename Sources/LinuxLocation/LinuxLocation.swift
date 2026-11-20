import DynamicLocation
import DynamicRuntime
import LinuxHost

/// The Location contracts over GeoClue 2 on the system bus (`Plan.md`
/// §11). Main loop only.
public enum LinuxLocation: HostModule {

    public static var contracts: [ContractDescriptor] {
        [
            LocationManagerProxy.descriptor,
            LocationManagerDelegateProxy.descriptor,
            LocationProxy.descriptor,
            HeadingProxy.descriptor,
        ]
    }

    public static func register(in registrar: some ContractRegistrar) {
        LocationManagerProxy.register(LinuxLocationManager.self, in: registrar)
        LocationManagerDelegateProxy.registerInterface(in: registrar)
        LocationProxy.register(LinuxLocationFix.self, in: registrar)
        HeadingProxy.register(LinuxHeading.self, in: registrar)
    }

    public static func permissionProviders() -> [Capability: any PermissionProvider] {
        [.location: LocationPermission()]
    }
}

/// `Permissions` for `location`: `granted` once GeoClue let the app start
/// a client, `denied` once it refused, `unavailable` without GeoClue, and
/// `notDetermined` before.
///
/// `request` starts and stops a client of its own, which is when GeoClue's
/// agent asks the user.
final class LocationPermission: PermissionProvider {

    func status() -> PermissionStatus {
        switch LocationAuthority.shared.status {
        case .authorizedAlways, .authorizedWhenInUse:
            return .granted
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return LocationAuthority.servicesEnabled(LinuxLocationManager.bus) ? .notDetermined : .unavailable
        }
    }

    func request(_ completion: @escaping (PermissionStatus) -> Void) {
        guard LocationAuthority.shared.status != .authorizedAlways else {
            completion(.granted)
            return
        }
        LocationAuthority.shared.ask(LinuxLocationManager.bus, desktopID: LinuxBundle.info.identifier) { error in
            guard let error else {
                completion(.granted)
                return
            }
            switch LinuxLocationManager.error(error) {
            case .denied: completion(.denied)
            case .servicesDisabled: completion(.unavailable)
            default: completion(LocationAuthority.shared.status == .denied ? .denied : .notDetermined)
            }
        }
    }
}
