import Dispatch
import Glibc
import LinuxHost

/// Reads a sensor every `interval` seconds, off the main thread (a driver
/// may take a bus transaction to answer), and hands each reading to the
/// main loop until it's stopped.
///
/// A busy driver skips the reading; any other failure stops the poller and
/// is handed over once, as `errno`.
final class SensorPoller<Reading> {

    let interval: Double

    private var timer: DispatchSourceTimer?

    /// Main loop only.
    private(set) var isStopped = false

    init(
        interval: Double,
        read: @escaping () -> Result<Reading, IIOChannel.ReadError>,
        deliver: @escaping (Reading) -> Void,
        fail: @escaping (Int32) -> Void
    ) {
        self.interval = interval
        let timer = DispatchSource.makeTimerSource(queue: motionQueue)
        self.timer = timer
        timer.setEventHandler { [weak self] in
            switch read() {
            case .success(let reading):
                MainLoop.shared.post {
                    guard let self, !self.isStopped else { return }
                    deliver(reading)
                }
            case .failure(.busy):
                break
            case .failure(.failed(let error)):
                // Stopped on the main loop; a reading meanwhile fails the
                // same way, and isn't handed over.
                MainLoop.shared.post {
                    guard let self, !self.isStopped else { return }
                    self.stop()
                    fail(error)
                }
            }
        }
        timer.schedule(deadline: .now(), repeating: .nanoseconds(Int(interval * 1e9)), leeway: .milliseconds(1))
        timer.resume()
    }

    deinit {
        timer?.cancel()
    }

    /// No reading is delivered after this. Main loop only.
    func stop() {
        isStopped = true
        timer?.cancel()
        timer = nil
    }
}

/// Nanoseconds since boot, counting time asleep, as the contract's
/// timestamps are.
func bootNanoseconds() -> Int64 {
    var time = timespec()
    clock_gettime(CLOCK_BOOTTIME, &time)
    return Int64(time.tv_sec) * 1_000_000_000 + Int64(time.tv_nsec)
}

/// Every poller's reads, one at a time.
private let motionQueue = DispatchQueue(label: "linux-app-host.motion")
