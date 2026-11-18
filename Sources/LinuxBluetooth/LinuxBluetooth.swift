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
            BluetoothCentralProxy.descriptor,
            BluetoothCentralDelegateProxy.descriptor,
            BluetoothPeripheralProxy.descriptor,
            BluetoothPeripheralDelegateProxy.descriptor,
            BluetoothServiceProxy.descriptor,
            BluetoothCharacteristicProxy.descriptor,
            BluetoothDescriptorProxy.descriptor,
            BluetoothAdvertisementProxy.descriptor,
        ]
    }

    public static func register(in registrar: some ContractRegistrar) {
        BluetoothCentralProxy.register(LinuxCentral.self, in: registrar)
        BluetoothPeripheralProxy.register(LinuxPeripheral.self, in: registrar)
        BluetoothServiceProxy.register(LinuxService.self, in: registrar)
        BluetoothCharacteristicProxy.register(LinuxCharacteristic.self, in: registrar)
        BluetoothDescriptorProxy.register(LinuxDescriptor.self, in: registrar)
        BluetoothAdvertisementProxy.register(LinuxAdvertisement.self, in: registrar)
        BluetoothCentralDelegateProxy.registerInterface(in: registrar)
        BluetoothPeripheralDelegateProxy.registerInterface(in: registrar)
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
