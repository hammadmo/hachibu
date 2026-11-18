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
    #expect(HistorySeries.build(samples: enough, window: 24 * 3600, now: t0.addingTimeInterval(3600), points: 96) != nil)
}

@Test("The chart starts at the first sample and holds the last value across a gap")
func seriesShape() throws {
    // Two hours at 80%, a three hour gap, then an hour at 60%.
    let samples = (0..<120).map { sample(Double($0), 80) } + (300...360).map { sample(Double($0), 60, temp: nil, limit: 70) }
    let now = t0.addingTimeInterval(360 * 60)
    let series = try #require(HistorySeries.build(samples: samples, window: 24 * 3600, now: now, points: 6))
    #expect(series.start == t0)
    #expect(series.end == now)
    #expect(series.level == [80, 80, 80, 80, 80, 60])
    #expect(series.limit == 70)
    // No temperature after the gap: the last one measured is kept.
    #expect(series.temperature.count == 6 && series.temperature.allSatisfy { abs($0 - 31.2) < 0.001 })
    #expect(series.chargerWatts.count == 6 && series.macWatts.count == 6)
    // Only what is inside the window counts.
    let lastHour = try #require(HistorySeries.build(samples: samples, window: 3600, now: now, points: 4))
    #expect(lastHour.level == [60, 60, 60, 60])
    #expect(lastHour.start == t0.addingTimeInterval(300 * 60))
    #expect(HistorySeries.build(samples: samples, window: 59 * 60, now: now, points: 4) == nil)
}

@Test("A value that was never measured gives an empty line, not zeros")
func missingSeries() throws {
    let samples = (0...60).map { sample(Double($0), temp: nil, charger: nil) }
    let series = try #require(HistorySeries.build(samples: samples, window: 24 * 3600,
                                                  now: t0.addingTimeInterval(3600), points: 10))
    #expect(series.temperature.isEmpty)
    #expect(series.chargerWatts.isEmpty)
    #expect(series.macWatts.count == 10)
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
