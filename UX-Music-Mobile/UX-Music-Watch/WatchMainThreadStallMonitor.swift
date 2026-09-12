#if DEBUG
import Foundation

/// DEBUG-only main-thread watchdog for device runs. It deliberately uses a background timer and
/// tiny main-queue pings so the diagnostic itself does not add work to the UI path.
enum WatchPerfBreadcrumb {
    private static let lock = NSLock()
    private static var lastLabel = "none"
    private static var lastMarkedAt = DispatchTime.now().uptimeNanoseconds

    static func mark(_ label: String) {
        lock.lock()
        lastLabel = label
        lastMarkedAt = DispatchTime.now().uptimeNanoseconds
        lock.unlock()
    }

    fileprivate static func snapshot() -> (label: String, sinceBreadcrumbMs: Int) {
        lock.lock()
        let label = lastLabel
        let markedAt = lastMarkedAt
        lock.unlock()
        let elapsed = DispatchTime.now().uptimeNanoseconds - markedAt
        return (label, Int(elapsed / 1_000_000))
    }
}

enum WatchMainThreadStallMonitor {
    private static let queue = DispatchQueue(
        label: "UXMusicWatch.mainThreadStallMonitor",
        qos: .utility
    )
    private static let lock = NSLock()
    private static var didStart = false
    private static var timer: DispatchSourceTimer?
    private static var nextPingID: UInt64 = 0
    private static var pendingPings: [UInt64: UInt64] = [:]
    private static var stallStart: UInt64?
    private static var didReportStall = false
    private static let stallThresholdNs: UInt64 = 250_000_000

    static func start() {
        lock.lock()
        guard !didStart else {
            lock.unlock()
            return
        }
        didStart = true
        lock.unlock()

        WatchPerfBreadcrumb.mark("WatchMainThreadStallMonitor.start")
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: .milliseconds(50))
        source.setEventHandler {
            sendPing()
            checkForStall()
        }
        lock.lock()
        timer = source
        lock.unlock()
        source.resume()
    }

    private static func sendPing() {
        let id: UInt64
        let sentAt = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        nextPingID += 1
        id = nextPingID
        pendingPings[id] = sentAt
        lock.unlock()

        DispatchQueue.main.async {
            queue.async {
                respond(to: id)
            }
        }
    }

    private static func checkForStall() {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        guard
            let firstPing = pendingPings.values.min(),
            now - firstPing > stallThresholdNs,
            !didReportStall
        else {
            lock.unlock()
            return
        }
        didReportStall = true
        stallStart = firstPing
        lock.unlock()

        let breadcrumb = WatchPerfBreadcrumb.snapshot()
        let durationMs = Int((now - firstPing) / 1_000_000)
        print("[MainThreadStall] \(durationMs)ms breadcrumb=\(breadcrumb.label) "
            + "sinceBreadcrumb=\(breadcrumb.sinceBreadcrumbMs)ms")
    }

    private static func respond(to id: UInt64) {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        pendingPings.removeValue(forKey: id)
        guard didReportStall, let start = stallStart else {
            lock.unlock()
            return
        }
        // The main queue is responsive again; discard pings queued during the same stall so a
        // single long freeze cannot be reported once per delayed ping.
        pendingPings.removeAll()
        didReportStall = false
        stallStart = nil
        lock.unlock()

        let totalMs = Int((now - start) / 1_000_000)
        print("[MainThreadStall] ended total=\(totalMs)ms")
    }
}
#endif
