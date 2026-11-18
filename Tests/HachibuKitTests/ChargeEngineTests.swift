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
