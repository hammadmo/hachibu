import Foundation
import Testing
@testable import HachibuKit

private func reading(_ percent: Int, plugged: Bool = true, current: Int = 0, override: Bool = false,
                     charger: Double? = 9.2, system: Double? = 7.2) -> BatteryReading {
    BatteryReading(percent: percent, isPluggedIn: plugged, currentMA: current, voltageMV: 12_000,
                   rawMaxCapacityMAh: 3556, designCapacityMAh: 4382, chargerWatts: charger,
                   systemWatts: system, fullChargeOverride: override)
}

@Test("Status follows the measured current, not the intent")
func statusDerivation() {
    #expect(BatteryStatus.derive(from: reading(60, current: 1800), limit: 80) == .charging)
    #expect(BatteryStatus.derive(from: reading(80), limit: 80) == .holdingAtLimit)
    #expect(BatteryStatus.derive(from: reading(78), limit: 80) == .holdingAtLimit)
    #expect(BatteryStatus.derive(from: reading(60), limit: 80) == .notCharging)
    #expect(BatteryStatus.derive(from: reading(100), limit: nil) == .fullyCharged)
    #expect(BatteryStatus.derive(from: reading(70, plugged: false, current: -900), limit: 80) == .onBattery)
    #expect(BatteryStatus.derive(from: reading(90, current: 1500, override: true), limit: 80) == .fullChargeByMacOS)
}

@Test("Holding at limit is never shown while current flows into the battery")
func neverHoldingWhileCharging() {
    for percent in 0...100 {
        let status = BatteryStatus.derive(from: reading(percent, current: 600), limit: 80)
        #expect(status != .holdingAtLimit)
    }
}

@Test("Holding at limit needs the level near the limit and no power leaving the battery")
func holdingNeedsAgreement() {
    // Far above the limit and not charging is not "holding at 80".
    #expect(BatteryStatus.derive(from: reading(95), limit: 80) == .notCharging)
    #expect(BatteryStatus.derive(from: reading(82), limit: 80) == .holdingAtLimit)
    #expect(BatteryStatus.derive(from: reading(83), limit: 80) == .notCharging)
    // Plugged in but draining is never "holding".
    #expect(BatteryStatus.derive(from: reading(80, current: -1500), limit: 80) == .usingBattery)
    #expect(BatteryStatus.derive(from: reading(95, current: -900), limit: 80) == .usingBattery)
    #expect(BatteryStatus.derive(from: reading(80, current: -BatteryReading.chargingThresholdMA), limit: 80) == .holdingAtLimit)
    #expect(BatteryStatus.usingBattery.detail(for: reading(80, current: -1500)) == "18 W from battery, charger connected")
}

@Test("Current under the threshold is noise, not charging")
func chargingThreshold() {
    #expect(!reading(80, current: BatteryReading.chargingThresholdMA).isCharging)
    #expect(reading(80, current: BatteryReading.chargingThresholdMA + 1).isCharging)
    #expect(!reading(80, plugged: false, current: 500).isCharging)
}

@Test("Health is raw capacity over design capacity, as a whole percent")
func health() {
    #expect(reading(80).healthPercent == 81)
    #expect(BatteryReading(percent: 80, isPluggedIn: true, currentMA: 0).healthPercent == nil)
    #expect(BatteryReading(percent: 80, isPluggedIn: true, currentMA: 0, rawMaxCapacityMAh: 5000,
                           designCapacityMAh: 4382).healthPercent == 100)
}

@Test("The status detail shows measured watts, and a dash when a value is missing")
func statusDetail() {
    #expect(BatteryStatus.holdingAtLimit.detail(for: reading(80)) == "9.2 W from charger")
    #expect(BatteryStatus.charging.detail(for: reading(60, current: 1800, charger: 28.4)) == "28 W from charger")
    #expect(BatteryStatus.charging.detail(for: reading(60, current: 1800, charger: nil)) == "– from charger")
    #expect(BatteryStatus.onBattery.detail(for: reading(70, plugged: false, current: -600, system: 7)) == "7.0 W out")
    #expect(BatteryStatus.onBattery.detail(for: reading(70, plugged: false, current: -600, system: nil)) == "7.2 W out")
}

@Test("The limit's source says who set it")
func limitSource() {
    #expect(LimitState(system: 80, saved: 80).source == .hachibu)
    #expect(LimitState(system: 80, saved: 85).source == .outside)
    #expect(LimitState(system: 80, saved: nil).source == .outside)
    #expect(LimitState(system: nil, saved: 80).source == .none)
    #expect(LimitState(system: 100, saved: 100).system == nil)
    #expect(LimitState(system: nil, saved: nil).valueText == "No limit")
    #expect(LimitState(system: 85, saved: 85).valueText == "85%")
}

@Test("A saved limit that differs from the system's can be restored")
func savedToRestore() {
    #expect(LimitState(system: 80, saved: 85).savedToRestore == 85)
    #expect(LimitState(system: nil, saved: 80).savedToRestore == 80)
    #expect(LimitState(system: 80, saved: 80).savedToRestore == nil)
    #expect(LimitState(system: nil, saved: 100).savedToRestore == nil)
    #expect(LimitState(system: 80, saved: nil).savedToRestore == nil)
}

@Test("Slider values snap to the stops macOS offers")
func stops() {
    #expect(LimitStops.normalized([95, 80, 85, 90, 100, 85]) == [80, 85, 90, 95, 100])
    #expect(LimitStops.normalized([]) == [100])
    #expect(LimitStops.normalized([10, 80, 120]) == [80, 100])
    #expect(LimitStops.snap(87, to: [80, 85, 90, 95, 100]) == 85)
    #expect(LimitStops.snap(20, to: [80, 85, 90, 95, 100]) == 80)
}

@Test("The warning starts after two minutes above the limit while charging, and clears when either stops")
func limitWatch() {
    var watch = LimitWatch()
    let start = Date(timeIntervalSinceReferenceDate: 1000)
    let over = reading(86, current: 1500)
    let step1 = watch.update(reading: over, limit: 80, now: start)
    #expect(!step1)
    #expect(!watch.isWarning)
    let step2 = watch.update(reading: over, limit: 80, now: start.addingTimeInterval(119))
    #expect(!step2)
    let step3 = watch.update(reading: over, limit: 80, now: start.addingTimeInterval(120))
    #expect(step3)
    #expect(watch.isWarning)
    // It fires once, not on every reading.
    let step4 = watch.update(reading: over, limit: 80, now: start.addingTimeInterval(150))
    #expect(!step4)
    #expect(watch.isWarning)
    // Charging stops: the warning clears and the clock starts again.
    let step5 = watch.update(reading: reading(86), limit: 80, now: start.addingTimeInterval(160))
    #expect(!step5)
    #expect(!watch.isWarning)
    let step6 = watch.update(reading: over, limit: 80, now: start.addingTimeInterval(170))
    #expect(!step6)
    #expect(!watch.isWarning)
}

@Test("No warning inside the margin, with no limit, during a top up, or during a full charge by macOS")
func limitWatchQuietCases() {
    let start = Date(timeIntervalSinceReferenceDate: 1000)
    let later = start.addingTimeInterval(600)
    var watch = LimitWatch()
    _ = watch.update(reading: reading(82, current: 1500), limit: 80, now: start)
    let step7 = watch.update(reading: reading(82, current: 1500), limit: 80, now: later)
    #expect(!step7)
    watch = LimitWatch()
    _ = watch.update(reading: reading(95, current: 1500), limit: nil, now: start)
    let step8 = watch.update(reading: reading(95, current: 1500), limit: nil, now: later)
    #expect(!step8)
    watch = LimitWatch()
    _ = watch.update(reading: reading(95, current: 1500), limit: 80, suppressed: true, now: start)
    let step9 = watch.update(reading: reading(95, current: 1500), limit: 80, suppressed: true, now: later)
    #expect(!step9)
    watch = LimitWatch()
    _ = watch.update(reading: reading(95, current: 1500, override: true), limit: 80, now: start)
    let step10 = watch.update(reading: reading(95, current: 1500, override: true), limit: 80, now: later)
    #expect(!step10)
}

@Test("The menu bar mark follows the level and the warning")
func menuBarMark() {
    #expect(MenuBarMark.choose(percent: 80, warning: false) == .level(80))
    #expect(MenuBarMark.choose(percent: 86, warning: true) == .warning(86))
    #expect(MenuBarMark.choose(percent: nil, warning: true) == .unknown)
    #expect(MenuBarMark.level(80).title(showPercentage: true) == "80%")
    #expect(MenuBarMark.level(80).title(showPercentage: false) == nil)
    #expect(MenuBarMark.unknown.title(showPercentage: true) == "–")
}
