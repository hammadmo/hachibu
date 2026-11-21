import Foundation
import Testing
@testable import HachibuKit

private func inputs(_ percent: Int, attached: Bool = true, limit: Int = 80, range: Int = 0,
                    helper: Bool = true) -> ChargeInputs {
    ChargeInputs(percent: percent, chargerAttached: attached, limit: limit, sailingRange: range, helperRunning: helper)
}

// MARK: S-020 Top Up

@Test("Top Up asks for no limit and ends on unplug or on Stop; the limit then returns")
func topUpLifecycle() {
    var engine = ChargeEngine()
    #expect(engine.startTopUp(inputs(80)) == nil)
    #expect(engine.step(inputs(85)) == ChargePlan(mode: .toppingUp, limit: 100))

    #expect(engine.step(inputs(90, attached: false)) == ChargePlan(mode: .normal, limit: 80))
    #expect(engine.lastEnd == .unplugged)

    engine = ChargeEngine()
    _ = engine.startTopUp(inputs(80))
    engine.stop()
    #expect(engine.step(inputs(90)) == ChargePlan(mode: .normal, limit: 80))
    #expect(engine.lastEnd == .stopped)
}

@Test("At 100% a Top Up keeps the battery full until the charger is unplugged")
func topUpStaysFull() {
    var engine = ChargeEngine()
    _ = engine.startTopUp(inputs(95))
    // Giving the limit back at 100% would make macOS drain to it while plugged in.
    #expect(engine.step(inputs(100)) == ChargePlan(mode: .toppingUp, limit: 100, isToppedUp: true))
    #expect(engine.step(inputs(100)) == ChargePlan(mode: .toppingUp, limit: 100, isToppedUp: true))
    #expect(engine.step(inputs(100, attached: false)) == ChargePlan(mode: .normal, limit: 80))
}

@Test("Top Up refuses without a charger, when full, or while another mode runs")
func topUpRefusals() {
    var engine = ChargeEngine()
    #expect(engine.startTopUp(inputs(80, attached: false)) != nil)
    #expect(engine.startTopUp(inputs(100)) != nil)
    #expect(engine.mode == .normal)
    #expect(engine.startTopUp(inputs(90)) == nil)
    #expect(engine.startTopUp(inputs(90)) != nil)
    #expect(engine.mode == .toppingUp)
}

// MARK: S-022 Sailing

private func plain(_ limit: Int = 80) -> ChargePlan { ChargePlan(mode: .normal, limit: limit) }
private func sail(_ level: Int) -> ChargePlan { ChargePlan(mode: .normal, limit: level, isSailing: true) }

@Test("With limit 80 and range 5, charging resumes at 75 and stops at 80")
func sailingBand() {
    var engine = ChargeEngine()
    #expect(engine.step(inputs(80, range: 5)) == plain())
    // One percent under the limit is still "at the limit".
    #expect(engine.step(inputs(79, range: 5)) == plain())
    // Two under: macOS is asked to hold the level, so nothing charges.
    #expect(engine.step(inputs(78, range: 5)) == sail(78))
    #expect(engine.step(inputs(76, range: 5)) == sail(76))
    // At the bottom of the range: charge back to the limit, all the way.
    for level in [75, 76, 77, 78] {
        #expect(engine.step(inputs(level, range: 5)) == plain())
        #expect(engine.isRecharging)
    }
    // macOS may stop a percent short; that counts as back up.
    #expect(engine.step(inputs(79, range: 5)) == plain())
    #expect(!engine.isRecharging)
    #expect(engine.step(inputs(80, range: 5)) == plain())
    #expect(engine.step(inputs(77, range: 5)) == sail(77))
}

@Test("A flicker of one percent does not ask for a new level")
func sailingIgnoresFlicker() {
    var engine = ChargeEngine()
    #expect(engine.step(inputs(77, range: 5)) == sail(77))
    for level in [78, 77, 76, 77, 78, 77] {
        #expect(engine.step(inputs(level, range: 5)) == sail(77))
    }
    // A real move, either way, is followed. Up, so macOS does not drain to the old level.
    #expect(engine.step(inputs(79, range: 5)) == sail(79))
    #expect(engine.step(inputs(80, range: 5)) == plain())
    // And around the limit there is no swinging between the limit and a hold.
    for level in [79, 80, 79, 80] {
        #expect(engine.step(inputs(level, range: 5)) == plain())
    }
}

@Test("Sailing starts from the level it finds, and is off without a range, a helper, or a limit")
func sailingConditions() {
    var engine = ChargeEngine()
    #expect(engine.step(inputs(77, range: 5)) == sail(77))
    engine = ChargeEngine()
    #expect(engine.step(inputs(70, range: 5)) == plain())
    for off in [inputs(77, range: 0), inputs(77, range: 5, helper: false)] {
        engine = ChargeEngine()
        #expect(engine.step(off) == plain())
    }
    // "No limit" is not sailed under.
    engine = ChargeEngine()
    #expect(engine.step(inputs(95, limit: 100, range: 5)) == plain(100))
    // Above the limit (after a Top Up): the limit itself, so macOS brings it down.
    engine = ChargeEngine()
    #expect(engine.step(inputs(95, range: 5)) == plain())
    // The range never reaches below 20%.
    engine = ChargeEngine()
    #expect(engine.step(inputs(22, limit: 25, range: 10)) == sail(22))
    #expect(engine.step(inputs(20, limit: 25, range: 10)) == plain(25))
}

@Test("Off the charger the held level stays asked for; back on it, the new level is held")
func sailingAcrossUnplug() {
    var engine = ChargeEngine()
    #expect(engine.step(inputs(78, range: 10)) == sail(78))
    // Unplugged and used down to 73: nothing new is asked.
    #expect(engine.step(inputs(76, attached: false, range: 10)) == plain(78))
    #expect(engine.step(inputs(73, attached: false, range: 10)) == plain(78))
    #expect(engine.step(inputs(73, range: 10)) == sail(73))
    // Used below the range while unplugged: charge back to the limit.
    #expect(engine.step(inputs(68, attached: false, range: 10)) == plain())
    #expect(engine.step(inputs(68, range: 10)) == plain())
}

@Test("Sailing does not hold during macOS's own full charge")
func sailingYieldsToFullCharge() {
    var engine = ChargeEngine()
    #expect(engine.step(inputs(77, range: 5)) == sail(77))
    var charging = inputs(79, range: 5)
    charging.macOSFullCharge = true
    #expect(engine.step(charging) == plain())
}

@Test("A hold left by the last run is taken up again")
func sailingAdoptsHold() {
    var engine = ChargeEngine()
    engine.adopt(hold: 76)
    #expect(engine.step(inputs(76, range: 5)) == sail(76))
    #expect(engine.step(inputs(77, range: 5)) == sail(76))
}

@Test("Sailing pauses during Top Up and Calibration")
func sailingPauses() {
    var engine = ChargeEngine()
    #expect(engine.step(inputs(77, range: 5)).isSailing)
    _ = engine.startTopUp(inputs(77, range: 5))
    #expect(engine.step(inputs(77, range: 5)) == ChargePlan(mode: .toppingUp, limit: 100))
    engine.stop()
    #expect(engine.startCalibration(inputs(77, range: 5)) == nil)
    let plan = engine.step(inputs(77, range: 5))
    #expect(plan.mode == .calibrating && !plan.isSailing)
}

// MARK: S-042 Calibration

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

@Test("Calibration drains to 15%, charges to 100%, rests two hours, then gives the limit back")
func calibrationSteps() {
    var engine = ChargeEngine()
    #expect(engine.startCalibration(inputs(80)) == nil)
    #expect(engine.step(inputs(80), now: t0) == ChargePlan(mode: .calibrating, limit: 15, calibration: .draining))
    #expect(engine.step(inputs(16), now: t0) == ChargePlan(mode: .calibrating, limit: 15, calibration: .draining))
    #expect(engine.step(inputs(15), now: t0) == ChargePlan(mode: .calibrating, limit: 100, calibration: .charging))
    #expect(engine.step(inputs(60), now: t0) == ChargePlan(mode: .calibrating, limit: 100, calibration: .charging))
    let full = t0.addingTimeInterval(3 * 3600)
    #expect(engine.step(inputs(100), now: full) == ChargePlan(mode: .calibrating, limit: 100, calibration: .resting))
    #expect(engine.step(inputs(100), now: full.addingTimeInterval(7_199)) == ChargePlan(mode: .calibrating, limit: 100, calibration: .resting))
    #expect(engine.step(inputs(100), now: full.addingTimeInterval(7_200)) == ChargePlan(mode: .normal, limit: 80))
    #expect(engine.lastEnd == .finished)
    #expect(engine.mode == .normal)
}

@Test("Cancel gives the limit back at once; unplugging only makes the step wait")
func calibrationCancelAndUnplug() {
    var engine = ChargeEngine()
    _ = engine.startCalibration(inputs(80))
    _ = engine.step(inputs(50), now: t0)
    // Unplugged at 50% and used down to 40%: still draining, nothing new asked.
    #expect(engine.step(inputs(40, attached: false), now: t0)
        == ChargePlan(mode: .calibrating, limit: 15, calibration: .draining, isWaitingForCharger: true))
    // Even at 15% off the charger the step does not advance: the drain must be macOS's, on AC.
    #expect(engine.step(inputs(15, attached: false), now: t0).calibration == .draining)
    #expect(engine.step(inputs(40), now: t0) == ChargePlan(mode: .calibrating, limit: 15, calibration: .draining))
    engine.stop()
    #expect(engine.step(inputs(40), now: t0) == ChargePlan(mode: .normal, limit: 80))
    #expect(engine.lastEnd == .stopped)
    #expect(engine.calibrationStep == nil)
}

@Test("A rest that is interrupted starts over, and the two hours count from full again")
func calibrationRestRestarts() {
    var engine = ChargeEngine()
    _ = engine.startCalibration(inputs(10))
    // Already under 15%: straight to charging.
    #expect(engine.step(inputs(10), now: t0).calibration == .charging)
    #expect(engine.step(inputs(100), now: t0).calibration == .resting)
    // Unplugged for a while during the rest and used a little.
    #expect(engine.step(inputs(96, attached: false), now: t0.addingTimeInterval(3_600)).isWaitingForCharger)
    #expect(engine.step(inputs(96), now: t0.addingTimeInterval(3_700)).calibration == .charging)
    let fullAgain = t0.addingTimeInterval(5_000)
    #expect(engine.step(inputs(100), now: fullAgain).calibration == .resting)
    #expect(engine.step(inputs(100), now: fullAgain.addingTimeInterval(7_000)).mode == .calibrating)
    #expect(engine.step(inputs(100), now: fullAgain.addingTimeInterval(7_200)).mode == .normal)
}

@Test("Calibration refuses without the helper, without a charger, or while another mode runs")
func calibrationRefusals() {
    var engine = ChargeEngine()
    #expect(engine.startCalibration(inputs(80, helper: false)) != nil)
    #expect(engine.startCalibration(inputs(80, attached: false)) != nil)
    _ = engine.startTopUp(inputs(80))
    #expect(engine.startCalibration(inputs(80)) != nil)
    #expect(engine.mode == .toppingUp)
}

// MARK: The override between the user's limit and what macOS was asked for

@Test("A Top Up remembers the user's limit until macOS has it back")
func overrideAroundTopUp() {
    var override = LimitOverride.none
    #expect(override.follow(wanted: nil, userLimit: 80) == nil)
    // Top Up: ask for no limit, remember 80.
    #expect(override.follow(wanted: 100, userLimit: 80) == 100)
    #expect(override == .holding(limit: 100, user: 80))
    #expect(override.userLimit(system: 100) == 80)
    #expect(override.follow(wanted: 100, userLimit: 80) == nil)
    // Over: ask for 80 again. Until macOS confirms, 80 is still remembered.
    #expect(override.follow(wanted: nil, userLimit: 80) == 80)
    #expect(override == .restoring(user: 80))
    #expect(override.userLimit(system: 100) == 80)
    #expect(override.follow(wanted: nil, userLimit: 80) == nil)
    override.confirmed()
    #expect(override == .none)
    #expect(override.userLimit(system: 80) == 80)
}

@Test("A restore that failed is asked again only when a retry is due, and the user's limit is never forgotten")
func overrideRetriesRestore() {
    var override = LimitOverride.restoring(user: 80)
    #expect(override.follow(wanted: nil, userLimit: 80) == nil)
    #expect(override.follow(wanted: nil, userLimit: 80, retryDue: true) == 80)
    #expect(override == .restoring(user: 80))
    // macOS still shows the Top Up's "no limit": the user's limit is still 80.
    #expect(override.userLimit(system: 100) == 80)
}

@Test("Sailing moves its hold without losing the user's limit")
func overrideWhileSailing() {
    var override = LimitOverride.none
    #expect(override.follow(wanted: 77, userLimit: 80) == 77)
    #expect(override.follow(wanted: 75, userLimit: 80) == 75)
    #expect(override == .holding(limit: 75, user: 80))
    // A Top Up on top of sailing still goes back to 80, not to the hold.
    #expect(override.follow(wanted: 100, userLimit: 80) == 100)
    #expect(override.follow(wanted: nil, userLimit: 80) == 80)
    // A new hold while the restore is pending.
    #expect(override.follow(wanted: 78, userLimit: 80) == 78)
    #expect(override == .holding(limit: 78, user: 80))
    // Confirming a hold changes nothing: it is still an override.
    override.confirmed()
    #expect(override == .holding(limit: 78, user: 80))
}

@Test("A limit changed outside Hachibu during a mode ends the override and is left alone")
func overrideSeesOutsideChange() {
    var override = LimitOverride.holding(limit: 75, user: 80)
    let seen1 = override.observe(system: 75)
    #expect(!seen1)
    #expect(override == .holding(limit: 75, user: 80))
    let seen2 = override.observe(system: 90)
    #expect(seen2)
    #expect(override == .none)
    #expect(override.userLimit(system: 90) == 90)
    // While restoring, seeing the user's limit is as good as a confirmation.
    override = .restoring(user: 80)
    let seen3 = override.observe(system: 100)
    #expect(!seen3)
    #expect(override == .restoring(user: 80))
    let seen4 = override.observe(system: 80)
    #expect(!seen4)
    #expect(override == .none)
}

// MARK: S-040 Heat protection

private func hot(_ percent: Int, _ temperature: Double?, attached: Bool = true, limit: Int = 80, threshold: Int? = 40,
                 helper: Bool = true, fullCharge: Bool = false) -> ChargeInputs {
    ChargeInputs(percent: percent, chargerAttached: attached, limit: limit, helperRunning: helper,
                 macOSFullCharge: fullCharge, temperatureC: temperature, heatThreshold: threshold)
}

private func paused(_ level: Int, mode: ChargeMode = .normal) -> ChargePlan {
    ChargePlan(mode: mode, limit: level, isPausedForHeat: true)
}

/// An engine that has already been over 40 °C for a minute.
private func hotEngine(_ percent: Int, topUp: Bool = false) -> ChargeEngine {
    var engine = ChargeEngine()
    if topUp { _ = engine.startTopUp(hot(percent, 35)) }
    _ = engine.step(hot(percent, 41), now: t0)
    _ = engine.step(hot(percent, 41), now: t0.addingTimeInterval(60))
    return engine
}

@Test("Charging pauses only after a minute above the threshold, and resumes 2 °C below it")
func heatPausesAndResumes() {
    var engine = ChargeEngine()
    #expect(engine.step(hot(60, 39.5), now: t0) == plain())
    #expect(engine.step(hot(60, 40.0), now: t0) == plain())
    // Above 40, but only just now: not yet.
    #expect(engine.step(hot(60, 40.1), now: t0) == plain())
    #expect(engine.step(hot(60, 41), now: t0.addingTimeInterval(59)) == plain())
    // A minute on: hold one percent above the level.
    #expect(engine.step(hot(60, 41), now: t0.addingTimeInterval(60)) == paused(61))
    // Cooling, but not by two degrees yet: still paused.
    #expect(engine.step(hot(60, 39.0), now: t0.addingTimeInterval(300)) == paused(61))
    #expect(engine.step(hot(60, 38.1), now: t0.addingTimeInterval(320)) == paused(61))
    #expect(engine.step(hot(60, 38.0), now: t0.addingTimeInterval(340)) == plain())
    #expect(engine.step(hot(61, 39.9), now: t0.addingTimeInterval(360)) == plain())
}

@Test("A spike that cools again before a minute starts nothing")
func heatIgnoresSpikes() {
    var engine = ChargeEngine()
    #expect(engine.step(hot(60, 42), now: t0) == plain())
    #expect(engine.step(hot(60, 39), now: t0.addingTimeInterval(40)) == plain())
    // Hot again: the minute starts over.
    #expect(engine.step(hot(60, 42), now: t0.addingTimeInterval(70)) == plain())
    #expect(engine.step(hot(60, 42), now: t0.addingTimeInterval(125)) == plain())
    #expect(engine.step(hot(60, 42), now: t0.addingTimeInterval(130)) == paused(61))
}

private func recorded(_ secondsAgo: TimeInterval, _ temperature: Double?) -> HistorySample {
    HistorySample(time: t0.addingTimeInterval(-secondsAgo), percent: 60, isPluggedIn: true, isCharging: true,
                  temperatureC: temperature, limit: 80)
}

@Test("The time above the threshold is read from History: recent, hot, and unbroken")
func heatStretchFromHistory() {
    func since(_ samples: [HistorySample]) -> TimeInterval? {
        ChargeEngine.hotSince(in: samples, threshold: 40, now: t0).map { t0.timeIntervalSince($0) }
    }
    #expect(since([]) == nil)
    // Hot for the last four samples; the cooler one before them ends the stretch.
    #expect(since([recorded(300, 41), recorded(240, 39.5), recorded(180, 40.4), recorded(120, 41), recorded(60, 42), recorded(5, 42)]) == 180)
    // Order on disk does not matter.
    #expect(since([recorded(5, 42), recorded(120, 41), recorded(60, 42)]) == 120)
    // Exactly at the threshold is not above it.
    #expect(since([recorded(60, 42), recorded(5, 40.0)]) == nil)
    // The newest sample is too old to say anything about now.
    #expect(since([recorded(400, 42), recorded(300, 42)]) == nil)
    // A gap in the record ends the stretch, and so does a sample with no temperature.
    #expect(since([recorded(600, 42), recorded(120, 42), recorded(60, 42)]) == 120)
    #expect(since([recorded(180, 42), recorded(120, nil), recorded(60, 42)]) == 60)
    // A sample from after "now" (a clock set back) is left out.
    #expect(since([recorded(-30, 42), recorded(60, 41)]) == 60)
}

@Test("A battery that was hot before a restart is paused on the first reading, not a minute later")
func heatCarriesOverARestart() {
    var fresh = ChargeEngine()
    #expect(fresh.step(hot(60, 42), now: t0) == plain())

    var reopened = ChargeEngine()
    reopened.adoptHeat(since: t0.addingTimeInterval(-90))
    #expect(reopened.step(hot(60, 42), now: t0) == paused(61))

    // Hot for only twenty seconds before the restart: the rest of the minute is still waited.
    var brief = ChargeEngine()
    brief.adoptHeat(since: t0.addingTimeInterval(-20))
    #expect(brief.step(hot(60, 42), now: t0) == plain())
    #expect(brief.step(hot(60, 42), now: t0.addingTimeInterval(40)) == paused(61))

    // Cool by the time it reopens: what was recorded counts for nothing.
    var cooled = ChargeEngine()
    cooled.adoptHeat(since: t0.addingTimeInterval(-90))
    #expect(cooled.step(hot(60, 39), now: t0) == plain())
    #expect(cooled.step(hot(60, 42), now: t0.addingTimeInterval(10)) == plain())

    // A reading taken before the record is read does not hide the earlier start.
    var late = ChargeEngine()
    #expect(late.step(hot(60, 42), now: t0) == plain())
    late.adoptHeat(since: t0.addingTimeInterval(-90))
    #expect(late.step(hot(60, 42), now: t0.addingTimeInterval(1)) == paused(61))
}

@Test("The hold is never below the battery's level, and one percent of climb asks for nothing new")
func heatNeverDrains() {
    var engine = hotEngine(60)
    let later = t0.addingTimeInterval(400)
    #expect(engine.step(hot(60, 41), now: later) == paused(61))
    // macOS is slow to act and the level climbs a percent: still inside the hold.
    #expect(engine.step(hot(61, 41), now: later) == paused(61))
    // Past the hold: move it, again with a percent of room.
    #expect(engine.step(hot(62, 41), now: later) == paused(63))
    // A real drop is followed down; one or two percent is not.
    #expect(engine.step(hot(61, 41), now: later) == paused(63))
    #expect(engine.step(hot(60, 41), now: later) == paused(61))
}

@Test("A pause also holds during a Top Up, and the Top Up continues when the battery has cooled")
func heatDuringTopUp() {
    var engine = hotEngine(88, topUp: true)
    let later = t0.addingTimeInterval(400)
    #expect(engine.step(hot(88, 41), now: later) == paused(89, mode: .toppingUp))
    #expect(engine.mode == .toppingUp)
    #expect(engine.step(hot(88, 37.5), now: later) == ChargePlan(mode: .toppingUp, limit: 100))
}

@Test("Heat protection does nothing when the plan would not charge, when it is off, or without the helper")
func heatLeavesTheRestAlone() {
    let later = t0.addingTimeInterval(400)
    // At the limit nothing charges, so nothing is asked.
    var engine = hotEngine(80)
    #expect(engine.step(hot(80, 45), now: later) == plain())
    // Off the charger.
    engine = hotEngine(60)
    #expect(engine.step(hot(60, 45, attached: false), now: later) == plain())
    // macOS's own full charge cannot be paused.
    engine = hotEngine(90)
    #expect(engine.step(hot(90, 45, fullCharge: true), now: later) == plain())
    // Switched off, no temperature, no helper.
    engine = hotEngine(60)
    #expect(engine.step(hot(60, 45, threshold: nil), now: later) == plain())
    engine = hotEngine(60)
    #expect(engine.step(hot(60, nil), now: later) == plain())
    engine = hotEngine(60)
    #expect(engine.step(hot(60, 45, helper: false), now: later) == plain())
    // Too low to hold: charging is more important.
    engine = hotEngine(12)
    #expect(engine.step(hot(12, 45), now: later) == plain())
    // One under the limit: the hold cannot pass the limit itself.
    engine = hotEngine(79)
    #expect(engine.step(hot(79, 45), now: later) == paused(80))
}

@Test("Heat protection takes over from sailing and gives back to it")
func heatAndSailing() {
    var engine = ChargeEngine()
    var reading = hot(77, 35)
    reading.sailingRange = 5
    #expect(engine.step(reading, now: t0) == sail(77))
    // Recharging from the bottom of the range, and it gets hot on the way up.
    reading.percent = 75
    #expect(engine.step(reading, now: t0) == plain())
    reading.percent = 76
    reading.temperatureC = 42
    #expect(engine.step(reading, now: t0.addingTimeInterval(10)) == plain())
    #expect(engine.step(reading, now: t0.addingTimeInterval(200)) == paused(77))
    reading.temperatureC = 37
    #expect(engine.step(reading, now: t0.addingTimeInterval(300)) == plain())
}

// MARK: S-042, what the review found

@Test("A step that stops one percent short still completes, after half an hour")
func calibrationNearTargets() {
    var engine = ChargeEngine()
    _ = engine.startCalibration(inputs(40))
    #expect(engine.step(inputs(16), now: t0).calibration == .draining)
    #expect(engine.step(inputs(16), now: t0.addingTimeInterval(1_799)).calibration == .draining)
    #expect(engine.step(inputs(16), now: t0.addingTimeInterval(1_800)).calibration == .charging)
    let charging = t0.addingTimeInterval(20_000)
    #expect(engine.step(inputs(99), now: charging).calibration == .charging)
    #expect(engine.step(inputs(99), now: charging.addingTimeInterval(1_800)).calibration == .resting)
    // Passing through 16% on the way down is not "stuck at 16".
    engine = ChargeEngine()
    _ = engine.startCalibration(inputs(40))
    _ = engine.step(inputs(17), now: t0)
    #expect(engine.step(inputs(16), now: t0.addingTimeInterval(4_000)).calibration == .draining)
}

@Test("A step that takes more than twelve hours ends the calibration and gives the limit back")
func calibrationTimesOut() {
    var engine = ChargeEngine()
    _ = engine.startCalibration(inputs(80))
    #expect(engine.step(inputs(80), now: t0).calibration == .draining)
    #expect(engine.step(inputs(40), now: t0.addingTimeInterval(12 * 3600)).calibration == .draining)
    #expect(engine.step(inputs(40), now: t0.addingTimeInterval(12 * 3600 + 1)) == ChargePlan(mode: .normal, limit: 80))
    #expect(engine.lastEnd == .timedOut)
    // Waiting for a charger that never comes back counts too.
    engine = ChargeEngine()
    _ = engine.startCalibration(inputs(80))
    _ = engine.step(inputs(80), now: t0)
    #expect(engine.step(inputs(70, attached: false), now: t0.addingTimeInterval(13 * 3600)).mode == .normal)
}

@Test("Only time at full on the charger counts as rest")
func calibrationRestCountsChargerTime() {
    var engine = ChargeEngine()
    _ = engine.startCalibration(inputs(10))
    _ = engine.step(inputs(10), now: t0)
    #expect(engine.step(inputs(100), now: t0).calibration == .resting)
    // An hour of rest, then off the charger for three hours without losing a percent.
    #expect(engine.step(inputs(100), now: t0.addingTimeInterval(3_600)).calibration == .resting)
    #expect(engine.step(inputs(100, attached: false), now: t0.addingTimeInterval(3_700)).isWaitingForCharger)
    #expect(engine.step(inputs(100, attached: false), now: t0.addingTimeInterval(14_000)).mode == .calibrating)
    // Back on the charger: the hour so far stands, the three hours away do not count.
    #expect(engine.step(inputs(100), now: t0.addingTimeInterval(14_020)).mode == .calibrating)
    #expect(engine.rested < 3_800)
    #expect(engine.step(inputs(100), now: t0.addingTimeInterval(14_020 + 3_600)).mode == .normal)
    #expect(engine.lastEnd == .finished)
}
