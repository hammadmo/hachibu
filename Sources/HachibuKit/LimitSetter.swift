import Foundation
import Observation

/// What macOS says about its charge limit.
public struct SystemLimit: Equatable, Sendable {
    public var supported = false
    /// False when macOS could not be asked. Then `limit` says nothing:
    /// a failed read must never look like "the limit is off".
    public var known = false
    /// The limit macOS is holding. nil when it is off.
    public var limit: Int?
    /// The limits macOS offers without administrator rights.
    public var available: [Int] = []

    public init(supported: Bool = false, known: Bool = false, limit: Int? = nil, available: [Int] = []) {
        self.supported = supported
        self.known = known
        self.limit = limit
        self.available = available
    }
}

/// Everything LimitSetter asks of the Mac. The app gives the real one;
/// tests give a scripted one.
public protocol LimitSystem: Sendable {
    func read() async -> SystemLimit
    /// The limit power management enforces right now (pmset). nil for none or unknown.
    func enforced() async -> Int?
    /// Sets a limit macOS offers by itself; 100 turns the limit off. True when accepted.
    func setOfficial(_ limit: Int) async -> Bool
    /// Sets any limit from 20 to 99 through the helper. True when accepted.
    func setThroughHelper(_ limit: Int) async -> Bool
}

/// Carries out requests to change the limit, one at a time. Only the newest
/// request counts: one that is still waiting is dropped when another
/// arrives, and one that is running stops waiting. A request is only "held"
/// once macOS itself reports the limit.
@MainActor
@Observable
public final class LimitSetter {
    public enum Outcome: Equatable, Sendable {
        /// macOS reports the limit (and, for a helper limit, enforces it).
        case held
        /// macOS or the helper refused the request.
        case notAccepted(viaHelper: Bool)
        /// Accepted, but macOS never reported the new limit.
        case notConfirmed
        /// Reported, but power management was not enforcing it when the wait ran out.
        case notEnforced
        /// A newer request took its place.
        case superseded
    }

    /// How often and how long the setter asks macOS before giving up.
    public static let confirmTries = 20
    public static let confirmPause = Duration.milliseconds(500)
    public static let enforceTries = 48
    public static let enforcePause = Duration.seconds(5)

    /// A request is being carried out right now.
    public private(set) var isApplying = false
    /// A helper limit is accepted and waiting for power management.
    public private(set) var isWaitingForMacOS = false
    /// A request is waiting or being carried out.
    public var isBusy: Bool { isApplying || requested != finished }
    /// Goes up when a request starts and when it ends, so a reading of the
    /// limit taken across either moment can be recognised as stale.
    public private(set) var generation = 0

    private var requested = 0
    private var finished = 0
    @ObservationIgnored private var chain: Task<Void, Never>?
    @ObservationIgnored private let system: any LimitSystem
    @ObservationIgnored private let officialStops: @MainActor () -> [Int]
    @ObservationIgnored private let pause: @Sendable (Duration) async -> Void

    public init(system: any LimitSystem, officialStops: @escaping @MainActor () -> [Int],
                pause: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.system = system
        self.officialStops = officialStops
        self.pause = pause
    }

    /// Queues a request behind any that is running. `delay` lets a drag
    /// across several values become one request. `settled` runs once, on the
    /// main actor, at the moment the setter stops being busy, and not at all
    /// for a superseded request. The task gives the outcome either way.
    @discardableResult
    public func request(_ limit: Int, after delay: Duration? = nil, waitForEnforcement: Bool = true,
                        settled: @escaping @MainActor (Outcome) -> Void = { _ in }) -> Task<Outcome, Never> {
        requested += 1
        let request = requested
        let previous = chain
        let work = Task { [weak self] () -> Outcome in
            if let delay { await self?.pause(delay) }
            await previous?.value
            guard let self, request == self.requested else { return .superseded }
            let outcome = await self.apply(limit, request: request, waitForEnforcement: waitForEnforcement)
            if outcome != .superseded { settled(outcome) }
            return outcome
        }
        chain = Task { _ = await work.value }
        return work
    }

    /// Drops every request that has not started and waits for the one that
    /// is running to stop. Afterwards nothing is pending.
    public func cancelPending() async {
        supersede()
        await chain?.value
        finished = requested
    }

    /// Makes every earlier request stale without waiting. For quitting.
    public func supersede() {
        requested += 1
        finished = isApplying ? finished : requested
    }

    private func apply(_ limit: Int, request: Int, waitForEnforcement: Bool) async -> Outcome {
        isApplying = true
        generation += 1
        // macOS sets the limits it offers; any other needs the helper.
        let viaHelper = limit < 100 && !officialStops().contains(limit)
        var outcome = Outcome.held
        let accepted = viaHelper ? await system.setThroughHelper(limit) : await system.setOfficial(limit)
        if !accepted {
            outcome = .notAccepted(viaHelper: viaHelper)
        } else {
            // macOS takes a moment to report a new limit. A read that fails
            // confirms nothing.
            let target: Int? = limit >= 100 ? nil : limit
            var confirmed = false
            for _ in 0..<Self.confirmTries where !confirmed {
                let state = await system.read()
                confirmed = state.known && state.limit == target
                if !confirmed { await pause(Self.confirmPause) }
            }
            if !confirmed {
                outcome = .notConfirmed
            } else if viaHelper, waitForEnforcement {
                // A helper limit is accepted at once but enforced a minute
                // or two later. Wait until power management reports it.
                isWaitingForMacOS = true
                var enforced = false
                for _ in 0..<Self.enforceTries where !enforced && request == requested {
                    enforced = await system.enforced() == limit
                    if !enforced { await pause(Self.enforcePause) }
                }
                isWaitingForMacOS = false
                if !enforced { outcome = .notEnforced }
            }
        }
        generation += 1
        // A newer request is waiting behind this one: let it report instead.
        guard request == requested else {
            isApplying = false
            return .superseded
        }
        finished = request
        isApplying = false
        return outcome
    }
}
