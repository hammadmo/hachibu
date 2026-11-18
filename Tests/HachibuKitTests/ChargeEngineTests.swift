import Foundation
import Testing
@testable import HachibuKit

private func inputs(_ percent: Int, attached: Bool = true, limit: Int = 80, range: Int = 0,
                    helper: Bool = true) -> ChargeInputs {
    ChargeInputs(percent: percent, chargerAttached: attached, limit: limit, sailingRange: range, helperRunning: helper)
}

// MARK: S-020 Top Up

@Test("Top Up asks for no limit, and ends at 100%, on unplug, or on Stop; the limit then returns")
func topUpLifecycle() {
    var engine = ChargeEngine()
    #expect(engine.startTopUp(inputs(80)) == nil)
    #expect(engine.step(inputs(85)) == ChargePlan(mode: .toppingUp, limit: 100))
    #expect(engine.step(inputs(100)) == ChargePlan(mode: .normal, limit: 80))
    #expect(engine.lastEnd == .reachedFull)

    engine = ChargeEngine()
    _ = engine.startTopUp(inputs(80))
    #expect(engine.step(inputs(90, attached: false)) == ChargePlan(mode: .normal, limit: 80))
    #expect(engine.lastEnd == .unplugged)

    engine = ChargeEngine()
    _ = engine.startTopUp(inputs(80))
    engine.stop()
    #expect(engine.step(inputs(90)) == ChargePlan(mode: .normal, limit: 80))
    #expect(engine.lastEnd == .stopped)
}

@Test("Top Up refuses without a charger, when full, or while another mode runs")
func topUpRefusals() {
    var engine = ChargeEngine()
    #expect(engine.startTopUp(inputs(80, attached: false)) != nil)
    #expect(engine.startTopUp(inputs(100)) != nil)
    #expect(engine.mode == .normal)
    #expect(engine.startDischarge(inputs(90)) == nil)
    #expect(engine.startTopUp(inputs(90)) != nil)
    #expect(engine.mode == .discharging)
}

// MARK: S-021 Discharge (rules only; see the story for why there is no button)

@Test("Discharge refuses at or below the limit, without a charger, or without the helper")
func dischargeRefusals() {
    var engine = ChargeEngine()
    #expect(engine.startDischarge(inputs(80)) != nil)
    #expect(engine.startDischarge(inputs(70)) != nil)
    #expect(engine.startDischarge(inputs(90, attached: false)) != nil)
    #expect(engine.startDischarge(inputs(90, helper: false)) != nil)
    #expect(engine.startDischarge(inputs(100, limit: 100)) != nil)
    #expect(engine.mode == .normal)
}

@Test("Discharge stops at the limit, at 20%, on Stop, on unplug, or when the helper is lost")
func dischargeEnds() {
    var engine = ChargeEngine()
    #expect(engine.startDischarge(inputs(90)) == nil)
    #expect(engine.step(inputs(85)) == ChargePlan(mode: .discharging, limit: 80, adapterCut: true))
    #expect(engine.step(inputs(80)).adapterCut == false)
    #expect(engine.lastEnd == .reachedLimit)

    engine = ChargeEngine()
    _ = engine.startDischarge(inputs(30, limit: 20))
    #expect(engine.step(inputs(21, limit: 10)).adapterCut)
    #expect(engine.step(inputs(20, limit: 10)).adapterCut == false)
    #expect(engine.lastEnd == .reachedFloor)

    for (change, reason) in [(inputs(88, attached: false), ModeEnd.unplugged), (inputs(88, helper: false), .helperLost)] {
        engine = ChargeEngine()
        _ = engine.startDischarge(inputs(90))
        #expect(engine.step(change).adapterCut == false)
        #expect(engine.lastEnd == reason)
    }

    engine = ChargeEngine()
    _ = engine.startDischarge(inputs(90))
    engine.stop()
    #expect(engine.step(inputs(88)) == ChargePlan(mode: .normal, limit: 80))
    #expect(engine.lastEnd == .stopped)
}

@Test("Before sleep the charger is reconnected in every mode")
func sleepReconnects() {
    var engine = ChargeEngine()
    _ = engine.startDischarge(inputs(90))
    #expect(engine.step(inputs(88)).adapterCut)
    #expect(engine.planForSleep(inputs(88)).adapterCut == false)
    #expect(engine.mode == .discharging)
    #expect(ChargeEngine().planForSleep(inputs(88)).adapterCut == false)
}

@Test("The helper reconnects the charger after 30 silent seconds, and not before")
func watchdog() {
    let heard = Date(timeIntervalSince1970: 1_000)
    #expect(!AdapterWatchdog.shouldRestore(adapterCut: true, lastHeard: heard, now: heard.addingTimeInterval(29)))
    #expect(AdapterWatchdog.shouldRestore(adapterCut: true, lastHeard: heard, now: heard.addingTimeInterval(30)))
    #expect(!AdapterWatchdog.shouldRestore(adapterCut: false, lastHeard: heard, now: heard.addingTimeInterval(300)))
}

// MARK: S-022 Sailing

@Test("With limit 80 and range 5, charging resumes at 75 and stops at 80")
func sailingBand() {
    var engine = ChargeEngine()
    // At the limit: plain holding.
    #expect(engine.step(inputs(80, range: 5)) == ChargePlan(mode: .normal, limit: 80))
    // Drifting down: macOS is asked to hold the level it is at, so nothing charges.
    for level in [79, 78, 77, 76] {
        #expect(engine.step(inputs(level, range: 5)) == ChargePlan(mode: .normal, limit: level, isSailing: true))
    }
    // At the bottom of the range: charge back to the limit, all the way.
    for level in [75, 76, 78, 79] {
        #expect(engine.step(inputs(level, range: 5)) == ChargePlan(mode: .normal, limit: 80))
        #expect(engine.isRecharging)
    }
    #expect(engine.step(inputs(80, range: 5)) == ChargePlan(mode: .normal, limit: 80))
    #expect(!engine.isRecharging)
    #expect(engine.step(inputs(79, range: 5)).isSailing)
}

@Test("Sailing starts from the level it finds, and is off without a range, a helper, or a charger")
func sailingConditions() {
    var engine = ChargeEngine()
    #expect(engine.step(inputs(77, range: 5)) == ChargePlan(mode: .normal, limit: 77, isSailing: true))
    engine = ChargeEngine()
    #expect(engine.step(inputs(70, range: 5)) == ChargePlan(mode: .normal, limit: 80))
    for off in [inputs(77, range: 0), inputs(77, range: 5, helper: false), inputs(77, attached: false, range: 5)] {
        engine = ChargeEngine()
        #expect(engine.step(off) == ChargePlan(mode: .normal, limit: 80))
    }
    // Above the limit (after a Top Up): the limit itself, so macOS brings it down.
    engine = ChargeEngine()
    #expect(engine.step(inputs(95, range: 5)) == ChargePlan(mode: .normal, limit: 80))
    // The range never reaches below 20%.
    engine = ChargeEngine()
    #expect(engine.step(inputs(21, limit: 25, range: 10)) == ChargePlan(mode: .normal, limit: 21, isSailing: true))
    #expect(engine.step(inputs(20, limit: 25, range: 10)) == ChargePlan(mode: .normal, limit: 25))
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
