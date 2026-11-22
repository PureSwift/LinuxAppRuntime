import DBus
import DynamicDevice
import Foundation
import LinuxDBus
import LinuxHost
import Testing
@testable import LinuxDevice

/// Plays iio-sensor-proxy: answers on the main loop, as the bus does, and
/// records the methods called.
final class FakeSensorProxy: SensorProxyBus {

    var properties: [String: DBusMessageArgument]

    /// Fails every call, as the bus does without the proxy.
    var error: BusError?

    private(set) var calls: [String] = []

    private var handlers: [UInt64: ([String: DBusMessageArgument]) -> Void] = [:]

    private var next: UInt64 = 0

    init(_ properties: [String: DBusMessageArgument] = [:]) {
        self.properties = properties
    }

    var subscribers: Int { handlers.count }

    func call(_ method: String, reply: @escaping (Result<Void, BusError>) -> Void) {
        calls.append(method)
        let answer: Result<Void, BusError> = error.map { .failure($0) } ?? .success(())
        MainLoop.shared.post { reply(answer) }
    }

    func properties(reply: @escaping (Result<[String: DBusMessageArgument], BusError>) -> Void) {
        let answer: Result<[String: DBusMessageArgument], BusError> = error.map { .failure($0) } ?? .success(properties)
        MainLoop.shared.post { reply(answer) }
    }

    func propertyAndWait(_ name: String) -> Result<DBusMessageArgument, BusError> {
        if let error {
            return .failure(error)
        }
        return properties[name].map { .success($0) } ?? .failure(BusError(name: "org.freedesktop.DBus.Error.UnknownProperty"))
    }

    func subscribeToChanges(_ handler: @escaping ([String: DBusMessageArgument]) -> Void) -> BusSubscription {
        next += 1
        handlers[next] = handler
        return BusSubscription(id: next)
    }

    func unsubscribe(_ subscription: BusSubscription) {
        handlers[subscription.id] = nil
    }

    /// The proxy's properties change.
    func change(_ changed: [String: DBusMessageArgument]) {
        properties.merge(changed) { $1 }
        MainLoop.shared.post { [handlers] in
            for id in handlers.keys.sorted() {
                handlers[id]?(changed)
            }
        }
    }
}

extension LinuxDeviceTests {

    func withProxy(_ proxy: FakeSensorProxy, _ body: (LinuxDevice, RecordingDelegate) throws -> Void) rethrows {
        LinuxDevice.reset()
        let previous = LinuxDevice.sensorProxy
        LinuxDevice.sensorProxy = proxy
        defer {
            LinuxDevice.reset()
            LinuxDevice.sensorProxy = previous
        }
        let device = LinuxDevice.current()
        let delegate = RecordingDelegate()
        device.setDelegate(delegate)
        defer { device.setDelegate(nil) }
        try body(device, delegate)
    }

    @Test func orientationNames() {
        #expect(SensorProxy.orientation("normal") == .portrait)
        #expect(SensorProxy.orientation("bottom-up") == .portraitUpsideDown)
        // The left edge up has the top to the right.
        #expect(SensorProxy.orientation("left-up") == .landscapeRight)
        #expect(SensorProxy.orientation("right-up") == .landscapeLeft)
        #expect(SensorProxy.orientation("undefined") == .unknown)
    }

    @Test func orientationComesFromTheProxysAccelerometer() {
        let proxy = FakeSensorProxy(["HasAccelerometer": .boolean(true), "AccelerometerOrientation": .string("right-up")])
        withProxy(proxy) { device, delegate in
            #expect(device.orientation() == DeviceOrientation.unknown.rawValue, "unknown until enabled")
            device.setOrientationUpdatesEnabled(true)
            MainLoop.shared.drain()
            #expect(proxy.calls == ["ClaimAccelerometer"])
            #expect(device.orientation() == DeviceOrientation.landscapeLeft.rawValue)
            #expect(delegate.events == ["orientation \(DeviceOrientation.landscapeLeft.rawValue)"])

            delegate.events = []
            proxy.change(["AccelerometerOrientation": .string("normal")])
            proxy.change(["AccelerometerOrientation": .string("normal"), "LightLevel": .double(3)])
            MainLoop.shared.drain()
            #expect(delegate.events == ["orientation \(DeviceOrientation.portrait.rawValue)"], "each change once")

            device.setOrientationUpdatesEnabled(false)
            MainLoop.shared.drain()
            #expect(proxy.calls == ["ClaimAccelerometer", "ReleaseAccelerometer"])
            #expect(device.orientation() == DeviceOrientation.unknown.rawValue)
            #expect(proxy.subscribers == 0)
        }
    }

    @Test func orientationStaysUnknownWithoutAnAccelerometer() {
        let proxy = FakeSensorProxy(["HasAccelerometer": .boolean(false), "AccelerometerOrientation": .string("undefined")])
        withProxy(proxy) { device, delegate in
            device.setOrientationUpdatesEnabled(true)
            MainLoop.shared.drain()
            #expect(proxy.calls.isEmpty, "nothing to claim")
            #expect(device.orientation() == DeviceOrientation.unknown.rawValue)
            #expect(delegate.events.isEmpty)
        }
        // Nor without the proxy.
        let missing = FakeSensorProxy()
        missing.error = BusError(name: "org.freedesktop.DBus.Error.ServiceUnknown")
        withProxy(missing) { device, delegate in
            device.setOrientationUpdatesEnabled(true)
            MainLoop.shared.drain()
            #expect(device.orientation() == DeviceOrientation.unknown.rawValue)
            #expect(delegate.events.isEmpty)
        }
    }

    @Test func disablingBeforeTheClaimReleasesIt() {
        let proxy = FakeSensorProxy(["HasAccelerometer": .boolean(true), "AccelerometerOrientation": .string("normal")])
        withProxy(proxy) { device, delegate in
            device.setOrientationUpdatesEnabled(true)
            device.setOrientationUpdatesEnabled(false)
            MainLoop.shared.drain()
            #expect(proxy.calls.isEmpty, "turned off before the proxy answered")
            #expect(delegate.events.isEmpty)
        }
    }

    @Test func proximityComesFromTheProxysSensor() {
        let proxy = FakeSensorProxy(["HasProximity": .boolean(true), "ProximityNear": .boolean(false)])
        withProxy(proxy) { device, delegate in
            device.setProximityMonitoringEnabled(true)
            #expect(device.isProximityMonitoringEnabled())
            MainLoop.shared.drain()
            #expect(proxy.calls == ["ClaimProximity"])
            #expect(!device.proximityState())

            proxy.change(["ProximityNear": .boolean(true)])
            MainLoop.shared.drain()
            #expect(device.proximityState())
            #expect(delegate.events == ["proximity true"])

            device.setProximityMonitoringEnabled(false)
            MainLoop.shared.drain()
            #expect(!device.isProximityMonitoringEnabled() && !device.proximityState())
            #expect(proxy.calls == ["ClaimProximity", "ReleaseProximity"])
        }
    }

    @Test func proximityStaysOffWithoutASensor() {
        let proxy = FakeSensorProxy(["HasProximity": .boolean(false)])
        withProxy(proxy) { device, _ in
            device.setProximityMonitoringEnabled(true)
            #expect(!device.isProximityMonitoringEnabled())
            MainLoop.shared.drain()
            #expect(proxy.calls.isEmpty)
        }
        let missing = FakeSensorProxy()
        missing.error = BusError(name: "org.freedesktop.DBus.Error.ServiceUnknown")
        withProxy(missing) { device, _ in
            device.setProximityMonitoringEnabled(true)
            #expect(!device.isProximityMonitoringEnabled())
        }
    }
}
