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
    private(set) var stops = [80, 85, 90, 95, 100]
    private(set) var isApplying = false
    private(set) var applyProblem: String?
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
    @ObservationIgnored private let isPreview: Bool
    @ObservationIgnored private var healthReadAt: Date?

    init(isPreview: Bool = false) {
        self.isPreview = isPreview
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

    var limitCaption: String {
        if !limitSupported { return "This version of macOS does not offer a charge limit." }
        if isApplying { return "Applying…" }
        return applyProblem ?? limit.sourceText
    }

    var limitAction: LimitAction? {
        guard limitSupported, !isApplying, requested == finished else { return nil }
        if let saved = limit.savedToRestore { return .useSaved(saved) }
        return limit.source == .outside ? .keepSystem : nil
    }

    // MARK: Watching

    func start() {
        guard !started, !isPreview else { return }
        started = true
        refresh()
        restartTimer()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        guard !isPreview else { return }
        Task.detached(priority: .utility) { [weak self] in
            let reading = SystemBattery.read()
            let state = ChargeLimit.read()
            await self?.update(reading: reading, state: state)
        }
        if healthReadAt.map({ Date.now.timeIntervalSince($0) > 3600 }) ?? true {
            healthReadAt = .now
            Task.detached(priority: .background) { [weak self] in
                let health = SystemBattery.systemHealthPercent()
                await self?.setSystemHealth(health)
            }
        }
    }

    private func setSystemHealth(_ value: Int?) {
        if let value { systemHealth = value }
    }

    /// For `Hachibu --set-limit <n>`: applies a limit through the same path
    /// as the slider and reports what macOS confirmed.
    func setLimitFromCommandLine(_ value: Int) async -> String {
        let before = await Task.detached { ChargeLimit.read() }.value
        let stops = LimitStops.normalized(before.available)
        guard before.supported, stops.contains(value) else {
            return "refused: \(value) is not one of \(stops)"
        }
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

    private func update(reading: BatteryReading?, state: ChargeLimit.State, now: Date = .now) {
        self.reading = reading
        limitSupported = state.supported
        if !state.available.isEmpty { stops = LimitStops.normalized(state.available) }
        limit = LimitState(system: state.limit, saved: Preferences.shared.savedLimit)
        if !isApplying, requested == finished { setSlider(limit.effective) }
        let justStarted = watch.update(reading: reading, limit: limit.system, now: now)
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
        requested += 1
        let request = requested
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, request == self.requested else { return }
            await self.apply(value, request: request)
        }
    }

    private func applyNow(_ value: Int) {
        guard !isPreview else { return }
        requested += 1
        let request = requested
        Task { [weak self] in await self?.apply(value, request: request) }
    }

    private func apply(_ value: Int, request: Int) async {
        isApplying = true
        applyProblem = nil
        let failure = await Task.detached { ChargeLimit.set(value) }.value
        var problem: String?
        if failure != nil {
            problem = "macOS did not accept this limit. Try again."
        } else {
            Preferences.shared.savedLimit = value
            // macOS takes a moment to report a new limit. Wait for it, so
            // the popover shows a confirmed value, never a hoped-for one.
            let target: Int? = value >= 100 ? nil : value
            var confirmed = false
            for _ in 0..<20 where !confirmed {
                confirmed = await Task.detached { ChargeLimit.read().limit }.value == target
                if !confirmed { try? await Task.sleep(for: .milliseconds(500)) }
            }
            if !confirmed { problem = "macOS has not confirmed this limit. Try again." }
        }
        // A newer request is on its way: let it report instead.
        guard request == requested else { return }
        finished = request
        isApplying = false
        let reading = await Task.detached { SystemBattery.read() }.value
        let state = await Task.detached { ChargeLimit.read() }.value
        update(reading: reading, state: state)
        applyProblem = problem
    }

    // MARK: Fixed states for snapshots

    static func preview(_ preview: PopoverPreview) -> BatteryMonitor {
        let monitor = BatteryMonitor(isPreview: true)
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
        }
        if monitor.reading != nil { monitor.systemHealth = 82 }
        monitor.setSlider(monitor.limit.effective)
        return monitor
    }
}

/// The fixed popover states that snapshot runs capture.
enum PopoverPreview: String, CaseIterable {
    case holding, charging, warning, outside, unavailable

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
