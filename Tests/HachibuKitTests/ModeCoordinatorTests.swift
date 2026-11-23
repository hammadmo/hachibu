import Foundation
import Testing
@testable import HachibuKit

// Scenarios for what a mode does to the limit. Each is a row from the fix
// log or from an independent review: they used to be provable only by a
// real run on a Mac.

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func battery(_ percent: Int, attached: Bool = true, range: Int = 0, helper: Bool = true,
                     temperature: Double? = nil, threshold: Int? = nil) -> ChargeInputs {
    ChargeInputs(percent: percent, chargerAttached: attached, limit: 0, sailingRange: range, helperRunning: helper,
                 temperatureC: temperature, heatThreshold: threshold)
}

/// A coordinator and the Mac it steers: what macOS holds, and what is written down.
private struct Rig {
    var modes = ModeCoordinator()
    var system = 80
    var record: ModeRecord?
    var asked: [Int] = []
    var notices: [ModeNotice] = []
    var limitProblem: String?
    var now = t0

    mutating func apply(_ effects: [ModeEffect]) {
        for effect in effects {
            switch effect {
            case .ask(let limit): asked.append(limit)
            case .write(let written): record = written
            case .notify(let notice): notices.append(notice)
            case .limitProblem(let text): limitProblem = text
            case .refreshHelper: break
            }
        }
    }

    /// One reading, with nothing under way.
    mutating func read(_ reading: ChargeInputs, own: Bool = true) {
        apply(modes.observed(system: system, isMacOSFullCharge: false))
        apply(modes.reading(reading, system: system, limitIsOwn: own, canAsk: true, now: now))
    }

    /// macOS takes the last limit asked for.
    mutating func held() {
        system = asked.last ?? system
        apply(modes.modeRequestSettled(.held, now: now))
    }

    mutating func failed(_ outcome: LimitSetter.Outcome = .notConfirmed) {
        apply(modes.modeRequestSettled(outcome, now: now))
    }
}

@Test("A Top Up asks for no limit, writes it down, and erases the note only when the limit is confirmed back")
func topUpRecord() {
    var rig = Rig()
    rig.modes.toggleTopUp(battery(80), system: 80, limitIsOwn: true)
    rig.read(battery(80))
    #expect(rig.asked == [100])
    #expect(rig.record == ModeRecord(asked: 100, user: 80, isSailingHold: false))
    rig.held()
    #expect(rig.modes.userLimit(system: rig.system) == 80)
    // Stop: 80 is asked for again, and the note stays until macOS has it.
    rig.modes.toggleTopUp(battery(90), system: rig.system, limitIsOwn: false)
    rig.read(battery(90))
    #expect(rig.asked == [100, 80])
    #expect(rig.record == ModeRecord(asked: 100, user: 80, isSailingHold: false))
    #expect(rig.modes.isOverriding)
    rig.held()
    #expect(rig.record == nil)
    #expect(!rig.modes.isOverriding)
}

@Test("When putting the limit back fails, it is asked again a minute later and never forgotten")
func restoreRetries() {
    var rig = Rig()
    rig.modes.toggleTopUp(battery(80), system: 80, limitIsOwn: true)
    rig.read(battery(80)); rig.held()
    rig.modes.toggleTopUp(battery(90), system: rig.system, limitIsOwn: false)
    rig.read(battery(90))
    rig.failed(.notAccepted(viaHelper: true))
    #expect(rig.limitProblem?.contains("not back yet") == true)
    #expect(rig.modes.userLimit(system: 100) == 80)
    // Not yet a minute: nothing is asked.
    rig.now = t0.addingTimeInterval(59)
    rig.read(battery(90))
    #expect(rig.asked == [100, 80])
    rig.now = t0.addingTimeInterval(60)
    rig.read(battery(90))
    #expect(rig.asked == [100, 80, 80])
    rig.held()
    #expect(rig.limitProblem == nil)
    #expect(rig.record == nil)
}

@Test("A crash after a failed restore: the next launch finds the note and puts the limit back")
func crashAfterFailedRestore() {
    // A calibration is draining; Stop; the restore fails; the app dies.
    var rig = Rig()
    #expect(rig.modes.startCalibration(battery(60), system: 80, limitIsOwn: true) == nil)
    rig.read(battery(60)); rig.held()
    #expect(rig.system == 15)
    rig.modes.stop()
    rig.read(battery(60))
    rig.failed()
    let left = rig.record
    #expect(left == ModeRecord(asked: 15, user: 80, isSailingHold: false))

    // A new process: the saved limit is 80, macOS still holds 15.
    var next = Rig(system: 15, record: left)
    next.apply(next.modes.launched(record: left, system: 15, saved: 80, sailingRange: 0, now: t0))
    #expect(next.modes.override == .restoring(user: 80))
    #expect(next.modes.problem?.contains("being put back") == true)
    next.read(battery(60), own: false)
    #expect(next.asked == [80])
    next.held()
    #expect(next.record == nil)
    // The notice goes away once it is no longer true.
    #expect(next.modes.problem == nil)
}

@Test("The launch restore puts back the limit the mode replaced, even with nothing saved")
func launchRestoresWhatWasReplaced() {
    // Saved 70, but macOS held an outside 85 when the calibration began.
    let left = ModeRecord(asked: 15, user: 85, isSailingHold: false)
    var rig = Rig(system: 15, record: left)
    rig.apply(rig.modes.launched(record: left, system: 15, saved: 70, sailingRange: 0, now: t0))
    rig.read(battery(60), own: false)
    #expect(rig.asked == [85])
    // Never set a limit in Hachibu at all.
    rig = Rig(system: 15, record: left)
    rig.apply(rig.modes.launched(record: left, system: 15, saved: nil, sailingRange: 0, now: t0))
    rig.read(battery(60), own: false)
    #expect(rig.asked == [85])
}

@Test("A launch leaves alone a limit that is not exactly what Hachibu asked for")
func launchLeavesOutsideLimits() {
    let left = ModeRecord(asked: 15, user: 80, isSailingHold: false)
    // Someone set 60 since: not Hachibu's leftover.
    var rig = Rig(system: 60, record: left)
    rig.apply(rig.modes.launched(record: left, system: 60, saved: 80, sailingRange: 0, now: t0))
    #expect(!rig.modes.isOverriding)
    #expect(rig.record == nil)
    rig.read(battery(70), own: false)
    #expect(rig.asked.isEmpty)
    // A sailing note, but macOS holds a different level: an outside limit.
    let sail = ModeRecord(asked: 77, user: 80, isSailingHold: true)
    rig = Rig(system: 78, record: sail)
    rig.apply(rig.modes.launched(record: sail, system: 78, saved: 80, sailingRange: 5, now: t0))
    #expect(!rig.modes.isOverriding && rig.record == nil)
    // Exactly the level written down: sailing is taken up again, nothing asked.
    rig = Rig(system: 77, record: sail)
    rig.apply(rig.modes.launched(record: sail, system: 77, saved: 80, sailingRange: 5, now: t0))
    #expect(rig.modes.override == .holding(limit: 77, user: 80))
    rig.read(battery(77, range: 5), own: false)
    #expect(rig.asked.isEmpty && rig.modes.isSailing)
}

@Test("A limit changed outside Hachibu during a mode ends the mode and is never written over")
func outsideChange() {
    var rig = Rig()
    rig.read(battery(77, range: 5))
    #expect(rig.asked == [77] && rig.record == ModeRecord(asked: 77, user: 80, isSailingHold: true))
    rig.held()
    // System Settings: 90.
    rig.system = 90
    rig.read(battery(77, range: 5), own: false)
    #expect(!rig.modes.isOverriding && !rig.modes.isSailing)
    #expect(rig.record == nil)
    #expect(rig.asked == [77])
    #expect(rig.modes.userLimit(system: 90) == 90)
    // And sailing does not start again under a limit that is not Hachibu's.
    rig.read(battery(76, range: 5), own: false)
    #expect(rig.asked == [77])
}

@Test("During macOS's own full charge a different reported limit is not taken for an outside change")
func fullChargeIsNotAnOutsideChange() {
    var rig = Rig()
    rig.modes.toggleTopUp(battery(80), system: 80, limitIsOwn: true)
    rig.read(battery(80)); rig.held()
    rig.apply(rig.modes.observed(system: 80, isMacOSFullCharge: true))
    #expect(rig.modes.override == .holding(limit: 100, user: 80))
}

@Test("A limit the user sets during a mode: if it fails, the old limit comes back, not the mode's")
func userLimitDuringMode() {
    var rig = Rig()
    _ = rig.modes.startCalibration(battery(60), system: 80, limitIsOwn: true)
    rig.read(battery(60)); rig.held()
    // The user drags the slider to 70.
    rig.apply(rig.modes.userAsked(system: rig.system))
    #expect(rig.modes.mode == .normal)
    #expect(rig.modes.override == .restoring(user: 80))
    #expect(rig.record == ModeRecord(asked: 15, user: 80, isSailingHold: false))
    // It fails: 80 is asked for again after a minute; 15 does not stay.
    rig.apply(rig.modes.userRequestSettled(accepted: false, now: rig.now))
    rig.now = t0.addingTimeInterval(60)
    rig.read(battery(60), own: false)
    #expect(rig.asked == [15, 80])
    // Had it been held, everything is over at once.
    var other = Rig()
    _ = other.modes.startCalibration(battery(60), system: 80, limitIsOwn: true)
    other.read(battery(60)); other.held()
    other.apply(other.modes.userAsked(system: other.system))
    other.system = 70
    other.apply(other.modes.userRequestSettled(accepted: true, now: other.now))
    #expect(!other.modes.isOverriding && other.record == nil)
}

@Test("A mode's request that fails stops the mode, says why, and asks for the user's limit")
func modeRequestFails() {
    var rig = Rig()
    rig.modes.toggleTopUp(battery(80), system: 80, limitIsOwn: true)
    rig.read(battery(80))
    rig.failed(.notAccepted(viaHelper: false))
    #expect(rig.modes.mode == .normal)
    #expect(rig.modes.problem == "The Top Up was stopped: macOS refused the limit.")
    // macOS never took it and still holds 80: there is nothing to put back.
    rig.read(battery(80))
    #expect(rig.asked == [100])
    #expect(!rig.modes.isOverriding && rig.record == nil)

    // "Not confirmed" can mean it did take: then the user's limit is asked for.
    rig = Rig()
    rig.modes.toggleTopUp(battery(80), system: 80, limitIsOwn: true)
    rig.read(battery(80))
    rig.failed(.notConfirmed)
    rig.system = 100
    rig.read(battery(80), own: false)
    #expect(rig.asked == [100, 80])
    #expect(rig.record == ModeRecord(asked: 100, user: 80, isSailingHold: false))
}

@Test("A sailing hold that does not take pauses sailing for ten minutes")
func sailingHoldFails() {
    var rig = Rig()
    rig.read(battery(77, range: 5))
    rig.failed(.notEnforced)
    #expect(rig.modes.problem?.contains("Sailing is paused") == true)
    #expect(!rig.modes.isSailing)
    // macOS accepted 77 and may enforce it late: 80 is asked for again.
    rig.system = 77
    rig.read(battery(77, range: 5), own: false)
    #expect(rig.asked == [77, 80])
    rig.held()
    rig.now = t0.addingTimeInterval(599)
    rig.read(battery(77, range: 5))
    #expect(rig.asked == [77, 80])
    rig.now = t0.addingTimeInterval(600)
    rig.read(battery(77, range: 5))
    #expect(rig.asked == [77, 80, 77])
    #expect(rig.modes.problem == nil)
}

@Test("Calibration finished is said once, and only when the limit is really back")
func finishedNotice() {
    var rig = Rig()
    _ = rig.modes.startCalibration(battery(10), system: 80, limitIsOwn: true)
    rig.read(battery(10)); rig.held()
    rig.read(battery(100))
    // Two hours at full on the charger.
    rig.now = t0.addingTimeInterval(7_200)
    rig.read(battery(100))
    #expect(rig.modes.mode == .normal)
    #expect(rig.asked == [100, 80])
    #expect(rig.notices.isEmpty)
    rig.failed()
    #expect(rig.notices.isEmpty)
    rig.now = t0.addingTimeInterval(7_260)
    rig.read(battery(100))
    rig.held()
    #expect(rig.notices == [.calibrationFinished(limit: 80)])
    rig.read(battery(99))
    #expect(rig.notices.count == 1)
}

@Test("Nothing is asked while another request is under way")
func waitsForRequests() {
    var rig = Rig()
    rig.modes.toggleTopUp(battery(80), system: 80, limitIsOwn: true)
    rig.apply(rig.modes.reading(battery(80), system: 80, limitIsOwn: true, canAsk: false, now: t0))
    #expect(rig.asked.isEmpty)
    #expect(rig.modes.mode == .toppingUp)
    rig.read(battery(80))
    #expect(rig.asked == [100])
}

@Test("A heat pause is written down like a mode, so a crash does not leave its level behind")
func heatPauseIsRecorded() {
    var rig = Rig()
    let hot = battery(60, temperature: 41, threshold: 40)
    rig.read(hot)
    rig.now = t0.addingTimeInterval(ChargeEngine.heatSustain)
    rig.read(hot)
    #expect(rig.asked == [61])
    #expect(rig.modes.isPausedForHeat)
    #expect(rig.record == ModeRecord(asked: 61, user: 80, isSailingHold: false))
}

@Test("Quitting returns the user's limit to write back and keeps the note; removing the helper ends every mode")
func quitAndRemoval() {
    var rig = Rig()
    rig.modes.toggleTopUp(battery(80), system: 80, limitIsOwn: true)
    rig.read(battery(80)); rig.held()
    #expect(rig.modes.quitting(system: 100) == 80)
    #expect(rig.record == ModeRecord(asked: 100, user: 80, isSailingHold: false))
    var idle = ModeCoordinator()
    #expect(idle.quitting(system: 80) == nil)

    rig = Rig()
    rig.read(battery(77, range: 5)); rig.held()
    let removal = rig.modes.removingHelper(system: 77)
    rig.apply(removal.effects)
    #expect(removal.user == 80)
    #expect(!rig.modes.isSailing && rig.modes.override == .restoring(user: 80))
}

// From the independent review of the refactors (2026-11-19).

@Test("A sailing hold left behind is put back at launch when sailing can no longer take it up")
func sailingLeftoverAtLaunch() {
    // Sailing was switched off, and Hachibu stopped before 80 was confirmed back.
    var rig = Rig()
    rig.system = 72
    let found = ModeRecord(asked: 72, user: 80, isSailingHold: true)
    rig.record = found
    rig.apply(rig.modes.launched(record: found, system: 72, saved: 80, sailingRange: 0, now: rig.now))
    #expect(rig.modes.override == .restoring(user: 80))
    #expect(rig.record == found)
    rig.read(battery(72), own: false)
    #expect(rig.asked == [80])
    rig.held()
    #expect(!rig.modes.isOverriding && rig.record == nil && rig.modes.problem == nil)

    // With sailing still on, it is taken up again and nothing is asked.
    rig = Rig()
    rig.system = 72
    rig.apply(rig.modes.launched(record: found, system: 72, saved: 80, sailingRange: 10, now: rig.now))
    #expect(rig.modes.override == .holding(limit: 72, user: 80) && rig.modes.isSailing)

    // A limit that is not the hold was set elsewhere: left alone, note erased.
    rig = Rig()
    rig.system = 75
    rig.record = found
    rig.apply(rig.modes.launched(record: found, system: 75, saved: 80, sailingRange: 0, now: rig.now))
    #expect(!rig.modes.isOverriding && rig.record == nil && rig.modes.problem == nil)
}

@Test("A limit the user sets during a mode that macOS accepts but enforces late is not undone")
func userLimitAcceptedLate() {
    var rig = Rig()
    rig.read(battery(77, range: 5)); rig.held()
    rig.apply(rig.modes.userAsked(system: rig.system))
    #expect(rig.modes.override == .restoring(user: 80))
    // macOS took 60 but does not report it as enforced yet.
    rig.apply(rig.modes.userRequestSettled(accepted: true, now: rig.now))
    rig.system = 60
    rig.now = t0.addingTimeInterval(120)
    rig.read(battery(77), own: false)
    #expect(rig.asked == [77])
    #expect(!rig.modes.isOverriding && rig.record == nil)
}

@Test("A heat pause that does not take says so, and is not asked for again for ten minutes")
func heatHoldFails() {
    var rig = Rig()
    let hot = battery(60, temperature: 42, threshold: 40)
    rig.read(hot)
    rig.now = t0.addingTimeInterval(ChargeEngine.heatSustain)
    rig.read(hot)
    #expect(rig.asked == [61] && rig.modes.isPausedForHeat)
    rig.failed(.notAccepted(viaHelper: true))
    #expect(rig.modes.problem == "Heat protection is paused for ten minutes: the helper did not answer.")
    #expect(!rig.modes.isPausedForHeat)
    // macOS never took 61: nothing to put back, and nothing asked while it waits.
    rig.now = rig.now.addingTimeInterval(30)
    rig.read(hot)
    rig.now = rig.now.addingTimeInterval(500)
    rig.read(hot)
    #expect(rig.asked == [61])
    // Ten minutes on it is still hot: after the minute again, the pause is asked for.
    rig.now = t0.addingTimeInterval(ChargeEngine.heatSustain + ModeCoordinator.sailingPause)
    rig.read(hot)
    rig.now = rig.now.addingTimeInterval(ChargeEngine.heatSustain)
    rig.read(hot)
    #expect(rig.asked == [61, 61])
    #expect(rig.modes.problem == nil)
}

@Test("Once Hachibu is quitting, a reading asks macOS for nothing")
func quittingAsksNothing() {
    var rig = Rig()
    rig.read(battery(77, range: 5)); rig.held()
    #expect(rig.modes.quitting(system: 77) == 80)
    // The level drops while the limit is being written back.
    rig.apply(rig.modes.reading(battery(74, range: 5), system: 77, limitIsOwn: true, canAsk: true, now: rig.now))
    #expect(rig.asked == [77])
    #expect(rig.record == ModeRecord(asked: 77, user: 80, isSailingHold: true))
}

@Test("A Top Up ends when the charger is unplugged, and the limit comes back")
func topUpUnplugged() {
    var rig = Rig()
    rig.modes.toggleTopUp(battery(80), system: 80, limitIsOwn: true)
    rig.read(battery(80)); rig.held()
    rig.read(battery(95, attached: false), own: false)
    #expect(rig.modes.mode == .normal && rig.asked == [100, 80])
    rig.held()
    #expect(!rig.modes.isOverriding && rig.record == nil)
}

@Test("A limit changed outside Hachibu while a launch restore waits: left alone, note erased")
func outsideChangeDuringLaunchRestore() {
    var rig = Rig()
    rig.system = 15
    let found = ModeRecord(asked: 15, user: 80, isSailingHold: false)
    rig.record = found
    rig.apply(rig.modes.launched(record: found, system: 15, saved: 80, sailingRange: 0, now: rig.now))
    #expect(rig.modes.problem != nil)
    // Someone sets 80 in System Settings before Hachibu's request goes out.
    rig.system = 80
    rig.read(battery(50), own: false)
    #expect(rig.asked.isEmpty && !rig.modes.isOverriding && rig.record == nil && rig.modes.problem == nil)
}

@Test("Top Up finished is said once, when the battery is seen at 100%")
func topUpFinishedNotice() {
    var rig = Rig()
    rig.modes.toggleTopUp(battery(80), system: 80, limitIsOwn: true)
    rig.read(battery(80)); rig.held()
    rig.read(battery(99), own: false)
    #expect(rig.notices.isEmpty)
    rig.read(battery(100), own: false)
    rig.read(battery(100), own: false)
    #expect(rig.notices == [.topUpFinished(limit: 80)])
    // Stopped before it is full: nothing is said.
    var other = Rig()
    other.modes.toggleTopUp(battery(80), system: 80, limitIsOwn: true)
    other.read(battery(80)); other.held()
    other.modes.toggleTopUp(battery(90), system: 100, limitIsOwn: false)
    other.read(battery(90), own: false)
    #expect(other.notices.isEmpty)
}

// From the independent review of M6.

@Test("Top Up finished is not said again when the level dips to 99 and returns, and a new Top Up says it again")
func topUpFinishedOncePerTopUp() {
    var rig = Rig()
    rig.modes.toggleTopUp(battery(80), system: 80, limitIsOwn: true)
    rig.read(battery(80)); rig.held()
    for percent in [100, 99, 100, 99, 100] { rig.read(battery(percent), own: false) }
    #expect(rig.notices == [.topUpFinished(limit: 80)])
    // Stop, the level falls, and a second Top Up fills it again.
    rig.modes.toggleTopUp(battery(100), system: 100, limitIsOwn: false)
    rig.read(battery(100), own: false); rig.held()
    rig.read(battery(97))
    rig.modes.toggleTopUp(battery(97), system: 80, limitIsOwn: true)
    rig.read(battery(97)); rig.held()
    rig.read(battery(100), own: false)
    #expect(rig.notices == [.topUpFinished(limit: 80), .topUpFinished(limit: 80)])
}

@Test("Top Up finished waits for a request under way, and is not said for a Top Up whose request failed")
func topUpFinishedWaits() {
    var rig = Rig()
    rig.modes.toggleTopUp(battery(99), system: 80, limitIsOwn: true)
    rig.read(battery(99))
    // 100% is seen while "no limit" is still being asked for.
    rig.apply(rig.modes.reading(battery(100), system: 80, limitIsOwn: true, canAsk: false, now: rig.now))
    #expect(rig.notices.isEmpty)
    rig.held()
    rig.read(battery(100), own: false)
    #expect(rig.notices == [.topUpFinished(limit: 80)])

    rig = Rig()
    rig.modes.toggleTopUp(battery(99), system: 80, limitIsOwn: true)
    rig.read(battery(99))
    rig.apply(rig.modes.reading(battery(100), system: 80, limitIsOwn: true, canAsk: false, now: rig.now))
    rig.failed(.notAccepted(viaHelper: false))
    rig.read(battery(100))
    #expect(rig.notices.isEmpty && rig.modes.mode == .normal)
}

/// Hachibu reopened inside the sailing range, the level two under the hold
/// it left: the new hold is asked for, never the limit, which would charge
/// the battery until the hold was asked again.
@Test
func launchInsideSailingRangeAsksOnlyForTheHold() {
    let sail = ModeRecord(asked: 68, user: 70, isSailingHold: true)
    var rig = Rig(system: 68, record: sail)
    rig.apply(rig.modes.launched(record: sail, system: 68, saved: 70, sailingRange: 5, now: t0))
    rig.read(battery(66, range: 5), own: false)
    #expect(rig.asked == [66])
    #expect(rig.modes.isSailing)
}

/// Why the monitor waits for the helper's first answer: the same launch
/// taken before it is known to run ends sailing and asks for the limit.
@Test
func launchBeforeTheHelperAnswersWouldAskForTheLimit() {
    #expect(!HelperState.checking.isSettled)
    for state in [HelperState.running, .notInstalled, .needsApproval, .failed("x"), .unavailable("x")] {
        #expect(state.isSettled)
    }
    let sail = ModeRecord(asked: 68, user: 70, isSailingHold: true)
    var rig = Rig(system: 68, record: sail)
    // What the app passes while the helper is not known to run: no range.
    rig.apply(rig.modes.launched(record: sail, system: 68, saved: 70, sailingRange: 0, now: t0))
    rig.read(battery(66, range: 0, helper: false), own: false)
    #expect(rig.asked == [70])
}

/// Until a record is taken up at launch, the hold macOS still reports is
/// not shown or recorded as the user's limit.
@Test
func recordNamesTheUsersLimitBeforeItIsTakenUp() {
    let sail = ModeRecord(asked: 66, user: 70, isSailingHold: true)
    #expect(sail.userLimit(system: 66, saved: 70) == 70)
    // macOS holds something else, or nothing is saved: the record is silent.
    #expect(sail.userLimit(system: 70, saved: 70) == nil)
    #expect(sail.userLimit(system: 66, saved: nil) == nil)
    #expect(sail.userLimit(system: 66, saved: 66) == nil)
    let topUp = ModeRecord(asked: 100, user: 80, isSailingHold: false)
    #expect(topUp.userLimit(system: 100, saved: 80) == 80)
    #expect(topUp.userLimit(system: 80, saved: 80) == nil)
}
