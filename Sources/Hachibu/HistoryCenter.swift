import Foundation
import HachibuKit
import Observation

/// Records the battery once a minute while Hachibu runs, and hands the
/// popover and the History window what they draw. Test and snapshot runs
/// never record: their store is a file in /tmp that only they fill.
@Observable
final class HistoryCenter {
    static let shared = HistoryCenter()

    /// Battery level over the last 24 hours, oldest first, with gaps where
    /// nothing was recorded. Empty while there is under an hour of data.
    private(set) var dayLevels: [Double] = []
    /// The limit over those 24 hours when it did not change; otherwise nil.
    private(set) var dayLimit: Int?
    @ObservationIgnored private var dayAsOf = Date.distantPast
    /// Goes up when something is recorded, so open charts load again.
    private(set) var revision = 0

    @ObservationIgnored let store: HistoryStore
    @ObservationIgnored private let records: Bool
    @ObservationIgnored private var lastSample: Date?
    @ObservationIgnored private var lastThin: Date?

    private init() {
        store = HistoryStore(file: Self.file)
        // Only the copy in the menu bar records. A command-line run would
        // add samples of its own and could rewrite the file under it.
        records = !Store.isOverridden && !Launch.isOneShot
        if !Store.isOverridden { reloadDay() }
    }

    /// A fixed 24 hours for snapshots. Nothing is read or written.
    init(fixedDay: [Double], limit: Int?) {
        store = HistoryStore(file: URL(fileURLWithPath: "/dev/null/hachibu-fixture"))
        records = false
        dayLevels = fixedDay
        dayLimit = limit
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
            let day = Self.day(in: store, now: now)
            await self?.recorded(day, asOf: now)
        }
    }

    private func recorded(_ day: HistorySeries?, asOf time: Date) {
        revision += 1
        // A slower, older read must not replace a newer one.
        guard time >= dayAsOf else { return }
        dayAsOf = time
        dayLevels = day?.level ?? []
        dayLimit = day?.limit
    }

    private func reloadDay() {
        let store = store
        Task.detached(priority: .utility) { [weak self] in
            let now = Date.now
            let day = Self.day(in: store, now: now)
            await self?.recorded(day, asOf: now)
        }
    }

    private nonisolated static func day(in store: HistoryStore, now: Date) -> HistorySeries? {
        let day: TimeInterval = 24 * 3600
        return HistorySeries.build(samples: store.samples(since: now.addingTimeInterval(-day)),
                                   window: day, now: now, points: 97)
    }

    /// Everything the History window draws for a range, read off the main thread.
    func data(for range: HistoryRange, now: Date = .now) async -> HistoryData {
        let store = store
        return await Task.detached(priority: .userInitiated) {
            HistoryData.recorded(range, from: store, now: now)
        }.value
    }
}
