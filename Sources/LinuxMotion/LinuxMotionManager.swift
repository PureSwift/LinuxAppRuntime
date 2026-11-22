import DynamicMotion
import DynamicRuntime
import Foundation
import Glibc
import LinuxHost

/// The `MotionManager` contract over the kernel's IIO sensors (`Plan.md`
/// §13). Main loop only.
///
/// - **Sensors** are the first IIO device with each one's channels (see
///   `IIOSensors`), in the device's axes by their mount matrix. Device
///   motion needs an accelerometer and a gyroscope, and is fused from them
///   (`MotionFusion`).
/// - **Samples** are polled from sysfs off the main thread, at the interval
///   asked for, no faster than 100 Hz or the sensor's own fastest
///   sampling. Each is stamped with the time since boot as it's read.
/// - **The magnetometer** isn't calibrated: its accuracy is
///   `uncalibrated`.
/// - A sensor that can't be read stops, with `unavailable` once it's gone
///   and `unknown` otherwise. A driver streaming to iio-sensor-proxy may
///   answer busy; those readings are skipped.
public final class LinuxMotionManager: MotionManager {

    /// The machine's sensors; replaceable for tests.
    nonisolated(unsafe) static var sensors = IIOSensors()

    /// The shortest interval polled: 100 Hz, as on iOS.
    static let fastest = 0.01

    let delegate: any MotionManagerDelegate

    private var pollers: [MotionSensor: any Stoppable] = [:]

    init(delegate: any MotionManagerDelegate) {
        self.delegate = delegate
    }

    deinit {
        for poller in pollers.values {
            poller.stop()
        }
    }

    // MARK: Contract

    public static func isAvailable(_ sensor: Int32) -> Bool {
        guard let sensor = MotionSensor(rawValue: sensor) else { return false }
        return channels(sensor) != nil
    }

    public static func make(_ delegate: any MotionManagerDelegate) -> LinuxMotionManager {
        LinuxMotionManager(delegate: delegate)
    }

    /// Starts again at `interval` if it's running.
    public func start(_ sensor: Int32, interval: Double) {
        guard let kind = MotionSensor(rawValue: sensor) else {
            HostLog.error("motion: unknown MotionSensor \(sensor)")
            return
        }
        pollers.removeValue(forKey: kind)?.stop()
        guard let channels = Self.channels(kind) else {
            MainLoop.shared.post { [weak self] in
                guard let self else { return }
                self.delegate.didFail(self, sensor: sensor, error: MotionError.unavailable.rawValue)
            }
            return
        }
        let interval = max(interval.isFinite ? interval : 0, Self.minimumInterval(channels))
        pollers[kind] = poller(kind, channels, interval: interval)
    }

    public func stop(_ sensor: Int32) {
        guard let kind = MotionSensor(rawValue: sensor) else { return }
        pollers.removeValue(forKey: kind)?.stop()
    }

    public func isActive(_ sensor: Int32) -> Bool {
        MotionSensor(rawValue: sensor).map { pollers[$0] != nil } ?? false
    }

    public func minimumInterval(_ sensor: Int32) -> Double {
        guard let kind = MotionSensor(rawValue: sensor), let channels = Self.channels(kind) else { return Self.fastest }
        return Self.minimumInterval(channels)
    }

    // MARK: Sensors

    /// The channels `sensor` reads, each its own; `nil` without them.
    static func channels(_ sensor: MotionSensor) -> [IIOChannel]? {
        let kinds: [IIOSensors.Kind] = switch sensor {
        case .accelerometer: [.accelerometer]
        case .gyroscope: [.gyroscope]
        case .magnetometer: [.magnetometer]
        case .deviceMotion: [.accelerometer, .gyroscope]
        }
        let channels = kinds.compactMap { sensors.channel($0) }
        return channels.count == kinds.count ? channels : nil
    }

    static func minimumInterval(_ channels: [IIOChannel]) -> Double {
        channels.compactMap(\.minimumInterval).reduce(fastest, max)
    }

    private func poller(_ kind: MotionSensor, _ channels: [IIOChannel], interval: Double) -> any Stoppable {
        let fail: (Int32) -> Void = { [weak self] error in
            guard let self else { return }
            self.pollers[kind] = nil
            let code: MotionError = error == ENOENT || error == ENODEV ? .unavailable : .unknown
            HostLog.error("motion: can't read \(channels.map(\.device)): \(String(cString: strerror(error)))")
            self.delegate.didFail(self, sensor: kind.rawValue, error: code.rawValue)
        }
        let channel = channels[0]
        switch kind {
        case .accelerometer, .gyroscope, .magnetometer:
            return SensorPoller(interval: interval, read: {
                channel.read().map { ($0, bootNanoseconds()) }
            }, deliver: { [weak self] reading in
                self?.deliver(kind, reading.0, timestamp: reading.1)
            }, fail: fail)
        case .deviceMotion:
            let gyroscope = channels[1]
            var fusion = MotionFusion()
            return SensorPoller(interval: interval, read: {
                channel.read().flatMap { acceleration in
                    gyroscope.read().map { rotation in
                        fusion.update(acceleration: acceleration, rotationRate: rotation, timestamp: bootNanoseconds())
                    }
                }
            }, deliver: { [weak self] sample in
                self?.deliver(sample)
            }, fail: fail)
        }
    }

    private func deliver(_ kind: MotionSensor, _ v: [Double], timestamp: Int64) {
        switch kind {
        case .accelerometer:
            delegate.didUpdateAcceleration(self, x: v[0], y: v[1], z: v[2], timestamp: timestamp)
        case .gyroscope:
            delegate.didUpdateRotationRate(self, x: v[0], y: v[1], z: v[2], timestamp: timestamp)
        case .magnetometer:
            delegate.didUpdateMagneticField(self, x: v[0], y: v[1], z: v[2], accuracy: MagneticFieldAccuracy.uncalibrated.rawValue,
                                            timestamp: timestamp)
        case .deviceMotion:
            break
        }
    }

    private func deliver(_ sample: MotionFusion.Sample) {
        let (q, g, a, r) = (sample.attitude, sample.gravity, sample.userAcceleration, sample.rotationRate)
        delegate.didUpdateDeviceMotion(
            self,
            attitudeX: q.x, attitudeY: q.y, attitudeZ: q.z, attitudeW: q.w,
            gravityX: g[0], gravityY: g[1], gravityZ: g[2],
            userAccelerationX: a[0], userAccelerationY: a[1], userAccelerationZ: a[2],
            rotationRateX: r[0], rotationRateY: r[1], rotationRateZ: r[2],
            timestamp: sample.timestamp
        )
    }
}

/// A poller, whatever it reads.
protocol Stoppable: AnyObject {
    func stop()
}

extension SensorPoller: Stoppable { }
