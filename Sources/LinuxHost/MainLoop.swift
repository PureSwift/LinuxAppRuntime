import Dispatch
import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// The main thread's loop (`Plan.md` §2.1): timers, jobs posted from other
/// threads, work to do before waiting (drawing), and the wait itself.
///
/// The guest is single-threaded (§6.4), so everything that calls it runs
/// here. Other threads, such as D-Bus's, hand their results over with
/// `post`. The host doesn't use the main actor or the main dispatch queue:
/// nothing drains them while the loop waits.
public final class MainLoop {

    nonisolated(unsafe) public static let shared = MainLoop()

    /// Does the waiting: a condition variable by default, SDL's event queue
    /// once there's a window. Set it before `run`.
    public var driver: any MainLoopDriver

    private let lock = NSLock()

    private var posted: [() -> Void] = []

    /// Pending timers, soonest first; equal deadlines in scheduling order.
    private var timers: [Timer] = []

    private var nextTimer: UInt64 = 0

    private var observers: [(id: UInt64, body: () -> Void)] = []

    private var nextObserver: UInt64 = 0

    private var stopping = false

    /// Runs jobs and timers on the main dispatch queue instead of in `run`:
    /// for when another loop owns the main thread and drains that queue, as
    /// Cacao's does. Set it before posting or scheduling.
    public var runsOnMainQueue = false

    public init(driver: any MainLoopDriver = ConditionDriver()) {
        self.driver = driver
    }

    // MARK: Time

    /// Monotonic nanoseconds (`CLOCK_MONOTONIC`).
    public static func now() -> Int64 {
        var time = timespec()
        clock_gettime(CLOCK_MONOTONIC, &time)
        return Int64(time.tv_sec) * 1_000_000_000 + Int64(time.tv_nsec)
    }

    // MARK: Jobs

    /// Runs `job` on the main loop, soon. Any thread.
    public func post(_ job: @escaping () -> Void) {
        lock.lock()
        posted.append(job)
        lock.unlock()
        if runsOnMainQueue {
            DispatchQueue.main.async { [self] in turn(wait: false) }
        } else {
            driver.wake()
        }
    }

    // MARK: Timers

    /// A scheduled timer, for `cancel`.
    public struct TimerToken: Hashable, Sendable {
        let id: UInt64
    }

    /// Runs `body` once on the main loop, at least `nanoseconds` from now.
    /// Main thread only.
    @discardableResult
    public func schedule(after nanoseconds: Int64, _ body: @escaping () -> Void) -> TimerToken {
        let (deadline, overflow) = Self.now().addingReportingOverflow(max(nanoseconds, 0))
        return schedule(at: overflow ? .max : deadline, body)
    }

    /// Runs `body` once on the main loop, at or after `deadline` (`now()`'s
    /// time base). Main thread only.
    @discardableResult
    public func schedule(at deadline: Int64, _ body: @escaping () -> Void) -> TimerToken {
        let token = TimerToken(id: nextTimer)
        nextTimer &+= 1
        let timer = Timer(deadline: deadline, token: token, body: body)
        let index = timers.firstIndex { $0.deadline > deadline } ?? timers.endIndex
        timers.insert(timer, at: index)
        if runsOnMainQueue {
            let delay = max(deadline - Self.now(), 0)
            DispatchQueue.main.asyncAfter(deadline: .now() + .nanoseconds(Int(clamping: delay))) { [self] in
                turn(wait: false)
            }
        }
        return token
    }

    /// Cancels a timer that hasn't fired. Main thread only.
    public func cancel(_ token: TimerToken) {
        timers.removeAll { $0.token == token }
    }

    /// Timers that haven't fired.
    public var pendingTimers: Int {
        timers.count
    }

    // MARK: Observers

    /// Runs `body` on every turn, after timers and jobs and before waiting:
    /// where a window draws. Returns a token for `removeObserver`.
    @discardableResult
    public func addObserver(_ body: @escaping () -> Void) -> UInt64 {
        nextObserver &+= 1
        observers.append((nextObserver, body))
        return nextObserver
    }

    public func removeObserver(_ id: UInt64) {
        observers.removeAll { $0.id == id }
    }

    // MARK: Running

    /// Runs until `stop()`.
    public func run() {
        stopping = false
        while !stopping {
            turn(wait: true)
        }
        stopping = false
    }

    /// Makes `run` return after the current turn. Main thread only; other
    /// threads post it.
    public func stop() {
        stopping = true
        driver.wake()
    }

    /// Runs until `done` is true, checking it after each turn's work and
    /// before waiting.
    public func run(until done: () -> Bool) {
        while true {
            work()
            if done() { return }
            waitForWork()
        }
    }

    /// One turn: due timers, posted jobs, observers, then, if `wait`, waits
    /// for the next timer, job or event.
    public func turn(wait: Bool) {
        work()
        if wait {
            waitForWork()
        }
    }

    private func work() {
        runDueTimers()
        runPosted()
        for observer in observers {
            observer.body()
        }
    }

    private func waitForWork() {
        guard !stopping else { return }
        lock.lock()
        let hasPosted = !posted.isEmpty
        lock.unlock()
        if hasPosted {
            return
        }
        let timeout = timers.first.map { max($0.deadline - Self.now(), 0) }
        driver.wait(timeout: timeout)
    }

    /// Runs turns without waiting until there are no posted jobs and no
    /// timers due, for tests and shutdown.
    public func drain() {
        repeat {
            turn(wait: false)
        } while hasWork
    }

    private var hasWork: Bool {
        lock.lock()
        let hasPosted = !posted.isEmpty
        lock.unlock()
        return hasPosted || (timers.first.map { $0.deadline <= Self.now() } ?? false)
    }

    private func runDueTimers() {
        let now = Self.now()
        // Only timers due now: one scheduled while firing waits a turn.
        var due: [Timer] = []
        while let first = timers.first, first.deadline <= now {
            due.append(timers.removeFirst())
        }
        for timer in due {
            timer.body()
        }
    }

    private func runPosted() {
        lock.lock()
        let jobs = posted
        posted = []
        lock.unlock()
        for job in jobs {
            job()
        }
    }

    private struct Timer {
        let deadline: Int64
        let token: TimerToken
        let body: () -> Void
    }
}

/// What the main loop waits on.
public protocol MainLoopDriver: AnyObject {

    /// Waits up to `timeout` nanoseconds, or until woken if `nil`, handling
    /// whatever events arrive meanwhile. Main thread.
    func wait(timeout: Int64?)

    /// Makes `wait` return soon. Any thread.
    func wake()
}

/// Waits on a semaphore: a loop with no window. Extra wakes cost an extra
/// turn, never a missed one.
public final class ConditionDriver: MainLoopDriver {

    private let semaphore = DispatchSemaphore(value: 0)

    public init() { }

    public func wait(timeout: Int64?) {
        if let timeout {
            _ = semaphore.wait(timeout: .now() + .nanoseconds(Int(clamping: timeout)))
        } else {
            semaphore.wait()
        }
    }

    public func wake() {
        semaphore.signal()
    }
}
