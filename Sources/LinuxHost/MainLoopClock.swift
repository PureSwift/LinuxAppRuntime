import RuntimeCore

/// The `Clock` built-in (§5.4) on the main loop: `CLOCK_MONOTONIC` for
/// `now`, the loop's timers for `schedule`, so timers fire on the main
/// thread.
public final class MainLoopClock: HostClock {

    public let loop: MainLoop

    public init(loop: MainLoop = .shared) {
        self.loop = loop
    }

    public func now() -> Int64 {
        MainLoop.now()
    }

    public func schedule(after nanoseconds: Int64, _ body: @escaping () -> Void) {
        loop.schedule(after: nanoseconds, body)
    }
}
