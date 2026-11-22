import DynamicMotion
import DynamicRuntime
import Foundation
import Glibc
import LinuxHost

/// The `Altimeter` contract over an IIO barometer (`in_pressure`), polled
/// once a second as CoreMotion delivers. Main loop only.
///
/// Nothing asks the user, as on Android: it's always `authorized`. The
/// relative altitude is the standard atmosphere's, from the first pressure
/// since `startUpdates()`, as Android's `SensorManager.getAltitude`
/// computes it.
public final class LinuxAltimeter: Altimeter {

    /// How often the pressure is read; replaceable for tests.
    nonisolated(unsafe) static var interval = 1.0

    let delegate: any AltimeterDelegate

    private var poller: SensorPoller<(Double, Int64)>?

    init(delegate: any AltimeterDelegate) {
        self.delegate = delegate
    }

    deinit {
        poller?.stop()
    }

    public static func isAvailable() -> Bool {
        LinuxMotionManager.sensors.channel(.barometer) != nil
    }

    public static func authorizationStatus() -> Int32 {
        MotionAuthorization.authorized.rawValue
    }

    public static func make(_ delegate: any AltimeterDelegate) -> LinuxAltimeter {
        LinuxAltimeter(delegate: delegate)
    }

    /// There's nothing to ask; the answer arrives on a later turn.
    public func requestAuthorization() {
        MainLoop.shared.post { [weak self] in
            guard let self else { return }
            self.delegate.didChangeAuthorization(self, status: MotionAuthorization.authorized.rawValue)
        }
    }

    public func startUpdates() {
        guard poller == nil else { return }
        guard let channel = LinuxMotionManager.sensors.channel(.barometer) else {
            MainLoop.shared.post { [weak self] in
                guard let self else { return }
                self.delegate.didFail(self, error: MotionError.unavailable.rawValue)
            }
            return
        }
        var start: Double?
        poller = SensorPoller(interval: Self.interval, read: {
            channel.read().map { ($0[0], bootNanoseconds()) }
        }, deliver: { [weak self] reading in
            guard let self else { return }
            let pressure = reading.0
            let base = start ?? pressure
            start = base
            let relative = Self.altitude(pressure) - Self.altitude(base)
            self.delegate.didUpdate(self, pressure: pressure, relativeAltitude: relative, timestamp: reading.1)
        }, fail: { [weak self] error in
            guard let self else { return }
            self.poller = nil
            HostLog.error("motion: can't read \(channel.device): \(String(cString: strerror(error)))")
            let code: MotionError = error == ENOENT || error == ENODEV ? .unavailable : .unknown
            self.delegate.didFail(self, error: code.rawValue)
        })
    }

    public func stopUpdates() {
        poller?.stop()
        poller = nil
    }

    /// Metres above sea level at `pressure` kPa, in the standard
    /// atmosphere.
    static func altitude(_ pressure: Double) -> Double {
        44_330 * (1 - pow(pressure / 101.325, 1 / 5.255))
    }
}
