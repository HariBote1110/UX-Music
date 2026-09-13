#if DEBUG
import Foundation
import SwiftUI
import WatchKit

enum WatchHapticLabHapticType: String, CaseIterable, Identifiable, Sendable {
    case click
    case directionUp
    case directionDown
    case start
    case stop
    case success
    case failure
    case retry
    case notification

    var id: String { rawValue }

    var watchKitType: WKHapticType {
        switch self {
        case .click: return .click
        case .directionUp: return .directionUp
        case .directionDown: return .directionDown
        case .start: return .start
        case .stop: return .stop
        case .success: return .success
        case .failure: return .failure
        case .retry: return .retry
        case .notification: return .notification
        }
    }
}

/// A queue-confined runtime for the DEBUG-only Haptics Lab timer.
private final class WatchHapticLabRuntime: @unchecked Sendable {
    typealias FireHandler = @MainActor @Sendable (WatchHapticLabHapticType, TimeInterval) -> Void
    typealias ReportHandler = @MainActor @Sendable (WatchHapticLatenessStatistics) -> Void

    private let timerQueue = DispatchQueue(
        label: "UXMusicWatch.hapticLab.timer",
        qos: .userInteractive
    )
    private let statisticsQueue = DispatchQueue(label: "UXMusicWatch.hapticLab.statistics")
    private let fireHandler: FireHandler
    private let reportHandler: ReportHandler
    private var timer: DispatchSourceTimer?
    private var pairs: [(scheduled: TimeInterval, fired: TimeInterval)] = []
    /// Confined to `timerQueue`; ticks skipped after a late timer wake are not haptic firings.
    private var skipped = 0

    init(fireHandler: @escaping FireHandler, reportHandler: @escaping ReportHandler) {
        self.fireHandler = fireHandler
        self.reportHandler = reportHandler
    }

    func start(schedule: WatchHapticBeatSchedule, type: WatchHapticLabHapticType) {
        let startUptime = Self.uptime
        timerQueue.async { [weak self] in
            guard let self else { return }
            self.timer?.setEventHandler {}
            self.timer?.cancel()
            self.skipped = 0
            self.statisticsQueue.sync {
                self.pairs = []
            }

            let timer = DispatchSource.makeTimerSource(queue: self.timerQueue)
            var tick = 0
            var nextReportUptime = startUptime + 10
            timer.setEventHandler { [weak self, timer] in
                guard let self else { return }

                let now = Self.uptime
                let currentDeadline = schedule.deadline(forTick: tick, startUptime: startUptime)
                if currentDeadline < now - schedule.interval {
                    let nextTick = schedule.nextTick(
                        after: now,
                        startUptime: startUptime,
                        tolerance: schedule.interval * 0.25
                    )
                    if nextTick > tick {
                        self.skipped += nextTick - tick
                        tick = nextTick
                    }
                }

                let scheduledUptime = schedule.deadline(forTick: tick, startUptime: startUptime)
                tick += 1
                self.schedule(timer, for: schedule.deadline(forTick: tick, startUptime: startUptime))

                DispatchQueue.main.async { [fireHandler = self.fireHandler] in
                    fireHandler(type, scheduledUptime)
                }

                if Self.uptime >= nextReportUptime {
                    nextReportUptime += 10
                    let statistics = self.statisticsSnapshot(skipped: self.skipped)
                    DispatchQueue.main.async { [reportHandler = self.reportHandler] in
                        reportHandler(statistics)
                    }
                }
            }
            self.timer = timer
            self.schedule(timer, for: startUptime)
        }
    }

    func stop() -> WatchHapticLatenessStatistics {
        let skipped = timerQueue.sync { () -> Int in
            timer?.setEventHandler {}
            timer?.cancel()
            timer = nil
            return self.skipped
        }
        return statisticsSnapshot(skipped: skipped)
    }

    func record(scheduled: TimeInterval, fired: TimeInterval) {
        statisticsQueue.async { [self] in
            pairs.append((scheduled: scheduled, fired: fired))
        }
    }

    private func schedule(_ timer: DispatchSourceTimer, for uptime: TimeInterval) {
        let nanoseconds = UInt64(max(0, uptime) * 1_000_000_000)
        timer.schedule(
            deadline: DispatchTime(uptimeNanoseconds: nanoseconds),
            leeway: .nanoseconds(0)
        )
    }

    private func statisticsSnapshot(skipped: Int) -> WatchHapticLatenessStatistics {
        statisticsQueue.sync {
            WatchHapticLatenessStatistics(pairs: pairs, skipped: skipped)
        }
    }

    private static var uptime: TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}

@MainActor
final class WatchHapticLab: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var lastStatsLine = "No samples"

    private lazy var runtime: WatchHapticLabRuntime = WatchHapticLabRuntime(
        fireHandler: { [weak self] type, scheduledUptime in
            self?.fire(type: type, scheduledUptime: scheduledUptime)
        },
        reportHandler: { [weak self] statistics in
            self?.publish(statistics: statistics)
        }
    )
    private var schedule: WatchHapticBeatSchedule?
    private var hapticType: WatchHapticLabHapticType = .click
    private var audioPlayingProvider: (@MainActor @Sendable () -> Bool)?
    private var lastApplicationState: String?

    init() {}

    func start(
        bpm: Int,
        subdivision: Int,
        type: WatchHapticLabHapticType,
        audioPlaying: @escaping @MainActor @Sendable () -> Bool
    ) {
        guard let schedule = WatchHapticBeatSchedule(bpm: bpm, subdivision: subdivision) else {
            return
        }

        if isRunning {
            stop()
        }

        self.schedule = schedule
        hapticType = type
        audioPlayingProvider = audioPlaying
        isRunning = true
        refreshApplicationState()
        lastStatsLine = formattedLine(statistics: WatchHapticLatenessStatistics(pairs: []))
        runtime.start(schedule: schedule, type: type)
    }

    func stop() {
        guard isRunning else { return }

        let statistics = runtime.stop()
        isRunning = false
        publish(statistics: statistics)
    }

    private func fire(type: WatchHapticLabHapticType, scheduledUptime: TimeInterval) {
        guard isRunning else { return }

        // Lateness ends at this timestamp immediately before `play()`, not at the physical
        // vibration, whose hardware delivery time is not observable here.
        let firedUptime = Self.uptime
        WKInterfaceDevice.current().play(type.watchKitType)
        runtime.record(scheduled: scheduledUptime, fired: firedUptime)
    }

    private func publish(statistics: WatchHapticLatenessStatistics) {
        guard schedule != nil else { return }
        let line = formattedLine(statistics: statistics)
        lastStatsLine = line
        print(line)
    }

    func refreshApplicationState() {
        let state = applicationState
        guard state != lastApplicationState else { return }

        lastApplicationState = state
        print("[HapticLab] appState -> \(state)")
    }

    private var applicationState: String {
        switch WKApplication.shared().applicationState {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "inactive"
        }
    }

    private func formattedLine(statistics: WatchHapticLatenessStatistics) -> String {
        let intervalMilliseconds = (schedule?.interval ?? 0) * 1_000
        let audioPlaying = audioPlayingProvider?() ?? false
        return String(
            format: "[HapticLab] bpm=%d sub=%d intervalMs=%.1f type=%@ fired=%d skipped=%d lateP50=%.1f lateP95=%.1f lateMax=%.1f appState=%@ audioPlaying=%@",
            schedule?.bpm ?? 0,
            schedule?.subdivision ?? 0,
            intervalMilliseconds,
            hapticType.rawValue,
            statistics.count,
            statistics.skipped,
            statistics.p50Milliseconds,
            statistics.p95Milliseconds,
            statistics.maxMilliseconds,
            applicationState,
            audioPlaying ? "true" : "false"
        )
    }

    private static var uptime: TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}

struct WatchHapticLabView: View {
    @EnvironmentObject private var player: WatchAudioPlayerService
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var lab = WatchHapticLab()
    @State private var bpm = 120
    @State private var subdivision = 1
    @State private var hapticType: WatchHapticLabHapticType = .click

    private var intervalMilliseconds: Double {
        WatchHapticBeatSchedule(bpm: bpm, subdivision: subdivision).map { $0.interval * 1_000 } ?? 0
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                HStack {
                    Button("−10") { bpm = max(40, bpm - 10) }
                    Text("\(bpm) BPM")
                        .frame(maxWidth: .infinity)
                    Button("+10") { bpm = min(240, bpm + 10) }
                }
                .disabled(lab.isRunning)

                Text(String(format: "Interval %.1f ms", intervalMilliseconds))
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Picker("Subdivision", selection: $subdivision) {
                    ForEach([1, 2, 4], id: \.self) { value in
                        Text("\(value) per beat").tag(value)
                    }
                }
                .disabled(lab.isRunning)

                Picker("Haptic", selection: $hapticType) {
                    ForEach(WatchHapticLabHapticType.allCases) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .disabled(lab.isRunning)

                Button(lab.isRunning ? "Stop" : "Start") {
                    if lab.isRunning {
                        lab.stop()
                    } else {
                        lab.start(
                            bpm: bpm,
                            subdivision: subdivision,
                            type: hapticType,
                            audioPlaying: { player.isPlaying }
                        )
                    }
                }

                Text(lab.lastStatsLine)
                    .font(.system(size: 9, design: .monospaced))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 8)
        }
        .navigationTitle("Haptics Lab")
        .onAppear { lab.refreshApplicationState() }
        .onChange(of: scenePhase) { _, _ in lab.refreshApplicationState() }
    }
}
#endif
