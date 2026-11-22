import DynamicNFC
import DynamicRuntime
import LinuxHost
import RuntimeNative

/// The NFC contracts over neard (`Plan.md` §14): the reader role, reading
/// and writing NDEF. Main loop only.
public enum LinuxNFC: HostModule {

    public static var contracts: [ContractDescriptor] {
        [
            NFCReaderProxy.descriptor,
            NFCReaderDelegateProxy.descriptor,
            NFCTagProxy.descriptor,
            NDEFMessageProxy.descriptor,
            NDEFRecordProxy.descriptor,
        ]
    }

    public static func register(in registrar: some ContractRegistrar) {
        NFCReaderProxy.register(LinuxNFCReader.self, in: registrar)
        NFCReaderDelegateProxy.registerInterface(in: registrar)
        NFCTagProxy.register(LinuxNFCTag.self, in: registrar)
        NDEFMessageProxy.register(LinuxNDEFMessage.self, in: registrar)
        NDEFRecordProxy.register(LinuxNDEFRecord.self, in: registrar)
    }

    /// NFC has no prompt anywhere: a declared `nfc` capability is granted,
    /// and the reader says whether there's hardware.
    public static func permissionProviders() -> [Capability: any PermissionProvider] {
        [.nfc: GrantedPermission()]
    }

    // MARK: Objects passed back

    /// Finds the Swift object behind a proxy the guest passed back. Replace
    /// it if the host runs on a `NativeRuntime` other than `shared`.
    nonisolated(unsafe) public static var objectResolver: (DynamicObject) -> AnyObject? = { proxy in
        NativeRuntime.shared.swiftObject(for: proxy)
    }

    /// The implementation object behind a contract object: itself when the
    /// caller is Swift, or the object a proxy stands for. Nil for an object
    /// the guest made itself.
    static func resolve<T: AnyObject>(_ object: AnyObject, as type: T.Type) -> T? {
        if let object = object as? T {
            return object
        }
        if let proxy = object as? DynamicObject {
            return objectResolver(proxy) as? T
        }
        return nil
    }
}
