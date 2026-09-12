import Foundation
import Network
import Observation

/// Observes the active network path and reports whether playback should be treated as cellular.
@MainActor
@Observable
final class NetworkCostMonitor {
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "uxmusic.network-cost-monitor")

    private(set) var isCellular = false {
        didSet {
            guard isCellular != oldValue else { return }
            onCellularStatusChange?(isCellular)
        }
    }

    /// Called on the main actor when `isCellular` changes.
    var onCellularStatusChange: ((Bool) -> Void)?

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let isCellular = Self.isCellularPath(path)
            Task { @MainActor [weak self] in
                self?.isCellular = isCellular
            }
        }
        monitor.start(queue: monitorQueue)
    }

    private nonisolated static func isCellularPath(_ path: NWPath) -> Bool {
        let usesWiFiOrWired = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
        return (path.usesInterfaceType(.cellular) && !usesWiFiOrWired) || path.isExpensive
    }
}
