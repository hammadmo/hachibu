import Foundation
import Testing
@testable import HachibuKit

/// A scripted Mac. It reports a limit only after `confirmAfter` reads, and
/// enforces a helper limit only after `enforceAfter` checks.
private final class FakeMac: LimitSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var held: Int? = 80
    private var pending: Int??
    private var enforcedLimit: Int? = 80
    private var reads = 0
    private var checks = 0
    private var log: [String] = []
    var acceptOfficial = true
    var acceptHelper = true
    var confirmAfter = 1
    var enforceAfter = 1
    var readable = true

    var calls: [String] { lock.withLock { log } }

    func read() async -> SystemLimit {
        lock.withLock {
            reads += 1
            if let waiting = pending, reads >= confirmAfter { held = waiting; pending = nil }
            return SystemLimit(supported: true, known: readable, limit: held, available: [80, 85, 90, 95, 100])
        }
    }

    func enforced() async -> Int? {
        lock.withLock {
            checks += 1
            if checks >= enforceAfter { enforcedLimit = held }
            return enforcedLimit
        }
    }

    func setOfficial(_ limit: Int) async -> Bool {
        lock.withLock {
            log.append("official \(limit)")
            guard acceptOfficial else { return false }
            pending = .some(limit >= 100 ? nil : limit); reads = 0
            if limit >= 100 { enforcedLimit = nil } else { enforcedLimit = limit }
            return true
        }
    }

    func setThroughHelper(_ limit: Int) async -> Bool {
        lock.withLock {
            log.append("helper \(limit)")
            guard acceptHelper else { return false }
            pending = .some(limit); reads = 0; checks = 0
            return true
        }
    }
}

/// Runs one request on a fresh setter that lives until it answers.
@MainActor
private func outcome(_ mac: FakeMac, _ limit: Int, waitForEnforcement: Bool = true) async -> LimitSetter.Outcome {
    let setter = setter(mac)
    return await setter.request(limit, waitForEnforcement: waitForEnforcement).value
}

@MainActor
private func setter(_ mac: FakeMac) -> LimitSetter {
    LimitSetter(system: mac, officialStops: { [80, 85, 90, 95, 100] }, pause: { _ in await Task.yield() })
}

@MainActor
@Test("A limit macOS offers is set by macOS and held once macOS reports it")
func officialLimit() async {
    let mac = FakeMac()
    mac.confirmAfter = 3
    let setter = setter(mac)
    var settled: [LimitSetter.Outcome] = []
    let outcome = await setter.request(85) { settled.append($0) }.value
    #expect(outcome == .held)
    #expect(settled == [.held])
    #expect(mac.calls == ["official 85"])
    #expect(!setter.isBusy && !setter.isApplying)
}

@MainActor
@Test("Turning the limit off is confirmed by macOS reporting no limit")
func noLimit() async {
    let mac = FakeMac()
    #expect(await outcome(mac, 100) == .held)
    #expect(mac.calls == ["official 100"])
}

@MainActor
@Test("Any other limit goes through the helper and is held only once power management enforces it")
func helperLimit() async {
    let mac = FakeMac()
    mac.enforceAfter = 10
    let setter = setter(mac)
    #expect(await setter.request(70).value == .held)
    #expect(mac.calls == ["helper 70"])
    #expect(!setter.isWaitingForMacOS)
}

@MainActor
@Test("A mode's limit can skip the wait for power management")
func helperLimitWithoutWaiting() async {
    let mac = FakeMac()
    mac.enforceAfter = .max
    #expect(await outcome(mac, 77, waitForEnforcement: false) == .held)
}

@MainActor
@Test("A refusal, a limit never reported, and a limit never enforced are told apart")
func failures() async {
    var mac = FakeMac()
    mac.acceptOfficial = false
    #expect(await outcome(mac, 85) == .notAccepted(viaHelper: false))

    mac = FakeMac()
    mac.acceptHelper = false
    #expect(await outcome(mac, 70) == .notAccepted(viaHelper: true))

    mac = FakeMac()
    mac.confirmAfter = .max
    #expect(await outcome(mac, 85) == .notConfirmed)

    mac = FakeMac()
    mac.readable = false
    #expect(await outcome(mac, 85) == .notConfirmed)

    mac = FakeMac()
    mac.enforceAfter = .max
    #expect(await outcome(mac, 70) == .notEnforced)
}

@MainActor
@Test("Of several requests in a row only the newest reaches the Mac")
func newestWins() async {
    let mac = FakeMac()
    let setter = setter(mac)
    var settled: [LimitSetter.Outcome] = []
    let first = setter.request(85, after: .milliseconds(600)) { settled.append($0) }
    let second = setter.request(90, after: .milliseconds(600)) { settled.append($0) }
    let third = setter.request(95, after: .milliseconds(600)) { settled.append($0) }
    #expect(setter.isBusy)
    #expect(await first.value == .superseded)
    #expect(await second.value == .superseded)
    #expect(await third.value == .held)
    #expect(mac.calls == ["official 95"])
    #expect(settled == [.held])
    #expect(!setter.isBusy)
}

@MainActor
@Test("A request that is waiting for power management gives way to a newer one")
func supersededWhileWaiting() async {
    let mac = FakeMac()
    mac.enforceAfter = .max
    let setter = setter(mac)
    var settled: [LimitSetter.Outcome] = []
    let slow = setter.request(70) { settled.append($0) }
    while !setter.isWaitingForMacOS { await Task.yield() }
    let next = setter.request(85) { settled.append($0) }
    #expect(await slow.value == .superseded)
    #expect(await next.value == .held)
    #expect(mac.calls == ["helper 70", "official 85"])
    #expect(settled == [.held])
}

@MainActor
@Test("Requests never run side by side")
func oneAtATime() async {
    let mac = FakeMac()
    mac.confirmAfter = 5
    let setter = setter(mac)
    let first = setter.request(85)
    while !setter.isApplying { await Task.yield() }
    let second = setter.request(90)
    _ = await first.value
    #expect(await second.value == .held)
    #expect(mac.calls == ["official 85", "official 90"])
}

@MainActor
@Test("Cancelling drops what is waiting and leaves nothing pending")
func cancelPending() async {
    let mac = FakeMac()
    let setter = setter(mac)
    let waiting = setter.request(85, after: .milliseconds(600))
    await setter.cancelPending()
    #expect(await waiting.value == .superseded)
    #expect(mac.calls.isEmpty)
    #expect(!setter.isBusy)
    // And the setter still works afterwards.
    #expect(await setter.request(90).value == .held)
}

@MainActor
@Test("The generation moves when a request starts and when it ends")
func generation() async {
    let mac = FakeMac()
    mac.confirmAfter = 4
    let setter = setter(mac)
    let before = setter.generation
    let running = setter.request(85)
    while !setter.isApplying { await Task.yield() }
    #expect(setter.generation == before + 1)
    _ = await running.value
    #expect(setter.generation == before + 2)
}

@MainActor
@Test("Superseding a running request without a new one leaves nothing pending")
func supersedeWhileRunning() async {
    let mac = FakeMac()
    mac.enforceAfter = .max
    let setter = setter(mac)
    let running = setter.request(70)
    while !setter.isWaitingForMacOS { await Task.yield() }
    setter.supersede()
    #expect(await running.value == .superseded)
    #expect(!setter.isBusy && !setter.isApplying)
    // And when nothing was running at all.
    setter.supersede()
    #expect(!setter.isBusy)
    #expect(await setter.request(85).value == .held)
}

