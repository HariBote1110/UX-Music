import XCTest
@testable import UX_Music_TV

/// Verifies `MainThreadWatchdog` actually fires its log hook when the main thread is genuinely
/// blocked, using the injectable `logSink` (`progress/tvos-playback-concurrency.md` "DEBUG
/// watchdog" 追記). Deliberately blocks the REAL main queue (via `DispatchQueue.main.sync` from a
/// background queue), not a stand-in — the whole point of this type is detecting exactly that
/// condition on a real device.
final class MainThreadWatchdogTests: XCTestCase {
    override func tearDown() {
        MainThreadWatchdog.logSink = { NSLog("%@", $0) }
        super.tearDown()
    }

    func testDeliberatelyBlockedMainQueueTriggersLogHook() {
        let lock = NSLock()
        var loggedMessages: [String] = []
        let expectation = XCTestExpectation(description: "watchdog log hook fired")

        MainThreadWatchdog.logSink = { message in
            lock.lock()
            loggedMessages.append(message)
            lock.unlock()
            if message.contains("[MainThreadWatchdog]") {
                expectation.fulfill()
            }
        }

        // Fast ping/threshold so the test doesn't need to wait anywhere near the production
        // defaults (0.5s ping / 2s threshold) to observe the behaviour.
        let watchdog = MainThreadWatchdog(pingInterval: 0.05, blockThreshold: 0.15)
        watchdog.start()
        defer { watchdog.stop() }

        // Block the ACTUAL main thread for long enough to blow past `blockThreshold`. Dispatched
        // from a background queue so this test method itself (running on the main thread) isn't
        // the one deadlocking — `wait(for:timeout:)` below pumps the run loop while this runs.
        DispatchQueue.global().async {
            DispatchQueue.main.sync {
                Thread.sleep(forTimeInterval: 0.6)
            }
        }

        wait(for: [expectation], timeout: 5)

        lock.lock()
        let captured = loggedMessages
        lock.unlock()
        XCTAssertTrue(
            captured.contains { $0.contains("[MainThreadWatchdog] main thread blocked") },
            "expected at least one blocked-main-thread log line, got: \(captured)"
        )
    }

    func testNeverBlockedMainQueueNeverLogs() {
        let lock = NSLock()
        var loggedMessages: [String] = []
        MainThreadWatchdog.logSink = { message in
            lock.lock()
            loggedMessages.append(message)
            lock.unlock()
        }

        let watchdog = MainThreadWatchdog(pingInterval: 0.05, blockThreshold: 0.2)
        watchdog.start()
        defer { watchdog.stop() }

        // Just let the run loop tick along for a bit with nothing blocking it.
        let doneExpectation = XCTestExpectation(description: "idle wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { doneExpectation.fulfill() }
        wait(for: [doneExpectation], timeout: 5)

        lock.lock()
        let captured = loggedMessages
        lock.unlock()
        XCTAssertTrue(captured.isEmpty, "watchdog should not log when the main thread is never blocked, got: \(captured)")
    }
}
