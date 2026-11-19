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
    /// A Top Up has reached 100% and keeps it there until unplugged.
    private(set) var isToppedUp = false
    /// The step a calibration is on. nil when none runs.
    private(set) var calibrationStep: CalibrationStep?
    /// A calibration is waiting for the charger to come back.
    private(set) var isWaitingForCharger = false

    /// What stands between the user's limit and what macOS was asked for.
    private(set) var override = LimitOverride.none {
        didSet { if override != oldValue { recordOverride() } }
    }
    /// Hot, so macOS is asked to hold the level instead of charging.
    private(set) var isPausedForHeat = false
    /// A limit the user asked for is waiting or under way.
    private(set) var userRequestPending = false
    /// The limit was already put back for a quit; the quit need not wait.
    private(set) var hasRestoredForQuit = false
    /// A calibration finished; say so once the user's limit is really back.
    @ObservationIgnored private var owesFinishedNotice = false
    /// The caption is the notice from a launch that found a leftover limit.
    @ObservationIgnored private var showsLaunchNotice = false
    /// The limit a mode has asked macOS for. nil when none.
    var overrideLimit: Int? { override.asked }
    var isOverriding: Bool { override != .none }

    @ObservationIgnored private var engine = ChargeEngine()
    @ObservationIgnored private var adoptedSailing = false
    /// After a hold failed to take, sailing waits until this time.
    @ObservationIgnored private var sailingPausedUntil: Date?
    /// When to ask for the user's limit again after macOS did not take it back.
    @ObservationIgnored private var restoreRetryAt: Date?
    /// False in a one-shot command-line run: the copy in the menu bar runs
    /// Top Up and sailing, and two copies would pull against each other.
    /// `--try` is the one command-line run that exists to run a mode.
    @ObservationIgnored var runsModes = !Launch.isOneShot || CommandLine.arguments.contains("--try")
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
    var userLimit: Int { override.userLimit(system: limit.effective) }

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

    /// The limit in words. While the slider is being dragged or a request is
    /// under way it shows where the slider is; the caption says "Applying…".
    var limitValueText: String {
        guard limitKnown else { return "–" }
        // Read the slider first, always: the view then redraws on every step of a drag.
        let target = LimitState(system: sliderValue, saved: nil).valueText
        // A limit the user is setting shows at once, even over a mode's.
        if userRequestPending { return target }
        if isOverriding { return LimitState(system: userLimit, saved: nil).valueText }
        return isBusy ? target : limit.valueText
    }

    /// A limit request is waiting or under way.
    var isBusy: Bool { setter.isBusy }

    var limitCaption: String {
        if !hasLoaded { return "Reading the limit…" }
        if !limitSupported { return "This version of macOS does not offer a charge limit." }
        _ = sliderValue // redraw the caption as soon as a drag starts
        if mode == .calibrating {
            return isWaitingForCharger ? "Calibrating. Connect the charger to go on."
                : "Calibrating. Your limit returns when it is done."
        }
        if mode == .toppingUp {
            return isToppedUp ? "Topped up. Your limit returns when you unplug."
                : "Charging to 100% once. Your limit returns when you unplug."
        }
        if isBusy {
            if userRequestPending { return isWaitingForMacOS ? "Applying… macOS can take two minutes." : "Applying…" }
            if case .restoring = override { return "Putting your limit back…" }
            if isSailing, isOverriding { return sailingCaption }
            return isWaitingForMacOS ? "Applying… macOS can take two minutes." : "Applying…"
        }
        if let modeProblem { return modeProblem }
        if let applyProblem { return applyProblem }
        if isSailing, isOverriding { return sailingCaption }
        if case .restoring = override { return "Putting your limit back…" }
        return limitKnown ? limit.sourceText : "The limit could not be read. Trying again…"
    }

    private var sailingCaption: String {
        let range = Preferences.shared.sailingRange
        return "Sailing between \(max(userLimit - range, 20))% and \(userLimit)%."
    }

    var limitAction: LimitAction? {
        guard canChangeLimit, !isBusy, !isOverriding, mode == .normal else { return nil }
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
            settleModeRequest(outcome)
            Task { await reloadNow() }
            return
        }
        userRequestPending = false
        var problem: String?
        switch outcome {
        case .held:
            // Saved only once macOS holds it, so "Set by Hachibu" is always true.
            Preferences.shared.savedLimit = value
            // Only now is whatever a mode left behind really gone.
            override = .none
            restoreRetryAt = nil
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
        // The new limit did not take while a mode's limit was still in
        // place: go back to the limit from before the mode, and keep asking.
        if problem != nil, case .restoring = override { restoreRetryAt = Date.now.addingTimeInterval(60) }
        applyProblem = problem
        Task { await reloadNow() }
    }

    /// The outcome of a limit a mode asked for: a hold, a Top Up's "no
    /// limit", or the user's limit being put back.
    private func settleModeRequest(_ outcome: LimitSetter.Outcome, now: Date = .now) {
        if outcome == .held {
            if case .restoring = override { applyProblem = nil }
            override.confirmed()
            if override == .none { overrideEnded() }
            return
        }
        let reason: String
        switch outcome {
        case .notAccepted(viaHelper: true):
            reason = "the helper did not answer"
            Task { await helper.refresh() }
        case .notAccepted: reason = "macOS refused the limit"
        case .notConfirmed: reason = "macOS did not report the new limit"
        default: reason = "macOS accepted the limit but has not enforced it"
        }
        switch override {
        case .restoring:
            // Never give up on the user's limit: ask again in a minute.
            restoreRetryAt = now.addingTimeInterval(60)
            applyProblem = "Your limit is not back yet: \(reason). Hachibu will ask again."
        case .holding(_, let user):
            // What the mode asked for did not take. Stop the mode, say why,
            // and put the user's limit back; the Mac may be in between.
            if mode == .toppingUp {
                modeProblem = "The Top Up was stopped: \(reason)."
            } else if mode == .calibrating {
                modeProblem = "The calibration was stopped: \(reason)."
                calibrationStep = nil
            } else {
                sailingPausedUntil = now.addingTimeInterval(600)
                modeProblem = "Sailing is paused for ten minutes: \(reason)."
            }
            engine.stop()
            engine.resetSailing()
            mode = .normal
            isSailing = false
            isToppedUp = false
            isPausedForHeat = false
            // What was asked stays written down until the user's limit is back.
            override = .restoring(user: user)
            restoreRetryAt = now
        case .none:
            break
        }
    }

    /// Reads the battery and the limit now, without waiting for the timer.
    private func reloadNow() async {
        let startedAt = setter.generation
        let reading = await Task.detached { SystemBattery.read() }.value
        let state = await Task.detached { ChargeLimit.read() }.value
        update(reading: reading, state: startedAt == setter.generation && !isApplying ? state : nil)
    }

    // MARK: Top Up and sailing

    /// Sailing only steers a limit that is Hachibu's own, and waits after a
    /// hold that did not take.
    private func sailingRange(now: Date) -> Int {
        guard Capability.sailing, isOverriding || limit.source == .hachibu else { return 0 }
        if let until = sailingPausedUntil, now < until { return 0 }
        return Preferences.shared.sailingRange
    }

    /// What the engine looks at. nil until the battery and the limit are known.
    private func chargeInputs(now: Date = .now) -> ChargeInputs? {
        guard let reading, limitKnown else { return nil }
        return ChargeInputs(percent: reading.percent, chargerAttached: reading.isPluggedIn, limit: userLimit,
                            sailingRange: sailingRange(now: now), helperRunning: helper.isRunning,
                            macOSFullCharge: reading.fullChargeOverride)
    }

    var canTopUp: Bool {
        guard let inputs = chargeInputs(), canChangeLimit, mode == .normal else { return false }
        return inputs.limit < 100 && inputs.chargerAttached && inputs.percent < 100
    }

    /// The Top Up button: starts one, or stops the one that runs.
    func toggleTopUp() {
        guard !isPreview, let inputs = chargeInputs() else { return }
        if mode == .toppingUp { engine.stop() } else { modeProblem = engine.startTopUp(inputs) }
        runModes()
    }

    /// Why a calibration cannot start now, in words for the user. nil when it can.
    var calibrationRefusal: String? {
        guard let inputs = chargeInputs(), canChangeLimit else { return "The battery or the limit cannot be read right now." }
        guard !isBusy else { return "A limit change is under way. Try again in a moment." }
        var trial = engine
        return trial.startCalibration(inputs)
    }

    /// Starts a calibration. Returns why not, or nil.
    @discardableResult
    func startCalibration() -> String? {
        guard !isPreview else { return nil }
        if let refusal = calibrationRefusal { return refusal }
        guard let inputs = chargeInputs() else { return "The battery cannot be read right now." }
        let refusal = engine.startCalibration(inputs)
        if refusal == nil { runModes() }
        return refusal
    }

    /// Ends a calibration early; the user's limit is asked for again.
    func stopCalibration() {
        guard !isPreview, mode == .calibrating else { return }
        engine.stop()
        runModes()
    }

    /// At launch: a limit that is exactly the level Hachibu was holding when
    /// it last ran is taken up again as sailing. Any other limit below the
    /// saved one was set outside Hachibu and is left alone.
    private func adoptSailing() {
        guard !adoptedSailing else { return }
        adoptedSailing = true
        guard runsModes, !isPreview else { return }
        // A Top Up or a calibration whose limit Hachibu did not get to take
        // back (a crash, a forced quit, a restore that failed): what it asked
        // for and the user's limit were both written down. If macOS still
        // holds exactly what was asked, it is Hachibu's own leftover, and the
        // user's limit is put back.
        if let asked = Preferences.shared.modeAsk, let user = Preferences.shared.modeUser {
            if limit.effective == asked, user != asked {
                override = .restoring(user: user)
                restoreRetryAt = .now
                modeProblem = "Hachibu stopped during a Top Up or a calibration. Your limit is being put back."
                showsLaunchNotice = true
                return
            }
            Preferences.shared.modeAsk = nil
            Preferences.shared.modeUser = nil
        }
        guard let hold = Preferences.shared.sailingHold else { return }
        guard Capability.sailing, Preferences.shared.sailingRange > 0, override == .none,
              let saved = limit.saved, limit.system == hold, hold < saved else {
            Preferences.shared.sailingHold = nil
            return
        }
        isSailing = true
        override = .holding(limit: hold, user: saved)
        engine.adopt(hold: hold)
    }

    /// With a fresh reading of the limit and nothing under way: if macOS
    /// holds something other than what a mode asked for, someone changed it
    /// outside Hachibu. The mode ends and that limit is left as it is.
    private func noticeOutsideChange() {
        // During macOS's own full charge the reported limit is not to be
        // trusted as a change someone made.
        guard !isPreview, !isBusy, reading?.fullChargeOverride != true else { return }
        let before = override
        let changedOutside = override.observe(system: limit.effective)
        if override == .none, before != .none, !changedOutside { overrideEnded() }
        guard changedOutside else { return }
        engine.stop()
        engine.resetSailing()
        mode = .normal
        isSailing = false
        isToppedUp = false
        isPausedForHeat = false
        calibrationStep = nil
        owesFinishedNotice = false
        modeProblem = nil
        restoreRetryAt = nil
        modeLog.notice("the limit was changed outside Hachibu during a mode; the mode ended")
    }

    /// The user's limit is confirmed back after a mode.
    private func overrideEnded() {
        if showsLaunchNotice {
            showsLaunchNotice = false
            modeProblem = nil
        }
        if owesFinishedNotice {
            owesFinishedNotice = false
            Notifier.calibrationFinished(limit: userLimit)
        }
    }

    /// Writes down what a mode has asked macOS for, and the user's limit it
    /// stands in for, so that a launch after a crash can tell Hachibu's own
    /// leftover from a limit set elsewhere. It stays written while the
    /// user's limit is being put back, and is erased only once that is
    /// confirmed (or the user sets a limit and macOS holds it).
    private func recordOverride() {
        guard !isPreview else { return }
        let preferences = Preferences.shared
        switch override {
        case .none:
            preferences.modeAsk = nil
            preferences.modeUser = nil
            preferences.sailingHold = nil
        case .holding(let limit, let user):
            if isSailing {
                preferences.sailingHold = limit
                preferences.modeAsk = nil
                preferences.modeUser = nil
            } else {
                preferences.modeAsk = limit
                preferences.modeUser = user
                preferences.sailingHold = nil
            }
        case .restoring:
            break
        }
    }

    /// A limit the user asks for ends every mode first. While a mode's
    /// limit is still in place the override stays as "putting the old limit
    /// back": if the user's new limit does not take, the old one returns
    /// instead of the mode's limit staying.
    private func endModesForUserRequest() {
        engine.stop()
        mode = .normal
        isToppedUp = false
        isPausedForHeat = false
        calibrationStep = nil
        isWaitingForCharger = false
        owesFinishedNotice = false
        showsLaunchNotice = false
        modeProblem = nil
        restoreRetryAt = nil
        if override != .none { override = .restoring(user: userLimit) }
    }

    /// Asks the engine what should be true now and carries it out. A limit
    /// is asked for only when the plan changes, and never while another
    /// request is under way.
    private func runModes(now: Date = .now) {
        guard !isPreview, runsModes, let inputs = chargeInputs(now: now) else { return }
        let plan = engine.step(inputs)
        mode = plan.mode
        isSailing = plan.isSailing
        isToppedUp = plan.isToppedUp
        isPausedForHeat = plan.isPausedForHeat
        let wasCalibrating = calibrationStep != nil
        calibrationStep = plan.calibration
        isWaitingForCharger = plan.isWaitingForCharger
        if wasCalibrating, plan.calibration == nil {
            // Said only once the user's limit is really back.
            if engine.lastEnd == .finished { owesFinishedNotice = true }
            if engine.lastEnd == .timedOut {
                modeProblem = "The calibration was stopped: a step took more than twelve hours."
            }
        }
        // A mode that is running again has nothing left to explain.
        if plan.mode != .normal || plan.isSailing { modeProblem = nil }
        guard !isBusy, canChangeLimit else { return }
        let wanted: Int? = plan.limit == inputs.limit ? nil : plan.limit
        let retryDue = restoreRetryAt.map { now >= $0 } ?? false
        if let limit = override.follow(wanted: wanted, userLimit: inputs.limit, retryDue: retryDue) {
            restoreRetryAt = nil
            ask(limit, plan)
        }
        if override == .none, owesFinishedNotice { overrideEnded() }
    }

    private func ask(_ limit: Int, _ plan: ChargePlan) {
        modeLog.notice("asked macOS for \(limit, privacy: .public)%: \(plan.mode.rawValue, privacy: .public)\(plan.isSailing ? ", sailing" : "", privacy: .public)")
        enqueueApply(limit, after: nil, remember: false)
    }

    /// Before Hachibu quits: put the user's limit back, without waiting for
    /// macOS to report it. Returns once the request is made.
    func restoreBeforeQuit() async {
        guard !isPreview, !Store.isOverridden, !hasRestoredForQuit, isOverriding || mode != .normal else { return }
        let target = userLimit
        engine.stop()
        mode = .normal
        hasRestoredForQuit = true
        guard isOverriding else { return }
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
        let user = userLimit
        endModesForUserRequest()
        engine.resetSailing()
        isSailing = false
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
        calibrationStep = fixture.calibration
        if let asked = fixture.overrideLimit, let user = fixture.limitBeforeOverride {
            override = .holding(limit: asked, user: user)
        }
        if fixture.reading != nil { systemHealth = 82 }
        setSlider(userLimit)
    }
}
