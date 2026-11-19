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
    typealias LimitAction = HachibuKit.LimitAction

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
    /// Everything about Top Up, sailing, calibration, and heat protection:
    /// what they ask macOS for, and how the user's limit comes back. It
    /// decides; this monitor carries out what it returns (`carryOut`).
    private(set) var modes = ModeCoordinator()
    /// Top Up or calibration, while one runs.
    var mode: ChargeMode { modes.mode }
    /// Plugged in and drifting down inside the sailing range.
    var isSailing: Bool { modes.isSailing }
    /// Why a mode could not start or was cut short.
    var modeProblem: String? { modes.problem }
    /// A Top Up has reached 100% and keeps it there until unplugged.
    var isToppedUp: Bool { modes.isToppedUp }
    /// The step a calibration is on. nil when none runs.
    var calibrationStep: CalibrationStep? { modes.calibrationStep }
    /// A calibration is waiting for the charger to come back.
    var isWaitingForCharger: Bool { modes.isWaitingForCharger }
    /// Hot, so macOS is asked to hold the level instead of charging.
    var isPausedForHeat: Bool { modes.isPausedForHeat }
    /// What stands between the user's limit and what macOS was asked for.
    var override: LimitOverride { modes.override }
    /// The limit a mode has asked macOS for. nil when none.
    var overrideLimit: Int? { modes.override.asked }
    var isOverriding: Bool { modes.isOverriding }

    /// A limit the user asked for is waiting or under way.
    private(set) var userRequestPending = false
    /// For `Hachibu --try heat`: a threshold used in place of the setting.
    @ObservationIgnored var heatThresholdForTrial: Int?
    /// The limit was already put back for a quit; the quit need not wait.
    private(set) var hasRestoredForQuit = false
    @ObservationIgnored private var hasLaunchedModes = false
    /// False in a one-shot command-line run: the copy in the menu bar runs
    /// Top Up and sailing, and two copies would pull against each other.
    /// `--try` is the one command-line run that exists to run a mode.
    @ObservationIgnored var runsModes = Launch.command?.runsModes ?? true
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
    @ObservationIgnored private var fullCharge = FullChargeWatch()
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
        // Once topped up, the battery's own state is the truth: "Fully charged".
        reading.map { reading in
            if reading.fullChargeOverride { return BatteryStatus.fullChargeByMacOS }
            if isPausedForHeat { return BatteryStatus.pausedForHeat }
            if let calibrationStep { return BatteryStatus.calibrating(calibrationStep) }
            return BatteryStatus.derive(from: reading, limit: limit.system, mode: isToppedUp ? .normal : mode, isSailing: isSailing)
        }
    }

    /// The limit the user chose: what a mode goes back to. 100 means none.
    var userLimit: Int { modes.userLimit(system: limit.effective) }

    /// The limit to draw on the gauge. nil means none.
    var shownLimit: Int? { userLimit >= 100 ? nil : userLimit }

    var statusTitle: String {
        if isWarning { return "Limit not holding" }
        return status?.title ?? (hasLoaded ? "Battery information unavailable" : "Reading the battery…")
    }

    var statusDetail: String? {
        if isWaitingForCharger { return "Waiting for the charger" }
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

    /// A limit request is waiting or under way.
    var isBusy: Bool { setter.isBusy }

    /// The words in the limit block. The rules are `LimitText` in
    /// HachibuKit; this only gathers the facts. The slider is read first,
    /// always, so the views redraw on every step of a drag.
    var limitText: LimitText {
        var facts = LimitFacts()
        facts.sliderValue = sliderValue
        facts.hasLoaded = hasLoaded
        facts.limitSupported = limitSupported
        facts.limitKnown = limitKnown
        facts.canChange = canChangeLimit
        facts.limit = limit
        facts.userLimit = userLimit
        facts.isBusy = isBusy
        facts.isWaitingForMacOS = isWaitingForMacOS
        facts.userRequestPending = userRequestPending
        facts.override = override
        facts.mode = mode
        facts.isSailing = isSailing
        facts.isToppedUp = isToppedUp
        facts.isPausedForHeat = isPausedForHeat
        facts.isWaitingForCharger = isWaitingForCharger
        facts.heatThreshold = heatThreshold
        facts.sailingRange = Preferences.shared.sailingRange
        facts.modeProblem = modeProblem
        facts.applyProblem = applyProblem
        return LimitText(facts)
    }

    var limitValueText: String { limitText.value }
    var limitCaption: String { limitText.caption }
    var limitAction: LimitAction? { limitText.action }

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
                launchModes()
                noticeOutsideChange()
                if !isBusy { setSlider(userLimit) }
            } else if !state.supported {
                limitKnown = false
                limit = LimitState(system: nil, saved: Preferences.shared.savedLimit)
            }
            // Supported but unreadable this time: keep the last known limit.
        }
        runModes(now: now)
        if !isPreview, let reading, fullCharge.update(isFullCharge: reading.fullChargeOverride) {
            Notifier.fullChargeByMacOS(limit: userLimit)
        }
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
            endModesForUserRequest()
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
        // A limit the user sets is theirs: any Top Up or hold ends here, so
        // nothing a mode did can come back over it.
        endModesForUserRequest()
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
        if remember { userRequestPending = true }
        setter.request(value, after: delay) { [weak self] in self?.settle(value, $0, remember: remember) }
    }

    /// What a finished request means for what Hachibu saves and says.
    private func settle(_ value: Int, _ outcome: LimitSetter.Outcome, remember: Bool) {
        guard outcome != .superseded else { return }
        guard remember else {
            carryOut(modes.modeRequestSettled(outcome, now: .now))
            Task { await reloadNow() }
            return
        }
        userRequestPending = false
        var problem: String?
        switch outcome {
        case .held:
            // Saved only once macOS holds it, so "Set by Hachibu" is always true.
            Preferences.shared.savedLimit = value
        case .notAccepted(let viaHelper):
            problem = viaHelper ? "The helper did not set this limit. Try again."
                : "macOS did not accept this limit. Try again."
            if viaHelper { Task { await helper.refresh() } }
        case .notConfirmed:
            problem = "macOS has not confirmed this limit. Try again."
        case .notEnforced:
            problem = "macOS accepted this limit but is not enforcing it yet."
            lateLimit = value
        case .superseded:
            return
        }
        // Held: whatever a mode left behind is gone. Not held while a
        // mode's limit was still in place: the limit from before returns.
        carryOut(modes.userRequestSettled(held: outcome == .held, now: .now))
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

    // MARK: Modes: Top Up, sailing, calibration, heat protection

    /// The temperature above which charging pauses. nil when heat protection is off.
    var heatThreshold: Int? {
        if let heatThresholdForTrial { return heatThresholdForTrial }
        guard Capability.heatProtection, Preferences.shared.heatProtection else { return nil }
        return Preferences.shared.heatThreshold
    }

    /// The reading as the modes see it. nil until the battery and the limit
    /// are known. The coordinator fills in the user's limit itself.
    private var modeReading: ChargeInputs? {
        guard let reading, limitKnown else { return nil }
        return ChargeInputs(percent: reading.percent, chargerAttached: reading.isPluggedIn, limit: userLimit,
                            sailingRange: Capability.sailing ? Preferences.shared.sailingRange : 0,
                            helperRunning: helper.isRunning, macOSFullCharge: reading.fullChargeOverride,
                            temperatureC: reading.temperatureC, heatThreshold: heatThreshold)
    }

    /// Sailing only steers a limit that is Hachibu's own.
    private var limitIsOwn: Bool { limit.source == .hachibu }

    var canTopUp: Bool {
        guard let reading = modeReading, canChangeLimit, mode == .normal else { return false }
        return userLimit < 100 && reading.chargerAttached && reading.percent < 100
    }

    /// The Top Up button: starts one, or stops the one that runs.
    func toggleTopUp() {
        guard !isPreview, let reading = modeReading else { return }
        modes.toggleTopUp(reading, system: limit.effective, limitIsOwn: limitIsOwn)
        runModes()
    }

    /// Why a calibration cannot start now, in words for the user. nil when it can.
    var calibrationRefusal: String? {
        guard let reading = modeReading, canChangeLimit else { return "The battery or the limit cannot be read right now." }
        guard !isBusy else { return "A limit change is under way. Try again in a moment." }
        return modes.calibrationRefusal(reading, system: limit.effective, limitIsOwn: limitIsOwn)
    }

    /// Starts a calibration. Returns why not, or nil.
    @discardableResult
    func startCalibration() -> String? {
        guard !isPreview else { return nil }
        if let refusal = calibrationRefusal { return refusal }
        guard let reading = modeReading else { return "The battery cannot be read right now." }
        let refusal = modes.startCalibration(reading, system: limit.effective, limitIsOwn: limitIsOwn)
        if refusal == nil { runModes() }
        return refusal
    }

    /// Ends a calibration early; the user's limit is asked for again.
    func stopCalibration() {
        guard !isPreview, mode == .calibrating else { return }
        modes.stop()
        runModes()
    }

    /// Once, with the first reading of the limit: what Hachibu wrote down
    /// when it last ran decides whether a limit it left behind is undone
    /// (a Top Up, a calibration, a heat pause) or taken up again (sailing).
    private func launchModes() {
        guard !hasLaunchedModes else { return }
        hasLaunchedModes = true
        guard runsModes, !isPreview else { return }
        carryOut(modes.launched(record: Preferences.shared.modeRecord, system: limit.effective, saved: limit.saved,
                                sailingRange: Capability.sailing ? Preferences.shared.sailingRange : 0, now: .now))
    }

    /// With a fresh reading of the limit and nothing under way: a limit
    /// changed outside Hachibu during a mode ends the mode and is left alone.
    private func noticeOutsideChange() {
        guard !isPreview, !isBusy else { return }
        let was = modes.isOverriding
        carryOut(modes.observed(system: limit.effective, isMacOSFullCharge: reading?.fullChargeOverride == true))
        if was, !modes.isOverriding, limit.source == .outside {
            modeLog.notice("the limit was changed outside Hachibu during a mode; the mode ended")
        }
    }

    /// A limit the user asks for ends every mode first.
    private func endModesForUserRequest() {
        carryOut(modes.userAsked(system: limit.effective))
    }

    /// Hands the reading to the coordinator and carries out what it wants.
    private func runModes(now: Date = .now) {
        guard !isPreview, runsModes, let reading = modeReading else { return }
        carryOut(modes.reading(reading, system: limit.effective, limitIsOwn: limitIsOwn,
                               canAsk: !isBusy && canChangeLimit, now: now))
    }

    /// Does what the coordinator decided.
    private func carryOut(_ effects: [ModeEffect]) {
        for effect in effects {
            switch effect {
            case .ask(let limit):
                modeLog.notice("asked macOS for \(limit, privacy: .public)%: \(self.mode.rawValue, privacy: .public)\(self.isSailing ? ", sailing" : "", privacy: .public)")
                enqueueApply(limit, after: nil, remember: false)
            case .write(let record):
                Preferences.shared.modeRecord = record
            case .notify(.calibrationFinished(let limit)):
                Notifier.calibrationFinished(limit: limit)
            case .refreshHelper:
                Task { await helper.refresh() }
            case .limitProblem(let text):
                applyProblem = text
            }
        }
    }

    /// Before Hachibu quits: put the user's limit back, without waiting for
    /// macOS to report it. Returns once the request is made.
    func restoreBeforeQuit() async {
        guard !isPreview, !Store.isOverridden, !hasRestoredForQuit, isOverriding || mode != .normal else { return }
        hasRestoredForQuit = true
        guard let target = modes.quitting(system: limit.effective) else { return }
        // What the mode asked for stays written down: this write is not
        // confirmed, and if it fails the next launch puts the limit back.
        // Let a request that is mid-call finish first, briefly, so it cannot
        // land after the limit written here.
        setter.supersede()
        for _ in 0..<30 where setter.isApplying { try? await Task.sleep(for: .milliseconds(100)) }
        if target < 100, !officialStops.contains(target) {
            _ = await HelperClient.send(.setLimit(target))
        } else {
            _ = await Task.detached { ChargeLimit.set(target) }.value
        }
    }

    /// Removes the helper and everything it did: any Top Up or sailing ends,
    /// the charger is reconnected, a limit below 80% goes up to the lowest
    /// macOS holds by itself, and then the helper leaves macOS. Returns why
    /// it failed, or nil.
    func removeHelper() async -> String? {
        guard !isPreview, !isRemovingHelper else { return nil }
        isRemovingHelper = true
        defer { isRemovingHelper = false }
        // Drop any limit request still waiting, and let one that is running
        // finish, so nothing writes a limit after the helper is gone.
        await setter.cancelPending()
        // The limit that must hold afterwards is the user's own, not
        // whatever a mode has macOS holding right now.
        let removal = modes.removingHelper(system: limit.effective)
        carryOut(removal.effects)
        let user = removal.user
        // Asked even of a helper that seems broken: asking starts it.
        _ = await HelperClient.send(.restoreAdapter)
        let now = await Task.detached { ChargeLimit.read() }.value
        guard now.known else { return "The limit could not be read, so the helper was kept. Try again." }
        if !now.available.isEmpty { officialStops = LimitStops.normalized(now.available) }
        let target = user < HelperNeed.lowestWithoutHelper
            ? HelperNeed.limitAfterRemoval(current: user, official: officialStops) : user
        if (now.limit ?? 100) != target {
            setSlider(target)
            let outcome = await setter.request(target) { [weak self] in self?.settle(target, $0, remember: true) }.value
            await reloadNow()
            if outcome != .held || limit.effective != target {
                return "The limit could not be set to \(target)%, so the helper was kept."
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
        var calibration: CalibrationStep?
        var isPausedForHeat = false
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
        var override = LimitOverride.none
        if let asked = fixture.overrideLimit, let user = fixture.limitBeforeOverride {
            override = .holding(limit: asked, user: user)
        }
        modes = ModeCoordinator(fixedMode: fixture.mode, isSailing: fixture.isSailing, calibration: fixture.calibration,
                                isPausedForHeat: fixture.isPausedForHeat, override: override)
        if fixture.isPausedForHeat { heatThresholdForTrial = ChargeEngine.heatDefault }
        if fixture.reading != nil { systemHealth = 82 }
        setSlider(userLimit)
    }
}
