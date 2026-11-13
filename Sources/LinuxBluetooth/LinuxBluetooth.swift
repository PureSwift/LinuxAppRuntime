import DynamicBluetooth
import DynamicRuntime
import LinuxHost
import RuntimeABI
import RuntimeNative

/// The Bluetooth LE central contracts over BlueZ's D-Bus API
/// (`Plan.md` §6). Main loop only.
public enum LinuxBluetooth: HostModule {

    public static var contracts: [ContractDescriptor] {
        [
            CentralProxy.descriptor,
            CentralDelegateProxy.descriptor,
            PeripheralProxy.descriptor,
            PeripheralDelegateProxy.descriptor,
            ServiceProxy.descriptor,
            CharacteristicProxy.descriptor,
            DescriptorProxy.descriptor,
            AdvertisementProxy.descriptor,
        ]
    }

    public static func register(in registrar: some ContractRegistrar) {
        CentralProxy.register(LinuxCentral.self, in: registrar)
        PeripheralProxy.register(LinuxPeripheral.self, in: registrar)
        ServiceProxy.register(LinuxService.self, in: registrar)
        CharacteristicProxy.register(LinuxCharacteristic.self, in: registrar)
        DescriptorProxy.register(LinuxDescriptor.self, in: registrar)
        AdvertisementProxy.register(LinuxAdvertisement.self, in: registrar)
        CentralDelegateProxy.registerInterface(in: registrar)
        PeripheralDelegateProxy.registerInterface(in: registrar)
    }

    /// Desktop Linux has no Bluetooth prompt: a declared `bluetooth`
    /// capability is granted.
    public static func permissionProviders() -> [Capability: any PermissionProvider] {
        [.bluetooth: GrantedPermission()]
    }

    // MARK: Objects passed back

    /// Finds the Swift object behind a proxy the guest passed back. Replace
    /// it if the host runs on a `NativeRuntime` other than `shared`.
    nonisolated(unsafe) public static var objectResolver: (DynamicObject) -> AnyObject? = { proxy in
        NativeRuntime.shared.swiftObject(for: proxy)
    }

    /// The implementation object behind a contract object: itself when the
    /// caller is Swift, or the object a proxy stands for.
    static func resolve<T: AnyObject>(_ object: AnyObject, as type: T.Type) -> T? {
        if let object = object as? T {
            return object
        }
        if let proxy = object as? DynamicObject {
            return objectResolver(proxy) as? T
        }
        return nil
    }

    /// Calls the guest on the next turn of the main loop, for results
    /// decided inside one of its calls.
    static func post(_ body: @escaping () -> Void) {
        MainLoop.shared.post(body)
    }
}
