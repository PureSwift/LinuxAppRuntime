import DynamicMotion
import DynamicRuntime
import LinuxHost

/// The `Pedometer` contract where there's nothing to count steps: Linux
/// has no step counter or service for one. It's `authorized`, since nothing
/// asks, and every count fails with `unavailable`, so an app written for
/// phones runs and hears why. Main loop only.
public final class LinuxPedometer: Pedometer {

    let delegate: any PedometerDelegate

    init(delegate: any PedometerDelegate) {
        self.delegate = delegate
    }

    public static func isStepCountingAvailable() -> Bool { false }

    public static func isDistanceAvailable() -> Bool { false }

    public static func isFloorCountingAvailable() -> Bool { false }

    public static func isHistoryAvailable() -> Bool { false }

    public static func authorizationStatus() -> Int32 {
        MotionAuthorization.authorized.rawValue
    }

    public static func make(_ delegate: any PedometerDelegate) -> LinuxPedometer {
        LinuxPedometer(delegate: delegate)
    }

    public func requestAuthorization() {
        later { $0.delegate.didChangeAuthorization($0, status: MotionAuthorization.authorized.rawValue) }
    }

    public func startUpdates(from start: Int64) {
        later { $0.delegate.didFail($0, error: MotionError.unavailable.rawValue) }
    }

    public func stopUpdates() { }

    public func query(from start: Int64, to end: Int64) {
        later {
            $0.delegate.didQuery($0, steps: -1, distance: .nan, floorsAscended: -1, floorsDescended: -1, start: start, end: end,
                                 error: MotionError.unavailable.rawValue)
        }
    }

    private func later(_ body: @escaping (LinuxPedometer) -> Void) {
        MainLoop.shared.post { [weak self] in
            if let self {
                body(self)
            }
        }
    }
}

/// The `ActivityRecognizer` contract where nothing recognizes activities:
/// unavailable, as on Android without Play services. It's `authorized`,
/// and starting fails with `unavailable`. Main loop only.
public final class LinuxActivityRecognizer: ActivityRecognizer {

    let delegate: any ActivityRecognizerDelegate

    init(delegate: any ActivityRecognizerDelegate) {
        self.delegate = delegate
    }

    public static func isAvailable() -> Bool { false }

    public static func authorizationStatus() -> Int32 {
        MotionAuthorization.authorized.rawValue
    }

    public static func make(_ delegate: any ActivityRecognizerDelegate) -> LinuxActivityRecognizer {
        LinuxActivityRecognizer(delegate: delegate)
    }

    public func requestAuthorization() {
        later { $0.delegate.didChangeAuthorization($0, status: MotionAuthorization.authorized.rawValue) }
    }

    public func startUpdates() {
        later { $0.delegate.didFail($0, error: MotionError.unavailable.rawValue) }
    }

    public func stopUpdates() { }

    private func later(_ body: @escaping (LinuxActivityRecognizer) -> Void) {
        MainLoop.shared.post { [weak self] in
            if let self {
                body(self)
            }
        }
    }
}
