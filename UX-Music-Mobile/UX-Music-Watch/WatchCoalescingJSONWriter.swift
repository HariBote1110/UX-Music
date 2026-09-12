import Foundation

/// Serial background JSON writer used for small Watch indexes. A new snapshot replaces a pending
/// one, while an in-progress write is allowed to finish, so rapid transfers never queue redundant
/// encodes and writes on the main actor.
final class WatchCoalescingJSONWriter<Value: Encodable & Sendable>: @unchecked Sendable {
    private let queue: DispatchQueue
    private let fileURL: @Sendable () -> URL
    private let stateLock = NSLock()
    private var pending: Value?
    private var workerScheduled = false

    init(label: String, fileURL: @escaping @Sendable () -> URL) {
        queue = DispatchQueue(label: label, qos: .utility)
        self.fileURL = fileURL
    }

    func enqueue(_ value: Value) {
        stateLock.lock()
        pending = value
        let shouldScheduleWorker = !workerScheduled
        workerScheduled = true
        stateLock.unlock()
        if shouldScheduleWorker {
            queue.async {
                self.drain()
            }
        }
    }

    private func drain() {
        while true {
            stateLock.lock()
            guard let value = pending else {
                workerScheduled = false
                stateLock.unlock()
                return
            }
            pending = nil
            stateLock.unlock()

            write(value)
        }
    }

    private func write(_ value: Value) {
        #if DEBUG
        WatchPerfBreadcrumb.mark("diskWrite.encode.begin")
        #endif
        if let data = try? JSONEncoder().encode(value) {
            try? data.write(to: fileURL(), options: .atomic)
        }
        #if DEBUG
        WatchPerfBreadcrumb.mark("diskWrite.encode.end")
        #endif
    }
}
