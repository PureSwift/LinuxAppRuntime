import Foundation
import Testing
@testable import LinuxHost

@Suite struct MainLoopTests {

    @Test func timersFireInDeadlineOrder() {
        let loop = MainLoop()
        var fired: [Int] = []
        loop.schedule(after: 2_000_000) { fired.append(2) }
        loop.schedule(after: 0) { fired.append(0) }
        loop.schedule(after: 1_000_000) { fired.append(1) }
        let cancelled = loop.schedule(after: 0) { fired.append(99) }
        loop.cancel(cancelled)
        #expect(loop.pendingTimers == 3)
        loop.run { loop.pendingTimers == 0 }
        #expect(fired == [0, 1, 2])
    }

    @Test func jobsPostedFromOtherThreadsWakeTheLoop() {
        let loop = MainLoop()
        var received: [Int] = []
        let thread = Thread {
            for value in 0..<3 {
                loop.post { received.append(value) }
            }
            loop.post { loop.stop() }
        }
        thread.start()
        loop.run()
        #expect(received == [0, 1, 2])
    }

    @Test func observersRunEveryTurn() {
        let loop = MainLoop()
        var turns = 0
        let observer = loop.addObserver { turns += 1 }
        loop.turn(wait: false)
        loop.turn(wait: false)
        loop.removeObserver(observer)
        loop.turn(wait: false)
        #expect(turns == 2)
    }

    @Test func drainRunsWorkThatIsReady() {
        let loop = MainLoop()
        var log: [String] = []
        loop.post {
            log.append("job")
            loop.post { log.append("nested") }
        }
        loop.schedule(after: 0) { log.append("timer") }
        loop.schedule(after: 60_000_000_000) { log.append("later") }
        loop.drain()
        #expect(log == ["timer", "job", "nested"])
    }

    @Test func clockSchedulesOnTheLoop() {
        let loop = MainLoop()
        let clock = MainLoopClock(loop: loop)
        let start = clock.now()
        var fired = false
        clock.schedule(after: 1_000_000) { fired = true }
        loop.run { fired }
        #expect(clock.now() - start >= 1_000_000)
    }
}
