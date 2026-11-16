import LinuxHost

/// Calls `frame` on every attached surface about 60 times a second, on the
/// main loop, while any is attached (`Graphics.md`, step 4).
///
/// Cacao has no display callback to hook, and its window refreshes at most
/// as often, so a timer on the loop that runs the guest stands in for one.
final class DisplayLink {

    nonisolated(unsafe) static let shared = DisplayLink()

    /// Nanoseconds between frames.
    var interval: Int64 = 1_000_000_000 / 60

    private var timer: MainLoop.TimerToken?

    private var deadline: Int64 = 0

    /// Starts or stops with the surfaces attached.
    func update() {
        if LinuxSurface.attached.isEmpty {
            if let timer {
                MainLoop.shared.cancel(timer)
                self.timer = nil
            }
        } else if timer == nil {
            deadline = MainLoop.now()
            schedule()
        }
    }

    private func schedule() {
        deadline += interval
        // A frame that took too long doesn't make the next ones hurry.
        let now = MainLoop.now()
        if deadline < now {
            deadline = now
        }
        timer = MainLoop.shared.schedule(at: deadline) { [weak self] in
            self?.tick()
        }
    }

    private func tick() {
        timer = nil
        let surfaces = LinuxSurface.attached
        guard !surfaces.isEmpty else { return }
        let timestamp = MainLoop.now()
        for surface in surfaces {
            surface.frame(timestamp: timestamp)
        }
        schedule()
    }
}
