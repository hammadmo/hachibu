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
    /// True while the helper is being removed. The slider waits.
    private(set) var isRemovingHelper = false
    /// A limit the helper wrote that macOS had not enforced when the wait
    /// ran out. If macOS enforces it later, it is saved then.
    @ObservationIgnored private var lateLimit: Int?
    /// True while a limit set through the helper waits to be enforced.
    private(set) var isWaitingForMacOS = false
    private(set) var isWarning = false
    /// Top Up or Discharge, while one runs.
    private(set) var mode = ChargeMode.normal
    /// Plugged in and drifting down inside the sailing range.
    private(set) var isSailing = false
    /// Why a Top Up or a Discharge could not start or was cut short.
    private(set) var modeProblem: String?
    /// The limit Hachibu asked macOS for on a mode's behalf, in place of
    /// the user's own: 100 during a Top Up, the current level while sailing.
    private(set) var overrideLimit: Int?
    /// The user's limit while `overrideLimit` stands in for it.
    private(set) var limitBeforeOverride: Int?
    @ObservationIgnored private var engine = ChargeEngine()
    @ObservationIgnored private var adoptedSailing = false
    /// The monitor of the running app, for the quit handler.
    @ObservationIgnored nonisolated(unsafe) static weak var current: BatteryMonitor?
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
        reading.map { BatteryStatus.derive(from: $0, limit: limit.system, mode: mode, isSailing: isSailing) }
    }

    /// The limit the user chose: what a mode goes back to. 100 means none.
    var userLimit: Int {
        if overrideLimit != nil, let limitBeforeOverride { return limitBeforeOverride }
        return limit.effective
    }

    /// The limit to draw on the gauge. nil means none.
    var shownLimit: Int? { userLimit >= 100 ? nil : userLimit }

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
    var canChangeLimit: Bool { limitSupported && limitKnown && !isRemovingHelper }

    /// The limit in words. While the slider is being dragged or a request is
    /// under way it shows where the slider is; the caption says "Applying…".
    var limitValueText: String {
        guard limitKnown else { return "–" }
        // Read the slider first, always: the view then redraws on every step of a drag.
        let target = LimitState(system: sliderValue, saved: nil).valueText
        if overrideLimit != nil { return LimitState(system: userLimit, saved: nil).valueText }
        return isApplying || requested != finished ? target : limit.valueText
    }

    var limitCaption: String {
        if !hasLoaded { return "Reading the limit…" }
        if !limitSupported { return "This version of macOS does not offer a charge limit." }
        _ = sliderValue // redraw the caption as soon as a drag starts
        if let modeProblem { return modeProblem }
        if mode == .toppingUp { return "Charging to 100% once. Your limit returns afterwards." }
        if mode == .discharging { return "Running on the battery down to the limit." }
        if isWaitingForMacOS, overrideLimit == nil { return "Applying… macOS can take two minutes." }
        if isApplying || requested != finished { return overrideLimit == nil ? "Applying…" : sailingCaption }
        if let applyProblem { return applyProblem }
        if overrideLimit != nil { return sailingCaption }
        return limitKnown ? limit.sourceText : "The limit could not be read. Trying again…"
    }

    private var sailingCaption: String {
        let range = Preferences.shared.sailingRange
        return "Sailing between \(max(userLimit - range, 20))% and \(userLimit)%."
    }

    var limitAction: LimitAction? {
        guard canChangeLimit, !isApplying, requested == finished, overrideLimit == nil, mode == .normal else { return nil }
        if let saved = limit.savedToRestore { return .useSaved(saved) }
        return limit.source == .outside ? .keepSystem : nil
    }

    // MARK: Watching

    func start() {
        guard !started, !isPreview else { return }
        started = true
        Self.current = self
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
            let late = lateLimit
            Task.detached(priority: .utility) { [weak self] in
                let reading = SystemBattery.read()
                let state = ChargeLimit.read()
                let enforced = late == nil ? nil : ChargeLimit.enforced()
                await self?.finishRefresh(reading: reading, state: state, startedAt: startedAt, enforced: enforced)
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

    private func finishRefresh(reading: BatteryReading?, state: ChargeLimit.State, startedAt: Int, enforced: Int?) {
        refreshing = false
        // macOS enforced, late, a limit Hachibu asked for: it is Hachibu's.
        if let late = lateLimit, startedAt == epoch, !isApplying, enforced == late, state.known, state.limit == late {
            Preferences.shared.savedLimit = late
            lateLimit = nil
            applyProblem = nil
        }
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
                if !isApplying, requested == finished { setSlider(userLimit) }
            } else if !state.supported {
                limitKnown = false
                limit = LimitState(system: nil, saved: Preferences.shared.savedLimit)
            }
            // Supported but unreadable this time: keep the last known limit.
        }
        runModes()
        let justStarted = watch.update(reading: reading, limit: limitKnown ? limit.system : nil,
                                       suppressed: mode != .normal, now: now)
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
        // A new limit from the slider ends a Top Up or a Discharge.
        engine.stop()
        mode = .normal
        modeProblem = nil
        // A short pause, so a drag across several stops makes one request.
        enqueueApply(value, after: .milliseconds(600))
    }

    private func applyNow(_ value: Int) {
        guard !isPreview else { return }
        enqueueApply(value, after: nil)
    }

    /// Queues a limit request behind any that is still running. Only the
    /// newest request is carried out; older ones that have not started are dropped.
    private func enqueueApply(_ value: Int, after delay: Duration?, remember: Bool = true) {
        guard canChangeLimit else { return }
        requested += 1
        let request = requested
        let previous = applyChain
        applyChain = Task { [weak self] in
            if let delay { try? await Task.sleep(for: delay) }
            await previous?.value
            guard let self, request == self.requested else { return }
            await self.apply(value, request: request, remember: remember)
        }
    }

    /// `remember` is false for a limit a mode asks for: it is not the
    /// user's choice, so it is never saved as theirs.
    private func apply(_ value: Int, request: Int, remember: Bool = true) async {
        isApplying = true
        applyProblem = nil
        lateLimit = nil
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
            if confirmed, needsHelper, remember || value < 100 {
                isWaitingForMacOS = true
                var enforced = false
                for _ in 0..<48 where !enforced && request == requested {
                    enforced = await Task.detached { ChargeLimit.enforced() }.value == value
                    if !enforced { try? await Task.sleep(for: .seconds(5)) }
                }
                isWaitingForMacOS = false
                if !enforced, request == requested {
                    problem = "macOS accepted this limit but is not enforcing it yet."
                    if remember { lateLimit = value }
                }
            }
            if !confirmed {
                problem = "macOS has not confirmed this limit. Try again."
            } else if request == requested, problem == nil, remember {
                // Saved only once macOS holds it, so "Set by Hachibu" is always true.
                Preferences.shared.savedLimit = value
                overrideLimit = nil
                limitBeforeOverride = nil
            }
        }
        // A mode's limit did not take: end the mode instead of pretending.
        if problem != nil, !remember, request == requested { abandonModes() }
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

    // MARK: Top Up, Discharge, sailing

    /// What the engine looks at. nil until the battery and the limit are known.
    private var chargeInputs: ChargeInputs? {
        guard let reading, limitKnown else { return nil }
        return ChargeInputs(percent: reading.percent, chargerAttached: reading.isPluggedIn, limit: userLimit,
                            sailingRange: Capability.sailing ? Preferences.shared.sailingRange : 0,
                            helperRunning: helper.isRunning)
    }

    var canTopUp: Bool {
        guard let inputs = chargeInputs, canChangeLimit, mode == .normal else { return false }
        return inputs.limit < 100 && inputs.chargerAttached && inputs.percent < 100
    }

    /// The Top Up button: starts one, or stops the one that runs.
    func toggleTopUp() {
        guard !isPreview, let inputs = chargeInputs else { return }
        if mode == .toppingUp { engine.stop() } else { modeProblem = engine.startTopUp(inputs) }
        runModes()
    }

    /// Asks the engine what should be true now and carries it out. A limit
    /// is only requested when the plan changes, and never while another
    /// request is under way, so a limit changed outside Hachibu is not fought.
    private func runModes() {
        guard !isPreview, let inputs = chargeInputs else { return }
        let plan = engine.step(inputs)
        mode = plan.mode
        isSailing = plan.isSailing
        if plan.mode != .normal { modeProblem = nil }
        let wanted: Int? = plan.limit == inputs.limit ? nil : plan.limit
        guard wanted != overrideLimit, !isApplying, requested == finished, canChangeLimit else { return }
        let goingBackTo = inputs.limit
        if overrideLimit == nil { limitBeforeOverride = inputs.limit }
        overrideLimit = wanted
        if wanted == nil { limitBeforeOverride = nil }
        enqueueApply(wanted ?? goingBackTo, after: nil, remember: false)
    }

    /// For `Hachibu --try`: runs a real mode for a while through the same
    /// path as the buttons, printing what is measured, then stops it and
    /// waits until the user's limit is back.
    func tryMode(_ name: String, seconds: Int) async {
        func line(_ label: String) {
            let r = reading
            print("\(label): \(statusTitle), \(r?.percent ?? -1)%, \(r?.currentMA ?? 0) mA, plugged \(r?.isPluggedIn ?? false), "
                + "macOS limit \(limit.valueText), yours \(userLimit)%, mode \(mode.rawValue)\(modeProblem.map { ", " + $0 } ?? "")")
        }
        popoverIsOpen = true
        await helper.refresh()
        for _ in 0..<20 where !(hasLoaded && limitKnown) { try? await Task.sleep(for: .milliseconds(250)) }
        line("before")
        switch name {
        case "topup": toggleTopUp()
        default: print("unknown mode \(name)"); return
        }
        guard mode != .normal else { line("refused"); return }
        for second in 1...max(seconds, 1) {
            try? await Task.sleep(for: .seconds(1))
            if second % 4 == 0 || second == seconds { line("t=\(second)s") }
            if mode == .normal { break }
        }
        if mode == .toppingUp { toggleTopUp() }
        for _ in 0..<120 where isApplying || requested != finished || overrideLimit != nil {
            try? await Task.sleep(for: .milliseconds(500))
        }
        try? await Task.sleep(for: .seconds(3))
        line("after")
    }

    private func abandonModes() {
        engine.stop()
        mode = .normal
        isSailing = false
        overrideLimit = nil
        limitBeforeOverride = nil
        modeProblem = "macOS did not change the limit, so this was stopped."
    }

    /// Before Hachibu quits: put the user's limit back, without waiting for
    /// macOS to report it. Returns once the request is made.
    func restoreBeforeQuit() async {
        guard !isPreview, !Store.isOverridden, overrideLimit != nil || mode != .normal else { return }
        let target = userLimit
        engine.stop()
        mode = .normal
        overrideLimit = nil
        limitBeforeOverride = nil
        requested += 1
        if target < 100, !officialStops.contains(target) {
            _ = await HelperClient.send(.setLimit(target))
        } else {
            _ = await Task.detached { ChargeLimit.set(target) }.value
        }
    }

    /// Removes the helper and everything it did: the charger is reconnected,
    /// a limit below 80% goes up to the lowest macOS holds by itself, and
    /// then the helper leaves macOS. Returns why it failed, or nil.
    func removeHelper() async -> String? {
        guard !isPreview, !isRemovingHelper else { return nil }
        isRemovingHelper = true
        defer { isRemovingHelper = false }
        // Drop any limit request still waiting, and let one that is running
        // finish, so nothing writes a limit after the helper is gone.
        requested += 1
        let request = requested
        await applyChain?.value
        // Asked even of a helper that seems broken: asking starts it.
        _ = await HelperClient.send(.restoreAdapter)
        let now = await Task.detached { ChargeLimit.read() }.value
        guard now.known else { return "The limit could not be read, so the helper was kept. Try again." }
        if !now.available.isEmpty { officialStops = LimitStops.normalized(now.available) }
        if let held = now.limit, held < HelperNeed.lowestWithoutHelper {
            let target = HelperNeed.limitAfterRemoval(current: held, official: officialStops)
            setSlider(target)
            await apply(target, request: request)
            if applyProblem != nil || limit.effective != target {
                return "The limit could not be raised to \(target)%, so the helper was kept."
            }
        } else {
            finished = request
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
        case .topUp:
            var reading = holding
            reading.percent = 88
            reading.currentMA = 1_720
            reading.chargerWatts = 29.8
            monitor.reading = reading
            monitor.limit = LimitState(system: nil, saved: 80)
            monitor.mode = .toppingUp
            monitor.overrideLimit = 100
            monitor.limitBeforeOverride = 80
        case .lowLimit, .helperMissing:
            var reading = holding
            reading.percent = 70
            monitor.reading = reading
            monitor.limit = LimitState(system: 70, saved: 70)
        }
        if monitor.reading != nil { monitor.systemHealth = 82 }
        monitor.limitKnown = preview != .unavailable
        monitor.setSlider(monitor.userLimit)
        return monitor
    }
}

/// The fixed popover states that snapshot runs capture.
enum PopoverPreview: String, CaseIterable {
    case holding, charging, warning, outside, unavailable
    /// A limit below 80%, held with the helper; and the same with the helper gone.
    case lowLimit = "low", helperMissing = "helper"
    case topUp = "topup"

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
