import AppKit
import Foundation
import HachibuKit
import Observation
import os

/// What Hachibu did to charging, readable with
/// `log show --predicate 'subsystem == "app.hachibu.mac"'`.
nonisolated let modeLog = Logger(subsystem: "app.hachibu.mac", category: "modes")

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
    /// Where readings are recorded, and where the 24-hour chart comes from.
    let history: HistoryCenter
    /// Carries out limit requests one at a time; only the newest counts.
    @ObservationIgnored private lazy var setter = LimitSetter(system: MacLimitSystem()) { [weak self] in
        self?.officialStops ?? []
    }
    var isApplying: Bool { setter.isApplying }
    private(set) var applyProblem: String?
    /// True while the helper is being removed. The slider waits.
    private(set) var isRemovingHelper = false
    /// A limit the helper wrote that macOS had not enforced when the wait
    /// ran out. If macOS enforces it later, it is saved then.
    @ObservationIgnored private var lateLimit: Int?
    /// True while a limit set through the helper waits to be enforced.
    var isWaitingForMacOS: Bool { setter.isWaitingForMacOS }
    private(set) var isWarning = false
    /// Top Up, while one runs.
    private(set) var mode = ChargeMode.normal
    /// Plugged in and drifting down inside the sailing range.
    private(set) var isSailing = false
    /// Why a Top Up could not start or was cut short.
    private(set) var modeProblem: String?
    /// The limit Hachibu asked macOS for on a mode's behalf, in place of
    /// the user's own: 100 during a Top Up, the current level while sailing.
    private(set) var overrideLimit: Int?
    /// The user's limit while `overrideLimit` stands in for it.
    private(set) var limitBeforeOverride: Int?
    @ObservationIgnored private var engine = ChargeEngine()
    @ObservationIgnored private var adoptedSailing = false
    /// False in a one-shot command-line run (`--set-limit`): the copy in the
    /// menu bar runs Top Up and sailing, and two copies would pull against
    /// each other.
    @ObservationIgnored var runsModes = true
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
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private let isPreview: Bool
    @ObservationIgnored private var healthReadAt: Date?

    init(isPreview: Bool = false, helper: HelperManager = HelperManager(), history: HistoryCenter = .shared) {
        self.isPreview = isPreview
        self.helper = helper
        self.history = history
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
        return isBusy ? target : limit.valueText
    }

    /// A limit request is waiting or under way.
    var isBusy: Bool { setter.isBusy }

    var limitCaption: String {
        if !hasLoaded { return "Reading the limit…" }
        if !limitSupported { return "This version of macOS does not offer a charge limit." }
        _ = sliderValue // redraw the caption as soon as a drag starts
        if let modeProblem { return modeProblem }
        if mode == .toppingUp { return "Charging to 100% once. Your limit returns afterwards." }
        if isWaitingForMacOS, overrideLimit == nil { return "Applying… macOS can take two minutes." }
        if isBusy { return overrideLimit == nil ? "Applying…" : sailingCaption }
        if let applyProblem { return applyProblem }
        if overrideLimit != nil { return sailingCaption }
        return limitKnown ? limit.sourceText : "The limit could not be read. Trying again…"
    }

    private var sailingCaption: String {
        let range = Preferences.shared.sailingRange
        return "Sailing between \(max(userLimit - range, 20))% and \(userLimit)%."
    }

    var limitAction: LimitAction? {
        guard canChangeLimit, !isBusy, overrideLimit == nil, mode == .normal else { return nil }
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
            let startedAt = setter.generation
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
        if let late = lateLimit, startedAt == setter.generation, !isApplying, enforced == late, state.known, state.limit == late {
            Preferences.shared.savedLimit = late
            lateLimit = nil
            applyProblem = nil
        }
        // A limit request started or ended since this read began, so its
        // limit may be the old one. Take the battery reading, drop the limit.
        let limitIsCurrent = startedAt == setter.generation && !isApplying
        update(reading: reading, state: limitIsCurrent ? state : nil)
    }

    private func setSystemHealth(_ value: Int?) {
        if let value { systemHealth = value }
    }

    /// For `Hachibu --set-limit <n>`: applies a limit through the same path
    /// as the slider and reports what macOS confirmed.
    func setLimitFromCommandLine(_ value: Int) async -> String {
        runsModes = false
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
        _ = await setter.request(value) { [weak self] in self?.settle(value, $0, remember: true) }.value
        await reloadNow()
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
                adoptSailing()
                if !isBusy { setSlider(userLimit) }
            } else if !state.supported {
                limitKnown = false
                limit = LimitState(system: nil, saved: Preferences.shared.savedLimit)
            }
            // Supported but unreadable this time: keep the last known limit.
        }
        runModes()
        if !isPreview, let reading {
            // The user's limit, not the level sailing holds (none while the
            // limit cannot be read); and health only once macOS has given its
            // own figure, the one System Settings shows.
            history.note(reading, limit: limitKnown ? userLimit : 100, health: systemHealth, now: now)
        }
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
        // A new limit from the slider ends a Top Up.
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

    /// Asks for a limit. `remember` is false for a limit a mode asks for: it
    /// is not the user's choice, so it is never saved as theirs.
    private func enqueueApply(_ value: Int, after delay: Duration?, remember: Bool = true) {
        guard canChangeLimit else { return }
        applyProblem = nil
        lateLimit = nil
        setter.request(value, after: delay) { [weak self] in self?.settle(value, $0, remember: remember) }
    }

    /// What a finished request means for what Hachibu saves and says.
    private func settle(_ value: Int, _ outcome: LimitSetter.Outcome, remember: Bool) {
        var problem: String?
        switch outcome {
        case .held:
            // Saved only once macOS holds it, so "Set by Hachibu" is always true.
            if remember {
                Preferences.shared.savedLimit = value
                overrideLimit = nil
                limitBeforeOverride = nil
            }
        case .notAccepted(let viaHelper):
            problem = viaHelper ? "The helper did not set this limit. Try again."
                : "macOS did not accept this limit. Try again."
            if viaHelper { Task { await helper.refresh() } }
        case .notConfirmed:
            problem = "macOS has not confirmed this limit. Try again."
        case .notEnforced:
            problem = "macOS accepted this limit but is not enforcing it yet."
            if remember { lateLimit = value }
        case .superseded:
            return
        }
        // A mode's limit did not take: end the mode instead of pretending.
        if problem != nil, !remember { abandonModes() }
        applyProblem = problem
        Task { await reloadNow() }
    }

    /// Reads the battery and the limit now, without waiting for the timer.
    private func reloadNow() async {
        let startedAt = setter.generation
        let reading = await Task.detached { SystemBattery.read() }.value
        let state = await Task.detached { ChargeLimit.read() }.value
        update(reading: reading, state: startedAt == setter.generation && !isApplying ? state : nil)
    }

    // MARK: Top Up and sailing

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

    /// At launch: a limit a little under the saved one, inside the sailing
    /// range, is the level Hachibu was holding when it last ran. Take it up
    /// again as sailing, not as a limit set outside Hachibu.
    private func adoptSailing() {
        guard !adoptedSailing else { return }
        adoptedSailing = true
        let range = Preferences.shared.sailingRange
        guard Capability.sailing, runsModes, range > 0, overrideLimit == nil,
              let saved = limit.saved, let held = limit.system, held < saved, held >= saved - range else { return }
        overrideLimit = held
        limitBeforeOverride = saved
    }

    /// Asks the engine what should be true now and carries it out. A limit
    /// is only requested when the plan changes, and never while another
    /// request is under way, so a limit changed outside Hachibu is not fought.
    private func runModes() {
        guard !isPreview, runsModes, let inputs = chargeInputs else { return }
        let plan = engine.step(inputs)
        mode = plan.mode
        isSailing = plan.isSailing
        if plan.mode != .normal { modeProblem = nil }
        let wanted: Int? = plan.limit == inputs.limit ? nil : plan.limit
        guard wanted != overrideLimit, !isBusy, canChangeLimit else { return }
        let goingBackTo = inputs.limit
        if overrideLimit == nil { limitBeforeOverride = inputs.limit }
        overrideLimit = wanted
        if wanted == nil { limitBeforeOverride = nil }
        modeLog.notice("asked macOS for \(wanted ?? goingBackTo, privacy: .public)%: \(plan.mode.rawValue, privacy: .public)\(plan.isSailing ? ", sailing" : "", privacy: .public)")
        enqueueApply(wanted ?? goingBackTo, after: nil, remember: false)
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
        guard overrideLimit != nil else { return }
        mode = .normal
        overrideLimit = nil
        limitBeforeOverride = nil
        setter.supersede()
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
        await setter.cancelPending()
        // Asked even of a helper that seems broken: asking starts it.
        _ = await HelperClient.send(.restoreAdapter)
        let now = await Task.detached { ChargeLimit.read() }.value
        guard now.known else { return "The limit could not be read, so the helper was kept. Try again." }
        if !now.available.isEmpty { officialStops = LimitStops.normalized(now.available) }
        if let held = now.limit, held < HelperNeed.lowestWithoutHelper {
            let target = HelperNeed.limitAfterRemoval(current: held, official: officialStops)
            setSlider(target)
            let outcome = await setter.request(target) { [weak self] in self?.settle(target, $0, remember: true) }.value
            await reloadNow()
            if outcome != .held || limit.effective != target {
                return "The limit could not be raised to \(target)%, so the helper was kept."
            }
        }
        return await helper.unregister().map { "macOS did not remove the helper: \($0)" }
    }

    // MARK: Fixed states for snapshots

    /// Everything a snapshot shows, given as plain values. The fixtures
    /// themselves are in BatteryMonitor+Preview.swift.
    struct Fixture {
        var reading: BatteryReading?
        var limit = LimitState(system: nil, saved: nil)
        var limitKnown = true
        var isWarning = false
        var mode = ChargeMode.normal
        var isSailing = false
        var overrideLimit: Int?
        var limitBeforeOverride: Int?
        var helper = HelperState.notInstalled
        /// Battery level over the last 24 hours. Empty shows "Collecting data".
        var dayLevels: [Double] = []
    }

    /// A monitor that shows a fixture and never reads or changes anything real.
    convenience init(fixture: Fixture) {
        self.init(isPreview: true, helper: HelperManager(fixed: fixture.helper),
                  history: HistoryCenter(fixedDay: fixture.dayLevels, limit: fixture.limit.saved))
        hasLoaded = true
        reading = fixture.reading
        limit = fixture.limit
        limitKnown = fixture.limitKnown
        isWarning = fixture.isWarning
        mode = fixture.mode
        isSailing = fixture.isSailing
        overrideLimit = fixture.overrideLimit
        limitBeforeOverride = fixture.limitBeforeOverride
        if fixture.reading != nil { systemHealth = 82 }
        setSlider(userLimit)
    }
}
