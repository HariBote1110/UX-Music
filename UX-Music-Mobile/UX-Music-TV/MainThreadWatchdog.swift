import Foundation

#if DEBUG
/// DEBUG-only diagnostic for catching a blocked main thread on a real device
/// (`progress/tvos-playback-concurrency.md` "DEBUG watchdog" 追記). The concurrency audit ranked
/// two remaining boundary-crossing hazards (`generationLock` taken from the MainActor,
/// `MusicPlayerService.dispatchToMainSync`) as deferred rather than fixed — this gives a way to
/// actually CATCH a hang if either of them (or anything else) ever blocks the main thread in the
/// field, rather than only reasoning about it statically.
///
/// **Design**: a background `DispatchSourceTimer` pings `DispatchQueue.main` every `pingInterval`.
/// While a ping is outstanding (i.e. the main queue hasn't drained it yet — the main thread is
/// busy with something else), the SAME tick keeps checking elapsed time rather than queuing a
/// second ping (queuing more work on an already-blocked main queue would only make the eventual
/// backlog worse and tells us nothing new). Once a single outstanding ping has been unanswered for
/// `blockThreshold`, this logs once (not on every subsequent tick) via `logSink` — reset the moment
/// the main queue catches up and services the ping.
///
/// **Why not a real call stack**: `Thread.callStackSymbols` only ever reflects the CALLING
/// thread's own stack — there is no public Swift/Foundation API to snapshot a *different*, still-
/// running thread's stack from the outside. So this logs the blocked-duration plus a marker
/// instead; on a real device, seeing this log line tells you WHEN to attach a debugger (or that a
/// hang report/watchdog trace was captured around that timestamp) to get the actual main-thread
/// backtrace, which is the practical way to use it (see 追記 in
/// `progress/tvos-playback-concurrency.md`).
final class MainThreadWatchdog {
    /// Injectable so tests can observe the hook firing without depending on `NSLog` output.
    /// Defaults to `NSLog` in production.
    static var logSink: (String) -> Void = { NSLog("%@", $0) }

    private let pingInterval: TimeInterval
    private let blockThreshold: TimeInterval
    private let monitorQueue = DispatchQueue(label: "com.uxmusic.tv.mainthreadwatchdog.monitor", qos: .utility)
    private let stateLock = NSLock()

    private var lastPingSentAt = Date()
    private var lastServicedAt = Date()
    private var hasReportedCurrentBlock = false
    private var timer: DispatchSourceTimer?
    private var isRunning = false

    init(pingInterval: TimeInterval = 0.5, blockThreshold: TimeInterval = 2.0) {
        self.pingInterval = pingInterval
        self.blockThreshold = blockThreshold
    }

    func start() {
        stateLock.lock()
        guard !isRunning else {
            stateLock.unlock()
            return
        }
        isRunning = true
        let now = Date()
        lastPingSentAt = now
        lastServicedAt = now
        hasReportedCurrentBlock = false
        stateLock.unlock()

        let timer = DispatchSource.makeTimerSource(queue: monitorQueue)
        timer.schedule(deadline: .now() + pingInterval, repeating: pingInterval)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
        stateLock.lock()
        isRunning = false
        stateLock.unlock()
    }

    /// Always invoked on `monitorQueue` (the timer's own queue), so no lock is needed around the
    /// control-flow decisions themselves — only the shared `Date` fields (also touched from the
    /// main-queue ping-back block below) go through `stateLock`.
    private func tick() {
        stateLock.lock()
        let pingOutstanding = lastServicedAt < lastPingSentAt
        stateLock.unlock()

        guard pingOutstanding else {
            // Previous ping was serviced — safe to send a fresh one.
            stateLock.lock()
            lastPingSentAt = Date()
            stateLock.unlock()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.stateLock.lock()
                self.lastServicedAt = Date()
                self.hasReportedCurrentBlock = false
                self.stateLock.unlock()
            }
            return
        }

        // A ping is still outstanding: the main thread hasn't drained its queue since we last sent
        // one. Don't queue another (see type doc comment) — just check how long it's been blocked.
        stateLock.lock()
        let sentAt = lastPingSentAt
        let alreadyReported = hasReportedCurrentBlock
        stateLock.unlock()

        let blockedFor = Date().timeIntervalSince(sentAt)
        guard blockedFor >= blockThreshold, !alreadyReported else { return }

        stateLock.lock()
        hasReportedCurrentBlock = true
        stateLock.unlock()

        Self.logSink(String(
            format: "[MainThreadWatchdog] main thread blocked >%.1fs (blocked for %.2fs)",
            blockThreshold, blockedFor
        ))
    }
}
#endif
