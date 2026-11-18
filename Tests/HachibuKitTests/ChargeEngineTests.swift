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
    engine.mode = .calibrating
    #expect(engine.step(inputs(77, range: 5)) == ChargePlan(mode: .calibrating, limit: 100))
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
