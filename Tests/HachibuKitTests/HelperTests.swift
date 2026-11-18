import Foundation
import Testing
@testable import HachibuKit

@Test("The helper's requests are a closed list of four")
func helperRequestsAreClosed() {
    #expect(HelperRequest(name: "set-limit", value: 70) == .setLimit(70))
    #expect(HelperRequest(name: "cut-adapter", value: 0) == .cutAdapter)
    #expect(HelperRequest(name: "restore-adapter", value: 0) == .restoreAdapter)
    #expect(HelperRequest(name: "read-status", value: 0) == .readStatus)
    for name in ["", "set-limit ", "SET-LIMIT", "write-smc", "run", "cut-adapter;restore-adapter", "quit"] {
        #expect(HelperRequest(name: name, value: 50) == nil)
        #expect(HelperRequest(name: name, value: 0) == nil)
    }
    // A request that takes no value refuses one.
    #expect(HelperRequest(name: "cut-adapter", value: 8) == nil)
    #expect(HelperRequest(name: "read-status", value: 1) == nil)
}

@Test("Every request survives the trip to the helper unchanged")
func helperRequestRoundTrip() {
    for request in [HelperRequest.setLimit(20), .setLimit(100), .cutAdapter, .restoreAdapter, .readStatus] {
        #expect(HelperRequest(name: request.name, value: request.value) == request)
    }
}

@Test("The helper rejects limits outside 20 to 100")
func helperLimitRange() {
    for value in [-1, 0, 1, 19, 101, 255, Int.max, Int.min] {
        #expect(HelperRequest(name: "set-limit", value: value) == nil)
    }
    for value in 20...100 {
        #expect(HelperRequest(name: "set-limit", value: value) == .setLimit(value))
    }
}

@Test("The slider runs from 20 with the helper and from 80 without it")
func stopsWithAndWithoutHelper() {
    let official = [80, 85, 90, 95, 100]
    #expect(LimitStops.all(official: official, helperRunning: false) == official)
    #expect(LimitStops.all(official: official, helperRunning: true) == Array(20...100))
}

@Test("Helper not running shows only for a saved limit below 80%")
func helperMissingBanner() {
    #expect(HelperNeed.isMissing(savedLimit: 70, state: .notInstalled))
    #expect(HelperNeed.isMissing(savedLimit: 79, state: .failed("no answer")))
    #expect(HelperNeed.isMissing(savedLimit: 70, state: .needsApproval))
    #expect(!HelperNeed.isMissing(savedLimit: 70, state: .running))
    #expect(!HelperNeed.isMissing(savedLimit: 70, state: .checking))
    #expect(!HelperNeed.isMissing(savedLimit: 80, state: .notInstalled))
    #expect(!HelperNeed.isMissing(savedLimit: 100, state: .notInstalled))
    #expect(!HelperNeed.isMissing(savedLimit: nil, state: .notInstalled))
}

@Test("Removing the helper raises a low limit to the lowest macOS holds")
func limitAfterRemoval() {
    let official = [80, 85, 90, 95, 100]
    #expect(HelperNeed.limitAfterRemoval(current: 60, official: official) == 80)
    #expect(HelperNeed.limitAfterRemoval(current: 85, official: official) == 85)
    #expect(HelperNeed.limitAfterRemoval(current: 87, official: official) == 90)
    #expect(HelperNeed.limitAfterRemoval(current: 100, official: official) == 100)
    #expect(HelperNeed.limitAfterRemoval(current: 60, official: []) == 100)
}

@Test("The signing rule names the program and the team, and nothing else gets in")
func signingRequirement() {
    #expect(CodeIdentity.requirement(identifier: "app.hachibu.mac", team: "ABCDE12345")
        == "identifier \"app.hachibu.mac\" and anchor apple generic and certificate leaf[subject.OU] = \"ABCDE12345\"")
    #expect(CodeIdentity.requirement(identifier: "app.hachibu.mac", team: "") == nil)
    #expect(CodeIdentity.requirement(identifier: "app.hachibu.mac", team: "ABCDE1234") == nil)
    #expect(CodeIdentity.requirement(identifier: "app.hachibu.mac", team: "A\" or true") == nil)
    #expect(CodeIdentity.requirement(identifier: "x\" or anchor apple", team: "ABCDE12345") == nil)
}
