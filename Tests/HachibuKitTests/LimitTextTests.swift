import Foundation
import Testing
@testable import HachibuKit

/// Facts for a limit of 80% set by Hachibu, at rest. Each row changes a few.
private func facts(_ change: (inout LimitFacts) -> Void = { _ in }) -> LimitFacts {
    var facts = LimitFacts()
    facts.limit = LimitState(system: 80, saved: 80)
    facts.sliderValue = 80
    facts.userLimit = 80
    change(&facts)
    return facts
}

@Test("Every sentence under the slider, by what is going on")
func captions() {
    let rows: [(String, LimitFacts)] = [
        ("Set by Hachibu", facts()),
        ("Reading the limit…", facts { $0.hasLoaded = false }),
        ("This version of macOS does not offer a charge limit.", facts { $0.limitSupported = false }),
        ("The limit could not be read. Trying again…", facts { $0.limitKnown = false }),
        ("Set outside Hachibu", facts { $0.limit = LimitState(system: 80, saved: 85) }),
        ("Charging goes to 100%", facts { $0.limit = LimitState(system: nil, saved: nil) }),
        ("No limit. Turned off outside Hachibu", facts { $0.limit = LimitState(system: nil, saved: 80) }),
        ("Applying…", facts { $0.isBusy = true; $0.userRequestPending = true }),
        ("Applying… macOS can take two minutes.", facts { $0.isBusy = true; $0.userRequestPending = true; $0.isWaitingForMacOS = true }),
        ("macOS did not accept this limit. Try again.", facts { $0.applyProblem = "macOS did not accept this limit. Try again." }),
        ("Charging to 100% once. Your limit returns when you unplug.",
         facts { $0.mode = .toppingUp; $0.override = .holding(limit: 100, user: 80) }),
        ("Topped up. Your limit returns when you unplug.",
         facts { $0.mode = .toppingUp; $0.isToppedUp = true; $0.override = .holding(limit: 100, user: 80) }),
        ("Calibrating. Your limit returns when it is done.",
         facts { $0.mode = .calibrating; $0.override = .holding(limit: 15, user: 80) }),
        ("Calibrating. Connect the charger to go on.",
         facts { $0.mode = .calibrating; $0.isWaitingForCharger = true; $0.override = .holding(limit: 15, user: 80) }),
        ("Paused for heat. Charging resumes at 38 °C.",
         facts { $0.isPausedForHeat = true; $0.heatThreshold = 40; $0.override = .holding(limit: 62, user: 80) }),
        ("Sailing between 75% and 80%.",
         facts { $0.isSailing = true; $0.sailingRange = 5; $0.override = .holding(limit: 77, user: 80) }),
        ("Sailing between 20% and 25%.",
         facts { $0.isSailing = true; $0.sailingRange = 10; $0.userLimit = 25; $0.override = .holding(limit: 22, user: 25) }),
        ("Putting your limit back…", facts { $0.override = .restoring(user: 80) }),
        ("Putting your limit back…", facts { $0.override = .restoring(user: 80); $0.isBusy = true }),
        ("The Top Up was stopped: macOS refused the limit.",
         facts { $0.modeProblem = "The Top Up was stopped: macOS refused the limit." }),
    ]
    for (expected, row) in rows {
        #expect(LimitText(row).caption == expected)
    }
}

@Test("What is happening now comes before what went wrong, which comes before who set the limit")
func captionOrder() {
    // A Top Up is running: an old problem is not shown over it.
    #expect(LimitText(facts {
        $0.mode = .toppingUp; $0.applyProblem = "old"; $0.modeProblem = "older"
    }).caption == "Charging to 100% once. Your limit returns when you unplug.")
    // Heat comes before the mode it interrupts.
    #expect(LimitText(facts {
        $0.mode = .toppingUp; $0.isPausedForHeat = true; $0.heatThreshold = 40
    }).caption == "Paused for heat. Charging resumes at 38 °C.")
    // A request under way hides a problem; once it ends, the mode's problem
    // shows before the limit's.
    #expect(LimitText(facts { $0.isBusy = true; $0.applyProblem = "p" }).caption == "Applying…")
    #expect(LimitText(facts { $0.applyProblem = "limit"; $0.modeProblem = "mode" }).caption == "mode")
    // The user's own request is "Applying…", even while sailing or restoring.
    #expect(LimitText(facts {
        $0.isBusy = true; $0.userRequestPending = true; $0.isSailing = true; $0.override = .restoring(user: 80)
    }).caption == "Applying…")
    // Sailing while its own request is under way still says sailing.
    #expect(LimitText(facts {
        $0.isBusy = true; $0.isSailing = true; $0.sailingRange = 5; $0.override = .holding(limit: 77, user: 80)
    }).caption == "Sailing between 75% and 80%.")
    // A problem shows before the sailing line once nothing is under way.
    #expect(LimitText(facts {
        $0.isSailing = true; $0.sailingRange = 5; $0.override = .holding(limit: 77, user: 80); $0.applyProblem = "p"
    }).caption == "p")
}

@Test("The value beside Limit: the user's limit, never what a mode asked macOS for")
func values() {
    #expect(LimitText(facts()).value == "80%")
    #expect(LimitText(facts { $0.limitKnown = false }).value == "–")
    #expect(LimitText(facts { $0.limit = LimitState(system: nil, saved: nil) }).value == "No limit")
    // Sailing holds 77 and a Top Up asks for none: both still read 80%.
    #expect(LimitText(facts { $0.limit = LimitState(system: 77, saved: 80); $0.override = .holding(limit: 77, user: 80) }).value == "80%")
    #expect(LimitText(facts { $0.limit = LimitState(system: nil, saved: 80); $0.override = .holding(limit: 100, user: 80) }).value == "80%")
    // Dragging: where the slider is, at once, even over a mode's limit.
    #expect(LimitText(facts { $0.sliderValue = 70; $0.isBusy = true; $0.userRequestPending = true }).value == "70%")
    #expect(LimitText(facts {
        $0.sliderValue = 70; $0.userRequestPending = true; $0.override = .restoring(user: 80)
    }).value == "70%")
    #expect(LimitText(facts { $0.sliderValue = 100; $0.isBusy = true; $0.userRequestPending = true }).value == "No limit")
    // A mode's request under way does not move the value.
    #expect(LimitText(facts { $0.isBusy = true; $0.override = .holding(limit: 100, user: 80) }).value == "80%")
}

@Test("The button appears only when the limit is at rest and is not Hachibu's own")
func actions() {
    #expect(LimitText(facts()).action == nil)
    #expect(LimitText(facts { $0.limit = LimitState(system: 80, saved: 85) }).action == .useSaved(85))
    #expect(LimitText(facts { $0.limit = LimitState(system: nil, saved: 80) }).action == .useSaved(80))
    #expect(LimitText(facts { $0.limit = LimitState(system: 80, saved: nil) }).action == .keepSystem)
    let outside: (inout LimitFacts) -> Void = { $0.limit = LimitState(system: 80, saved: 85) }
    #expect(LimitText(facts { outside(&$0); $0.isBusy = true }).action == nil)
    #expect(LimitText(facts { outside(&$0); $0.canChange = false }).action == nil)
    #expect(LimitText(facts { outside(&$0); $0.mode = .toppingUp }).action == nil)
    #expect(LimitText(facts { outside(&$0); $0.override = .restoring(user: 85) }).action == nil)
    #expect(LimitAction.useSaved(85).title == "Use Hachibu's Limit")
    #expect(LimitAction.keepSystem.title == "Keep This Limit")
}
