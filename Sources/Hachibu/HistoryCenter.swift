import Foundation
import HachibuKit
import Observation

/// Records the battery once a minute while Hachibu runs, and hands the
/// popover and the History window what they draw. Test and snapshot runs
/// never record: their store is a file in /tmp that only they fill.
@Observable
final class HistoryCenter {
    static let shared = HistoryCenter()

    /// Battery level over the last 24 hours, oldest first. Empty while
    /// there is under an hour of data.
    private(set) var dayLevels: [Double] = []
    /// Goes up when something is recorded, so open charts load again.
    private(set) var revision = 0

    @ObservationIgnored let store: HistoryStore
    @ObservationIgnored private let records: Bool
    @ObservationIgnored private var lastSample: Date?
    @ObservationIgnored private var lastThin: Date?

    private init() {
        store = HistoryStore(file: Self.file)
        records = !Store.isOverridden
        if records { reloadDay() }
    }

    /// A fixed 24 hours for snapshots. Nothing is read or written.
    init(fixedDay: [Double]) {
        store = HistoryStore(file: URL(fileURLWithPath: "/dev/null/hachibu-fixture"))
        records = false
        dayLevels = fixedDay
    }

    /// Where history is kept: Application Support, or the test run's own file.
    nonisolated static var file: URL {
        if let test = ProcessInfo.processInfo.environment["APP_STORE"], !test.isEmpty {
            return URL(fileURLWithPath: test)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Hachibu/history.store")
    }

    /// Called with every reading; keeps one a minute.
    func note(_ reading: BatteryReading, limit: Int, health: Int?, now: Date = .now) {
        guard records, HistoryRules.shouldRecord(last: lastSample, now: now) else { return }
        lastSample = now
        let sample = HistorySample(time: now, percent: reading.percent, isPluggedIn: reading.isPluggedIn,
                                   isCharging: reading.isCharging, temperatureC: reading.temperatureC,
                                   chargerWatts: reading.chargerWatts, macWatts: reading.systemWatts, limit: limit)
        let snapshot = health.flatMap { health in
            reading.cycleCount.map { HealthSnapshot(time: now, healthPercent: health, cycles: $0) }
        }
        let thin = lastThin.map { now.timeIntervalSince($0) > 24 * 3600 } ?? true
        if thin { lastThin = now }
        let store = store
        Task.detached(priority: .utility) { [weak self] in
            store.append(sample)
            if let snapshot { store.appendHealth(snapshot) }
            if thin { store.thin(now: now) }
            let levels = Self.dayLevels(in: store, now: now)
            await self?.recorded(levels)
        }
    }

    private func recorded(_ levels: [Double]) {
        dayLevels = levels
        revision += 1
    }

    private func reloadDay() {
        let store = store
        Task.detached(priority: .utility) { [weak self] in
            let levels = Self.dayLevels(in: store, now: .now)
            await self?.recorded(levels)
        }
    }

    private nonisolated static func dayLevels(in store: HistoryStore, now: Date) -> [Double] {
        let day: TimeInterval = 24 * 3600
        return HistorySeries.build(samples: store.samples(since: now.addingTimeInterval(-day)),
                                   window: day, now: now, points: 96)?.level ?? []
    }

    /// Everything the History window draws for a range, read off the main thread.
    func data(for range: HistoryRange, now: Date = .now) async -> HistoryData {
        let store = store
        return await Task.detached(priority: .userInitiated) {
            HistoryData.recorded(range, from: store, now: now)
        }.value
    }
}
