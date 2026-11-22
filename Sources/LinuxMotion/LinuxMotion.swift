import DynamicMotion
import DynamicRuntime
import LinuxHost
import RuntimeHost

/// The Motion contracts (`Plan.md` §13): the inertial sensors and the
/// barometer over the kernel's IIO sensors, and a pedometer and activity
/// recognizer that are unavailable. Main loop only.
public enum LinuxMotion: HostModule {

    public static var contracts: [ContractDescriptor] {
        [
            MotionManagerProxy.descriptor,
            MotionManagerDelegateProxy.descriptor,
            AltimeterProxy.descriptor,
            AltimeterDelegateProxy.descriptor,
            PedometerProxy.descriptor,
            PedometerDelegateProxy.descriptor,
            ActivityRecognizerProxy.descriptor,
            ActivityRecognizerDelegateProxy.descriptor,
        ]
    }

    public static func register(in registrar: some ContractRegistrar) {
        MotionManagerProxy.register(LinuxMotionManager.self, in: registrar)
        MotionManagerDelegateProxy.registerInterface(in: registrar)
        AltimeterProxy.register(LinuxAltimeter.self, in: registrar)
        AltimeterDelegateProxy.registerInterface(in: registrar)
        PedometerProxy.register(LinuxPedometer.self, in: registrar)
        PedometerDelegateProxy.registerInterface(in: registrar)
        ActivityRecognizerProxy.register(LinuxActivityRecognizer.self, in: registrar)
        ActivityRecognizerDelegateProxy.registerInterface(in: registrar)
    }

    /// Nothing asks: Motion & Fitness is a phone's permission.
    public static func permissionProviders() -> [Capability: any PermissionProvider] {
        [.motion: GrantedPermission()]
    }
}
