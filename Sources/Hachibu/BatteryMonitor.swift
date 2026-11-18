import AppKit
import Foundation
import HachibuKit
import Observation
import UserNotifications

/// Watches the battery and macOS's charge limit, and applies the limit the
/// user chooses. Everything the popover and the menu bar item show comes
/// from here.
@Observable
final class BatteryMonitor {
    enum LimitAction: Equatable {
        case useSaved(Int), keepSystem

        var title: String {
            switch self {
            case .useSaved: "Use Hachibu's Limit"
            case .keepSystem: "Keep This Limit"
            }
        }
    }

    private(set) var reading: BatteryReading?
    private(set) var limit = LimitState(system: nil, saved: nil)
    private(set) var limitSupported = true
    /// False until macOS has told us the limit. A failed read keeps the last
    /// known limit and never shows as "no limit".
    private(set) var limitKnown = false
    /// The limits macOS offers by itself.
    private(set) var officialStops = [80, 85, 90, 95, 100]
    /// The helper, which adds every whole percent from 20.
    let helper: HelperManager
    private(set) var isApplying = false
    private(set) var applyProblem: String?
    /// True while a limit set through the helper waits to be enforced.
    private(set) var isWaitingForMacOS = false
    private(set) var isWarning = false
    /// False until the first reading arrives.
    private(set) var hasLoaded = false
    /// Battery health as System Settings shows it, read about once an hour.
    private(set) var systemHealth: Int?

    /// The slider's value. Changing it applies the limit after a short pause,
    /// so a drag across several stops makes one request.
    var sliderValue = 100 {
        didSet { if !syncing, sliderValue != oldValue { scheduleApply(sliderValue) } }
    }

    /// The popover reads faster while it is open.
    var popoverIsOpen = false {
        didSet {
            guard popoverIsOpen != oldValue else { return }
            restartTimer()
            if popoverIsOpen { refresh() }
        }
    }

    @ObservationIgnored private var watch = LimitWatch()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var syncing = false
    @ObservationIgnored private var started = false
    /// Counts limit requests, so only the newest one is applied and the
    /// slider is not pulled back while a request is waiting.
    @ObservationIgnored private var requested = 0
    @ObservationIgnored private var finished = 0
    /// Limit requests run one after another, never side by side.
    @ObservationIgnored private var applyChain: Task<Void, Never>?
    /// Goes up whenever a limit request starts or ends, so a refresh that
    /// began before it cannot bring back the old limit.
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private let isPreview: Bool
    @ObservationIgnored private var healthReadAt: Date?

    init(isPreview: Bool = false, helper: HelperManager = HelperManager()) {
        self.isPreview = isPreview
        self.helper = helper
    }

    // MARK: What the views show

    var status: BatteryStatus? {
        reading.map { BatteryStatus.derive(from: $0, limit: limit.system) }
    }

    var statusTitle: String {
        if isWarning { return "Limit not holding" }
        return status?.title ?? (hasLoaded ? "Battery information unavailable" : "Reading the battery…")
    }

    var statusDetail: String? {
        if let reading, let status { return status.detail(for: reading) }
        return hasLoaded ? "This Mac may not have a battery." : nil
    }

    /// Health as macOS reports it, so the number matches System Settings;
    /// until that arrives, raw capacity over design capacity.
    var healthPercent: Int? { systemHealth ?? reading?.healthPercent }

    /// Where the slider may land.
    var stops: [Int] { LimitStops.all(official: officialStops, helperRunning: helper.isRunning) }

    /// The saved limit is below 80% and the helper that holds it is not there.
    var helperMissing: Bool { HelperNeed.isMissing(savedLimit: limit.saved, state: helper.state) }

    /// The slider works once the limit is known. Until then a drag would
    /// set a limit without knowing the real one.
    var canChangeLimit: Bool { limitSupported && limitKnown }

    var limitValueText: String { limitKnown ? limit.valueText : "–" }

    var limitCaption: String {
        if !hasLoaded { return "Reading the limit…" }
        if !limitSupported { return "This version of macOS does not offer a charge limit." }
        if isWaitingForMacOS { return "Applying… macOS can take two minutes." }
        if isApplying || requested != finished { return "Applying…" }
        if let applyProblem { return applyProblem }
        return limitKnown ? limit.sourceText : "The limit could not be read. Trying again…"
    }

    var limitAction: LimitAction? {
        guard canChangeLimit, !isApplying, requested == finished else { return nil }
        if let saved = limit.savedToRestore { return .useSaved(saved) }
        return limit.source == .outside ? .keepSystem : nil
    }

    // MARK: Watching

    func start() {
        guard !started, !isPreview else { return }
        started = true
        refresh()
        restartTimer()
        Task { await helper.refresh() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        guard !isPreview else { return }
        // One read at a time: a slow read must not pile up behind the timer.
        if !refreshing {
            refreshing = true
            let startedAt = epoch
            Task.detached(priority: .utility) { [weak self] in
                let reading = SystemBattery.read()
                let state = ChargeLimit.read()
                await self?.finishRefresh(reading: reading, state: state, startedAt: startedAt)
            }
        }
        if healthReadAt.map({ Date.now.timeIntervalSince($0) > 3600 }) ?? true {
            healthReadAt = .now
            Task.detached(priority: .background) { [weak self] in
                let health = SystemBattery.systemHealthPercent()
                await self?.setSystemHealth(health)
            }
        }
    }

    private func finishRefresh(reading: BatteryReading?, state: ChargeLimit.State, startedAt: Int) {
        refreshing = false
        // A limit request started or ended since this read began, so its
        // limit may be the old one. Take the battery reading, drop the limit.
        let limitIsCurrent = startedAt == epoch && !isApplying
        update(reading: reading, state: limitIsCurrent ? state : nil)
    }

    private func setSystemHealth(_ value: Int?) {
        if let value { systemHealth = value }
    }

    /// For `Hachibu --set-limit <n>`: applies a limit through the same path
    /// as the slider and reports what macOS confirmed.
    func setLimitFromCommandLine(_ value: Int) async -> String {
        let before = await Task.detached { ChargeLimit.read() }.value
        await helper.refresh()
        if !before.available.isEmpty { officialStops = LimitStops.normalized(before.available) }
        guard before.supported, stops.contains(value) else {
            return helper.isRunning ? "refused: \(value) is not between 20 and 100"
                : "refused: \(value) is not one of \(stops). Lower limits need the helper (\(helper.state.title))"
        }
        limitSupported = true
        limitKnown = before.known
        guard before.known else { return "refused: the current limit could not be read" }
        requested += 1
        await apply(value, request: requested)
        return "limit \(limit.valueText), \(limit.sourceText)" + (applyProblem.map { ". \($0)" } ?? "")
    }

    private func restartTimer() {
        guard started else { return }
        timer?.invalidate()
        let timer = Timer(timeInterval: popoverIsOpen ? 2 : 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = popoverIsOpen ? 0.3 : 4
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Takes a new battery reading and, when given, a new limit state.
    private func update(reading: BatteryReading?, state: ChargeLimit.State?, now: Date = .now) {
        self.reading = reading
        if let state {
            limitSupported = state.supported
            if !state.available.isEmpty { officialStops = LimitStops.normalized(state.available) }
            if state.known {
                limitKnown = true
                Preferences.shared.reloadSavedLimit()
                limit = LimitState(system: state.limit, saved: Preferences.shared.savedLimit)
                if !isApplying, requested == finished { setSlider(limit.effective) }
            } else if !state.supported {
                limitKnown = false
                limit = LimitState(system: nil, saved: Preferences.shared.savedLimit)
            }
            // Supported but unreadable this time: keep the last known limit.
        }
        let justStarted = watch.update(reading: reading, limit: limitKnown ? limit.system : nil, now: now)
        isWarning = watch.isWarning
        hasLoaded = true
        if justStarted, let reading, let held = limit.system {
            Notifier.limitNotHolding(percent: reading.percent, limit: held)
        }
    }

    private func setSlider(_ value: Int) {
        syncing = true
        sliderValue = value
        syncing = false
    }

    // MARK: Changing the limit

    func perform(_ action: LimitAction) {
        switch action {
        case .useSaved(let value):
            setSlider(value)
            applyNow(value)
        case .keepSystem:
            Preferences.shared.savedLimit = limit.effective
            limit = LimitState(system: limit.system, saved: limit.effective)
        }
    }

    /// The banner's button: ask macOS for the limit once more.
    func applyLimitAgain() {
        applyNow(limit.saved ?? limit.effective)
    }

    private func scheduleApply(_ value: Int) {
        guard !isPreview else {
            limit = LimitState(system: value, saved: value)
            return
        }
        // A short pause, so a drag across several stops makes one request.
        enqueueApply(value, after: .milliseconds(600))
    }

    private func applyNow(_ value: Int) {
        guard !isPreview else { return }
        enqueueApply(value, after: nil)
    }

    /// Queues a limit request behind any that is still running. Only the
    /// newest request is carried out; older ones that have not started are dropped.
    private func enqueueApply(_ value: Int, after delay: Duration?) {
        guard canChangeLimit else { return }
        requested += 1
        let request = requested
        let previous = applyChain
        applyChain = Task { [weak self] in
            if let delay { try? await Task.sleep(for: delay) }
            await previous?.value
            guard let self, request == self.requested else { return }
            await self.apply(value, request: request)
        }
    }

    private func apply(_ value: Int, request: Int) async {
        isApplying = true
        applyProblem = nil
        epoch += 1
        // macOS sets the limits it offers; any other needs the helper.
        let needsHelper = value < 100 && !officialStops.contains(value)
        var problem: String?
        if needsHelper {
            if !(await HelperClient.send(.setLimit(value))).succeeded {
                problem = "The helper did not set this limit. Try again."
                await helper.refresh()
            }
        } else if await Task.detached(operation: { ChargeLimit.set(value) }).value != nil {
            problem = "macOS did not accept this limit. Try again."
        }
        if problem == nil {
            // macOS takes a moment to report a new limit. Wait for it, so
            // the popover shows a confirmed value, never a hoped-for one.
            // A read that fails confirms nothing.
            let target: Int? = value >= 100 ? nil : value
            var confirmed = false
            for _ in 0..<20 where !confirmed {
                let state = await Task.detached { ChargeLimit.read() }.value
                confirmed = state.known && state.limit == target
                if !confirmed { try? await Task.sleep(for: .milliseconds(500)) }
            }
            // A limit set through the helper is accepted at once but enforced
            // a minute or two later. Wait until power management reports it.
            if confirmed, needsHelper {
                isWaitingForMacOS = true
                var enforced = false
                for _ in 0..<48 where !enforced && request == requested {
                    enforced = await Task.detached { ChargeLimit.enforced() }.value == value
                    if !enforced { try? await Task.sleep(for: .seconds(5)) }
                }
                isWaitingForMacOS = false
                if !enforced, request == requested { problem = "macOS accepted this limit but is not enforcing it yet." }
            }
            if !confirmed {
                problem = "macOS has not confirmed this limit. Try again."
            } else if request == requested, problem == nil {
                // Saved only once macOS holds it, so "Set by Hachibu" is always true.
                Preferences.shared.savedLimit = value
            }
        }
        epoch += 1
        // A newer request is waiting behind this one: let it report instead.
        guard request == requested else { return }
        finished = request
        isApplying = false
        let reading = await Task.detached { SystemBattery.read() }.value
        let state = await Task.detached { ChargeLimit.read() }.value
        update(reading: reading, state: state)
        applyProblem = problem
    }

    /// Removes the helper and everything it did: the charger is reconnected,
    /// a limit below 80% goes up to the lowest macOS holds by itself, and
    /// then the helper leaves macOS. Returns why it failed, or nil.
    func removeHelper() async -> String? {
        guard !isPreview else { return nil }
        if helper.isRunning { _ = await HelperClient.send(.restoreAdapter) }
        if limitKnown, let held = limit.system, held < HelperNeed.lowestWithoutHelper {
            let target = HelperNeed.limitAfterRemoval(current: held, official: officialStops)
            setSlider(target)
            requested += 1
            await apply(target, request: requested)
            if applyProblem != nil { return "The limit could not be raised to \(target)%, so the helper was kept." }
        }
        return await helper.unregister().map { "macOS did not remove the helper: \($0)" }
    }

    // MARK: Fixed states for snapshots

    static func preview(_ preview: PopoverPreview, helper: HelperState? = nil) -> BatteryMonitor {
        let state = helper ?? (preview == .lowLimit ? .running : .notInstalled)
        let monitor = BatteryMonitor(isPreview: true, helper: HelperManager(fixed: state))
        let holding = BatteryReading(percent: 80, isPluggedIn: true, currentMA: 0, voltageMV: 12_094,
                                     temperatureC: 34.7, cycleCount: 274, rawMaxCapacityMAh: 3556,
                                     designCapacityMAh: 4382, chargerWatts: 9.2, systemWatts: 7.2)
        monitor.hasLoaded = true
        switch preview {
        case .holding:
            monitor.reading = holding
            monitor.limit = LimitState(system: 80, saved: 80)
        case .charging:
            var reading = holding
            reading.percent = 46
            reading.currentMA = 1_950
            reading.chargerWatts = 30.6
            monitor.reading = reading
            monitor.limit = LimitState(system: 80, saved: 80)
        case .warning:
            var reading = holding
            reading.percent = 86
            reading.currentMA = 1_650
            reading.chargerWatts = 28.4
            reading.temperatureC = 37.9
            monitor.reading = reading
            monitor.limit = LimitState(system: 80, saved: 80)
            monitor.isWarning = true
        case .outside:
            monitor.reading = holding
            monitor.limit = LimitState(system: 80, saved: 85)
        case .unavailable:
            monitor.limit = LimitState(system: nil, saved: nil)
        case .lowLimit, .helperMissing:
            var reading = holding
            reading.percent = 70
            monitor.reading = reading
            monitor.limit = LimitState(system: 70, saved: 70)
        }
        if monitor.reading != nil { monitor.systemHealth = 82 }
        monitor.limitKnown = preview != .unavailable
        monitor.setSlider(monitor.limit.effective)
        return monitor
    }
}

/// The fixed popover states that snapshot runs capture.
enum PopoverPreview: String, CaseIterable {
    case holding, charging, warning, outside, unavailable
    /// A limit below 80%, held with the helper; and the same with the helper gone.
    case lowLimit = "low", helperMissing = "helper"

    static let windowID = "popover-preview"
    static let windowTitle = "Hachibu Popover"

    /// The snapshot's file name.
    var page: String { self == .holding ? "popover" : "popover-\(rawValue)" }
}

/// Notifications. Never sent in test runs.
enum Notifier {
    static func requestPermission() {
        guard !Store.isOverridden else { return }
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
    }

    static func limitNotHolding(percent: Int, limit: Int) {
        guard !Store.isOverridden, Preferences.shared.notifyLimitNotHolding else { return }
        let content = UNMutableNotificationContent()
        content.title = "Limit not holding"
        content.body = "Battery is at \(percent)% and still charging. The limit is \(limit)%."
        let request = UNNotificationRequest(identifier: "limit-not-holding", content: content, trigger: nil)
        Task { try? await UNUserNotificationCenter.current().add(request) }
    }
}
