import DBus
import DynamicDevice
import LinuxDBus
import LinuxHost

/// iio-sensor-proxy on the system bus (`Plan.md` §10), or a fake one in
/// tests: `net.hadess.SensorProxy` at `/net/hadess/SensorProxy`. Everything
/// it answers arrives on the main loop.
public protocol SensorProxyBus: AnyObject {

    /// Calls one of its methods, which take nothing and answer nothing:
    /// `ClaimAccelerometer`, `ReleaseProximity` and so on.
    func call(_ method: String, reply: @escaping (Result<Void, BusError>) -> Void)

    /// Every property.
    func properties(reply: @escaping (Result<[String: DBusMessageArgument], BusError>) -> Void)

    /// One property, waiting for it: for the contract's synchronous calls.
    func propertyAndWait(_ name: String) -> Result<DBusMessageArgument, BusError>

    /// Calls `handler` with the properties each `PropertiesChanged` signal
    /// changes.
    func subscribeToChanges(_ handler: @escaping ([String: DBusMessageArgument]) -> Void) -> BusSubscription

    func unsubscribe(_ subscription: BusSubscription)
}

/// iio-sensor-proxy's names and values.
public enum SensorProxy {

    public static let service = "net.hadess.SensorProxy"

    public static let path = "/net/hadess/SensorProxy"

    public static let interface = "net.hadess.SensorProxy"

    /// `AccelerometerOrientation`: which edge of the device is up, from its
    /// natural orientation, `normal`. `left-up` has the top to the right.
    public static func orientation(_ name: String) -> DeviceOrientation {
        switch name {
        case "normal": .portrait
        case "bottom-up": .portraitUpsideDown
        case "left-up": .landscapeRight
        case "right-up": .landscapeLeft
        default: .unknown
        }
    }
}

/// iio-sensor-proxy on the system bus, through LinuxDBus.
public final class SystemSensorProxy: SensorProxyBus {

    private let bus: Bus

    public init(bus: Bus = .system) {
        self.bus = bus
    }

    public func call(_ method: String, reply: @escaping (Result<Void, BusError>) -> Void) {
        bus.call(SensorProxy.service, SensorProxy.path, SensorProxy.interface, method) { result in
            reply(result.map { _ in })
        }
    }

    public func properties(reply: @escaping (Result<[String: DBusMessageArgument], BusError>) -> Void) {
        bus.properties(SensorProxy.service, SensorProxy.path, SensorProxy.interface, reply: reply)
    }

    public func propertyAndWait(_ name: String) -> Result<DBusMessageArgument, BusError> {
        bus.propertyAndWait(SensorProxy.service, SensorProxy.path, SensorProxy.interface, name)
    }

    public func subscribeToChanges(_ handler: @escaping ([String: DBusMessageArgument]) -> Void) -> BusSubscription {
        let rule = MatchRule(sender: SensorProxy.service, path: SensorProxy.path, interface: "org.freedesktop.DBus.Properties",
                             member: "PropertiesChanged", arg0: SensorProxy.interface)
        return bus.subscribe(rule) { signal in
            guard signal.body.count > 1 else { return }
            handler(signal.body[1].entries)
        }
    }

    public func unsubscribe(_ subscription: BusSubscription) {
        bus.unsubscribe(subscription)
    }
}
