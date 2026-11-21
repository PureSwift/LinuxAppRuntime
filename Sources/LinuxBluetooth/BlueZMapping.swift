import Bluetooth
import DBus
import LinuxDBus
import DynamicBluetooth
import DynamicRuntime

/// Conversions between BlueZ's values and the contract's (`Plan.md` §6).
public enum BlueZMapping {

    // MARK: UUIDs

    /// The Bluetooth Base UUID after its first 32 bits.
    static let baseUUIDSuffix = "-0000-1000-8000-00805F9B34FB"

    /// A UUID as BlueZ writes them: 128-bit, lowercase.
    public static func bluezUUID(_ uuid: BluetoothUUID) -> String {
        uuid.bit128.rawValue.lowercased()
    }

    /// BlueZ's 128-bit string in the shortest form that represents it.
    public static func shortestUUID(_ string: String) -> BluetoothUUID? {
        guard let uuid = BluetoothUUID(rawValue: string.uppercased()) else {
            return nil
        }
        switch uuid {
        case .bit16:
            return uuid
        case .bit32(let value):
            return value <= 0xFFFF ? .bit16(UInt16(value)) : uuid
        case .bit128:
            let raw = uuid.rawValue
            guard raw.hasSuffix(baseUUIDSuffix), let prefix = UInt32(raw.prefix(8), radix: 16) else {
                return uuid
            }
            return prefix <= 0xFFFF ? .bit16(UInt16(prefix)) : .bit32(prefix)
        }
    }

    static func uuid(_ string: String?) throws(RuntimeError) -> BluetoothUUID {
        guard let string, let uuid = shortestUUID(string) else {
            throw RuntimeError.thrown("invalid Bluetooth UUID \(string ?? "(none)")")
        }
        return uuid
    }

    // MARK: Characteristics

    /// `GattCharacteristic1.Flags` as `GATTCharacteristicProperties` bits.
    public static func properties(_ flags: [String]) -> Int32 {
        var bits: Int32 = 0
        for flag in flags {
            switch flag {
            case "broadcast": bits |= 0x01
            case "read": bits |= 0x02
            case "write-without-response": bits |= 0x04
            case "write": bits |= 0x08
            case "notify": bits |= 0x10
            case "indicate": bits |= 0x20
            case "authenticated-signed-writes": bits |= 0x40
            case "extended-properties": bits |= 0x80
            default: break
            }
        }
        return bits
    }

    // MARK: Advertisements

    /// `Device1.ManufacturerData` (`a{qv}`): the first entry, company
    /// identifier first, little-endian, as in the advertisement.
    public static func manufacturerData(_ value: DBusMessageArgument?) -> [UInt8]? {
        guard let entries = value?.pairs else { return nil }
        guard let (company, data) = entries.compactMap({ key, value -> (Int, [UInt8])? in
            guard let company = key.intValue, let bytes = value.bytes else { return nil }
            return (company, bytes)
        }).min(by: { $0.0 < $1.0 }) else { return nil }
        return [UInt8(company & 0xFF), UInt8((company >> 8) & 0xFF)] + data
    }

    /// `Device1.ServiceData` (`a{sv}`).
    public static func serviceData(_ value: DBusMessageArgument?) -> [(uuid: String, data: [UInt8])] {
        guard let entries = value?.pairs else { return [] }
        return entries.compactMap { key, value in
            guard let uuid = key.text, let bytes = value.bytes else { return nil }
            return (uuid, bytes)
        }.sorted { $0.uuid < $1.uuid }
    }

    // MARK: Errors

    /// A BlueZ error as a `BluetoothError` raw value; `unknown` for errors
    /// the contract has no code for.
    public static func errorCode(_ error: BlueZError, connecting: Bool = false) -> Int32 {
        let code: BluetoothError
        switch error.name {
        case "org.bluez.Error.NotConnected":
            code = .notConnected
        case "org.bluez.Error.NotPermitted", "org.bluez.Error.NotAuthorized", "org.bluez.Error.AuthenticationFailed",
             "org.bluez.Error.AuthenticationRejected", "org.bluez.Error.AuthenticationCanceled":
            code = .insufficientAuthentication
        case "org.bluez.Error.NotSupported":
            code = .operationNotSupported
        case "org.bluez.Error.InvalidArguments", "org.bluez.Error.InvalidValueLength", "org.bluez.Error.InvalidOffset":
            code = .invalidParameters
        case "org.bluez.Error.NotReady":
            code = .poweredOff
        case "org.bluez.Error.InProgress", "org.bluez.Error.Failed", "org.bluez.Error.AlreadyConnected",
             "org.bluez.Error.ConnectionAttemptFailed", "org.freedesktop.DBus.Error.NoReply":
            code = connecting ? .connectionFailed : .unknown
        case "org.bluez.Error.DoesNotExist", "org.freedesktop.DBus.Error.UnknownObject":
            code = connecting ? .connectionFailed : .notConnected
        case "org.freedesktop.DBus.Error.AccessDenied":
            code = .unauthorized
        case "org.freedesktop.DBus.Error.ServiceUnknown":
            code = .unsupported
        default:
            code = connecting ? .connectionFailed : .unknown
        }
        if code == .unknown || code == .connectionFailed {
            BlueZHub.log("BlueZ: \(error)")
        }
        return code.rawValue
    }
}
