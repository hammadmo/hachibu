import Foundation
import Testing
@testable import HachibuKit

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func sample(_ minutes: Double, _ percent: Int = 80, temp: Double? = 31.2, charger: Double? = 9.2,
                    mac: Double? = 7.2, limit: Int = 80) -> HistorySample {
    HistorySample(time: t0.addingTimeInterval(minutes * 60), percent: percent, isPluggedIn: true, isCharging: false,
                  temperatureC: temp, chargerWatts: charger, macWatts: mac, limit: limit)
}

private func temporaryFile() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("hachibu-test-\(UUID().uuidString).store")
}

// MARK: S-030

@Test("On battery the charger reads 0 W and the battery arrow points to the Mac")
func powerFlowOnBattery() {
    let onBattery = BatteryReading(percent: 60, isPluggedIn: false, currentMA: -900, voltageMV: 11_500,
                                   chargerWatts: 12, systemWatts: 10.2)
    let flow = PowerFlow(onBattery)
    #expect(flow.charger == 0)
    #expect(flow.batteryFeedsMac)
    #expect((flow.battery ?? 0) < 0)
    let charging = BatteryReading(percent: 60, isPluggedIn: true, currentMA: 1_800, voltageMV: 12_000,
                                  chargerWatts: 30, systemWatts: 8)
    #expect(PowerFlow(charging).charger == 30)
    #expect(!PowerFlow(charging).batteryFeedsMac)
    #expect(PowerFlow(nil).charger == nil && !PowerFlow(nil).batteryFeedsMac)
}

// MARK: S-031

@Test("A sample survives the trip to disk, to a tenth of a degree and of a watt")
func sampleRoundTrip() {
    let original = HistorySample(time: t0, percent: 73, isPluggedIn: true, isCharging: true, temperatureC: 34.7,
                                 chargerWatts: 29.8, macWatts: 7.2, limit: 80)
    #expect(original.encoded().count == HistorySample.size)
    #expect(HistorySample(encoded: original.encoded()) == original)
    let bare = HistorySample(time: t0, percent: 0, isPluggedIn: false, isCharging: false)
    #expect(HistorySample(encoded: bare.encoded()) == bare)
    #expect(HistorySample(encoded: Data(count: 15)) == nil)
    #expect(HistorySample(encoded: Data(count: 16)) == nil)
}

@Test("Samples written to a store come back in time order")
func storeKeepsOrder() {
    let url = temporaryFile()
    defer { try? FileManager.default.removeItem(at: url) }
    let store = HistoryStore(file: url)
    #expect(store.samples().isEmpty)
    for minutes in [2.0, 0, 1, 3] { store.append(sample(minutes, 70 + Int(minutes))) }
    #expect(store.samples().map(\.percent) == [70, 71, 72, 73])
    #expect(store.samples(since: t0.addingTimeInterval(120)).map(\.percent) == [72, 73])
    #expect(HistoryStore(file: url).samples().count == 4)
    #expect(store.sizeInBytes == 4 * HistorySample.size)
}

@Test("A record cut short does not spoil the ones after it")
func storeSurvivesPartialWrite() throws {
    let url = temporaryFile()
    defer { try? FileManager.default.removeItem(at: url) }
    let store = HistoryStore(file: url)
    store.append(sample(0, 70))
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data([1, 2, 3, 4, 5]))
    try handle.close()
    store.append(sample(1, 71))
    #expect(store.samples().map(\.percent) == [70, 71])
}

@Test("One sample a minute, at most")
func sampleCadence() {
    #expect(HistoryRules.shouldRecord(last: nil, now: t0))
    #expect(!HistoryRules.shouldRecord(last: t0, now: t0.addingTimeInterval(59)))
    #expect(HistoryRules.shouldRecord(last: t0, now: t0.addingTimeInterval(60)))
    // The clock was set back: record, so History is not silent until it catches up.
    #expect(HistoryRules.shouldRecord(last: t0, now: t0.addingTimeInterval(-3600)))
}

@Test("Samples older than 90 days are thinned to one per hour")
func thinning() {
    let now = t0.addingTimeInterval(100 * 24 * 3600)
    // Three hours of minutes, 100 days old; and one hour of minutes from yesterday.
    let old = (0..<180).map { sample(Double($0)) }
    let recent = (0..<60).map { sample(Double(99 * 24 * 60 + $0)) }
    let kept = HistoryRules.thinned(old + recent, now: now)
    #expect(kept.count == 3 + 60)
    #expect(kept.prefix(3).map(\.time) == [0, 60, 120].map { t0.addingTimeInterval($0 * 60) })
    #expect(HistoryRules.thinned(recent, now: now) == recent)

    let url = temporaryFile()
    defer { try? FileManager.default.removeItem(at: url) }
    let store = HistoryStore(file: url)
    (old + recent).forEach(store.append)
    #expect(store.thin(now: now) == 177)
    #expect(store.samples().count == 63)
    #expect(store.thin(now: now) == 0)
}

// MARK: S-032, S-033

@Test("Under an hour of data there is nothing to chart")
func collecting() {
    let now = t0.addingTimeInterval(59 * 60)
    let short = (0..<60).map { sample(Double($0)) }
    #expect(HistorySeries.build(samples: short, window: 24 * 3600, now: now, points: 96) == nil)
    #expect(HistorySeries.build(samples: [], window: 24 * 3600, now: now, points: 96) == nil)
    let enough = short + [sample(60)]
    #expect(HistorySeries.build(samples: enough, window: 24 * 3600, now: t0.addingTimeInterval(3600), points: 97) != nil)
}

@Test("The chart covers the whole window and leaves a gap where nothing was recorded")
func seriesShape() throws {
    // Six hours: two at 80%, three with nothing, one at 60%.
    let samples = (0...120).map { sample(Double($0), 80) } + (300...360).map { sample(Double($0), 60, temp: nil) }
    let now = t0.addingTimeInterval(360 * 60)
    let series = try #require(HistorySeries.build(samples: samples, window: 6 * 3600, now: now, points: 7))
    #expect(series.start == t0)
    #expect(series.end == now)
    // One point an hour, each at its own time: 0h 1h 2h 3h 4h 5h 6h.
    #expect(Array(series.level[0...2]) == [80, 80, 80])
    #expect(series.level[3].isNaN && series.level[4].isNaN)
    #expect(Array(series.level[5...6]) == [60, 60])
    // Temperature stopped being measured: nothing is carried forward or back.
    #expect(series.temperature[0...2].allSatisfy { abs($0 - 31.2) < 0.001 })
    #expect(series.temperature[3...6].allSatisfy { $0.isNaN })
    #expect(series.limit == 80)
}

@Test("Time before the first sample is a gap, not an invented line")
func seriesLeadingGap() throws {
    let samples = (0...60).map { sample(Double($0), 75) }
    let now = t0.addingTimeInterval(3600)
    let series = try #require(HistorySeries.build(samples: samples, window: 4 * 3600, now: now, points: 5))
    #expect(series.start == now.addingTimeInterval(-4 * 3600))
    #expect(series.level[0...2].allSatisfy { $0.isNaN })
    #expect(Array(series.level[3...4]) == [75, 75])
    #expect(HistorySeries.build(samples: samples, window: 59 * 60, now: now, points: 5) == nil)
}

@Test("A value measured late is not drawn earlier")
func lateMeasurement() throws {
    let samples = (0..<60).map { sample(Double($0), temp: nil) } + (60...120).map { sample(Double($0), temp: 35) }
    let series = try #require(HistorySeries.build(samples: samples, window: 2 * 3600,
                                                  now: t0.addingTimeInterval(7200), points: 5))
    #expect(series.temperature[0].isNaN && series.temperature[1].isNaN)
    #expect(series.temperature[3] == 35 && series.temperature[4] == 35)
}

@Test("The limit is given only when it was the same for the whole stretch")
func limitOverTime() throws {
    let now = t0.addingTimeInterval(3600)
    let steady = (0...60).map { sample(Double($0), limit: 80) }
    let steadySeries = try #require(HistorySeries.build(samples: steady, window: 3600, now: now, points: 5))
    #expect(steadySeries.limit == 80)
    let changed = (0..<30).map { sample(Double($0), limit: 100) } + (30...60).map { sample(Double($0), limit: 80) }
    let changedSeries = try #require(HistorySeries.build(samples: changed, window: 3600, now: now, points: 5))
    #expect(changedSeries.limit == nil)
}

@Test("A value that was never measured gives an empty line, not zeros")
func missingSeries() throws {
    let samples = (0...60).map { sample(Double($0), temp: nil, charger: nil) }
    let series = try #require(HistorySeries.build(samples: samples, window: 3600,
                                                  now: t0.addingTimeInterval(3600), points: 10))
    #expect(series.temperature.isEmpty)
    #expect(series.chargerWatts.isEmpty)
    #expect(series.macWatts.count == 10 && series.macWatts.allSatisfy { $0.isFinite })
}

@Test("A wild sensor value is clamped, never a crash")
func wildValues() {
    let wild = HistorySample(time: t0, percent: 500, isPluggedIn: true, isCharging: false, temperatureC: -1e30,
                             chargerWatts: 1e30, macWatts: -5, limit: 999)
    let back = HistorySample(encoded: wild.encoded())
    #expect(back?.percent == 255 && back?.limit == 255)
    #expect(back?.chargerWatts == 6553.5 && back?.macWatts == 0)
    #expect(back?.temperatureC == -3276.8)
}

@Test("Thinning leaves a file alone when it holds records this build cannot read")
func thinningKeepsUnknownRecords() throws {
    let url = temporaryFile()
    defer { try? FileManager.default.removeItem(at: url) }
    let store = HistoryStore(file: url)
    let now = t0.addingTimeInterval(100 * 24 * 3600)
    (0..<180).forEach { store.append(sample(Double($0))) }
    // A record from a newer version: same size, another version byte.
    var future = sample(200).encoded()
    future[13] = 2
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: future)
    try handle.close()
    let before = try Data(contentsOf: url)
    #expect(store.thin(now: now) == 0)
    let after = try Data(contentsOf: url)
    #expect(after == before)
    #expect(store.samples().count == 180)
}

// MARK: S-034

@Test("One health snapshot is saved per day, at most")
func healthOncePerDay() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let morning = Date(timeIntervalSince1970: TimeInterval(1_800_000_000 - 1_800_000_000 % 86_400 + 8 * 3600))
    #expect(HistoryRules.shouldRecordHealth(last: nil, now: morning, calendar: calendar))
    #expect(!HistoryRules.shouldRecordHealth(last: morning, now: morning.addingTimeInterval(10 * 3600), calendar: calendar))
    #expect(HistoryRules.shouldRecordHealth(last: morning, now: morning.addingTimeInterval(17 * 3600), calendar: calendar))
    #expect(!HistoryRules.shouldRecordHealth(last: morning, now: morning.addingTimeInterval(-86_400), calendar: calendar))

    let url = temporaryFile()
    defer {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(atPath: url.path + "-health")
    }
    let store = HistoryStore(file: url)
    #expect(store.appendHealth(HealthSnapshot(time: morning, healthPercent: 82, cycles: 274), calendar: calendar))
    #expect(!store.appendHealth(HealthSnapshot(time: morning.addingTimeInterval(3600), healthPercent: 82, cycles: 274), calendar: calendar))
    #expect(store.appendHealth(HealthSnapshot(time: morning.addingTimeInterval(86_400), healthPercent: 81, cycles: 275), calendar: calendar))
    #expect(store.healthSnapshots() == [HealthSnapshot(time: morning, healthPercent: 82, cycles: 274),
                                         HealthSnapshot(time: morning.addingTimeInterval(86_400), healthPercent: 81, cycles: 275)])
}

@Test("Health is drawn where it was measured: each point shows the latest snapshot before it")
func healthLine() {
    let day = 86_400.0
    let start = t0, end = t0.addingTimeInterval(4 * day)
    let snapshots = [HealthSnapshot(time: t0.addingTimeInterval(-10 * day), healthPercent: 84, cycles: 260),
                     HealthSnapshot(time: t0.addingTimeInterval(3 * day), healthPercent: 82, cycles: 275)]
    // Five points, one a day. The old figure holds until the new one is measured on day 3.
    #expect(HistorySeries.healthLine(snapshots, start: start, end: end, points: 5) == [84, 84, 84, 82, 82])
    // With nothing before the chart, the days before the first snapshot are a gap.
    let line = HistorySeries.healthLine([snapshots[1]], start: start, end: end, points: 5)
    #expect(line[0...2].allSatisfy { $0.isNaN } && Array(line[3...4]) == [82, 82])
    #expect(HistorySeries.healthLine([], start: start, end: end, points: 5).isEmpty)
}
