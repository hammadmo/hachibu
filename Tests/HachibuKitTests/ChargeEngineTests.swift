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
    #expect(engine.startTopUp(inputs(90)) == nil)
    #expect(engine.startTopUp(inputs(90)) != nil)
    #expect(engine.mode == .toppingUp)
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
