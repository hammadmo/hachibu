import Testing
@testable import HachibuKit

private let every: [Notice] = [.limitNotHolding(percent: 84, limit: 80), .fullChargeByMacOS(limit: 80),
                               .topUpFinished(limit: 80), .calibrationFinished(limit: 80)]

@Test("A kind of notification that is switched off is never sent, and the others still are")
func noticeSwitchedOff() {
    #expect(Set(every.map(\.kind)) == Set(Notice.Kind.allCases))
    for notice in every {
        #expect(notice.message(allowed: Set(Notice.Kind.allCases)) != nil)
        #expect(notice.message(allowed: []) == nil)
        #expect(notice.message(allowed: Set(Notice.Kind.allCases).subtracting([notice.kind])) == nil)
        #expect(notice.message(allowed: [notice.kind]) != nil)
    }
}

@Test("Each notification has its own identifier and says the limit only when there is one")
func noticeWords() {
    let all = Set(Notice.Kind.allCases)
    let messages = every.compactMap { $0.message(allowed: all) }
    #expect(Set(messages.map(\.identifier)).count == 4)
    let topUp = Notice.topUpFinished(limit: 80).message(allowed: all)
    #expect(topUp?.title == "Top Up finished")
    #expect(topUp?.body == "The battery is full. It stays at 100% until you unplug the charger; then your limit of 80% returns.")
    #expect(Notice.topUpFinished(limit: 100).message(allowed: all)?.body == "The battery is full.")
    #expect(Notice.calibrationFinished(limit: 100).message(allowed: all)?.body.contains("no limit") == true)
    #expect(Notice.fullChargeByMacOS(limit: 100).message(allowed: all)?.body.contains("your") == false)
}
