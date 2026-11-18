import HachibuKit
import SwiftUI

/// The History window, drawn with the design kit: battery level,
/// temperature, power, and battery health over a day, a week, or a month.
struct HistoryView: View {
    static let windowID = "history"
    static let windowTitle = "Hachibu History"

    @Environment(AppModel.self) private var model
    /// What was recorded, loaded off the main thread. nil until the first load.
    @State private var recorded: HistoryData?
    private var history: HistoryCenter { .shared }

    var body: some View {
        @Bindable var model = model
        let range = model.historyRange
        let data = model.historyPreview == .sample ? HistoryData.sample(range) : recorded ?? HistoryData()
        VStack(spacing: 0) {
            KitTabBar(tabs: HistoryRange.allCases.map { (id: $0, title: $0.title) },
                      selection: $model.historyRange, label: "Time range")
                .padding(.top, Metric.titleBarInset)
                .padding(.bottom, Space.sm)
            KitDivider()
            Group {
                if data.isEmpty { emptyState } else { charts(data, range) }
            }
            .padding(Space.xxl)
        }
        .kitWindow(width: Metric.historyWidth)
        // Load again when the range changes and whenever a minute is recorded.
        .task(id: "\(range.rawValue) \(history.revision) \(model.historyLoad)") {
            guard model.historyPreview == .recorded else { return }
            recorded = await history.data(for: range)
        }
    }

    private var emptyState: some View {
        VStack(spacing: Space.lg) {
            EnsoGauge(percent: nil, size: Metric.gaugeSmall, showsSeal: false)
            VStack(spacing: Space.xs) {
                Text("No history yet").kitType(.status).foregroundStyle(Ink.text)
                Text(Capability.history
                     ? "Hachibu records the battery once a minute while it runs. Charts appear after the first hour."
                     : "Recording the battery is not part of this build yet.")
                    .kitType(.body).foregroundStyle(Ink.textSoft)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, minHeight: Metric.historyEmptyHeight)
        .accessibilityElement(children: .combine)
    }

    private func charts(_ data: HistoryData, _ range: HistoryRange) -> some View {
        let time: (Double) -> String = { range.timeLabel(at: $0, from: data.start, to: data.end) }
        let startLabel = data.startLabel(for: range)
        return Grid(horizontalSpacing: Space.lg, verticalSpacing: Space.lg) {
            GridRow {
                ChartCard(title: "Battery level",
                          series: [.init(id: "level", values: data.level)],
                          bounds: ChartScale.bounds(for: data.level, including: [Double(data.limit), 100],
                                                    step: 10, minimumSpan: 20),
                          guide: data.limit < 100 ? Double(data.limit) : nil,
                          value: { "\(Int($0.rounded()))%" },
                          time: time, startLabel: startLabel)
                ChartCard(title: "Temperature",
                          series: [.init(id: "temperature", values: data.temperature)],
                          bounds: ChartScale.bounds(for: data.temperature, step: 5, minimumSpan: 10),
                          value: { String(format: "%.1f °C", $0) },
                          time: time, startLabel: startLabel)
            }
            GridRow {
                ChartCard(title: "Power",
                          series: [.init(id: "charger", values: data.chargerWatts),
                                   .init(id: "mac", values: data.macWatts, weight: .secondary)],
                          bounds: ChartScale.bounds(for: data.chargerWatts + data.macWatts, including: [0],
                                                    step: 10, minimumSpan: 20),
                          value: { Watts.text($0) },
                          legend: ["Charger", "Mac"],
                          time: time, startLabel: startLabel)
                ChartCard(title: "Battery health",
                          series: [.init(id: "health", values: data.health)],
                          bounds: ChartScale.bounds(for: data.health, step: 1, minimumSpan: 4),
                          value: { "\(Int($0.rounded()))%" },
                          summary: data.health.last.map { "\(Int($0.rounded()))% · \(data.cycles) cycles" },
                          time: time, startLabel: startLabel)
            }
        }
    }
}

/// How far back the History window looks.
nonisolated enum HistoryRange: String, CaseIterable, Identifiable, Sendable {
    case day, week, month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: "Day"
        case .week: "Week"
        case .month: "Month"
        }
    }

    var duration: TimeInterval {
        switch self {
        case .day: 24 * 3600
        case .week: 7 * 24 * 3600
        case .month: 30 * 24 * 3600
        }
    }

    var startLabel: String {
        switch self {
        case .day: "24 hours ago"
        case .week: "7 days ago"
        case .month: "30 days ago"
        }
    }

    /// The time at a point along the chart, 0 at its start and 1 at its end.
    func timeLabel(at fraction: Double, from start: Date, to end: Date) -> String {
        let date = start.addingTimeInterval(end.timeIntervalSince(start) * fraction)
        switch self {
        case .day: return date.formatted(date: .omitted, time: .shortened)
        case .week: return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        case .month: return date.formatted(.dateTime.day().month(.abbreviated))
        }
    }

    /// How many points a chart of this range draws.
    var points: Int {
        switch self {
        case .day: 97
        case .week: 169
        case .month: 121
        }
    }
}

/// Whether the History window shows what was recorded, or sample data for
/// snapshots and design review.
enum HistoryPreview { case recorded, sample }

/// Everything the History window draws for one range. Every series has the
/// same number of points, oldest first.
struct HistoryData: Sendable {
    /// Where the charts begin: the start of the range, or the first thing
    /// recorded when that is later.
    var start = Date.now
    var end = Date.now
    var limit = 80
    var cycles = 0
    var level: [Double] = []
    var temperature: [Double] = []
    var chargerWatts: [Double] = []
    var macWatts: [Double] = []
    var health: [Double] = []

    var isEmpty: Bool { level.count < 2 }

    /// The label under the left edge of every chart.
    func startLabel(for range: HistoryRange) -> String {
        // Recorded for (nearly) the whole range: "24 hours ago".
        if end.timeIntervalSince(start) >= range.duration * 0.98 { return range.startLabel }
        return range == .day ? "Since \(start.formatted(date: .omitted, time: .shortened))"
            : "Since \(start.formatted(.dateTime.day().month(.abbreviated)))"
    }

    /// What Hachibu has recorded for a range. Empty with under an hour of data.
    nonisolated static func recorded(_ range: HistoryRange, from store: HistoryStore, now: Date) -> HistoryData {
        let from = now.addingTimeInterval(-range.duration)
        guard let series = HistorySeries.build(samples: store.samples(since: from), window: range.duration,
                                               now: now, points: range.points) else { return HistoryData() }
        var data = HistoryData(start: series.start, end: series.end, limit: series.limit)
        data.level = series.level
        data.temperature = series.temperature
        data.chargerWatts = series.chargerWatts
        data.macWatts = series.macWatts
        // Health changes slowly: one point per saved day, from the last one
        // before the chart begins. A single day draws as a level line.
        let snapshots = store.healthSnapshots()
        let before = snapshots.last { $0.time < series.start }
        let shown = (before.map { [$0] } ?? []) + snapshots.filter { $0.time >= series.start && $0.time <= now }
        data.health = shown.map { Double($0.healthPercent) }
        if data.health.count == 1 { data.health += data.health }
        data.cycles = shown.last?.cycles ?? 0
        return data
    }

    /// A believable stretch of battery life, the same every time, for
    /// snapshots: held at the limit, a few spells on battery, warm while charging.
    static func sample(_ range: HistoryRange) -> HistoryData {
        let count = range == .day ? 97 : range == .week ? 169 : 121
        let spells: Double = range == .day ? 2 : range == .week ? 6 : 14
        let end = Date(timeIntervalSinceReferenceDate: 816_660_000)
        var data = HistoryData(start: end.addingTimeInterval(-range.duration), end: end, limit: 80, cycles: 274)
        var level = 80.0
        for index in 0..<count {
            let t = Double(index) / Double(count - 1)
            let wave = sin(t * spells * 2 * Double.pi + 0.6)
            let onBattery = wave > 0.55
            let charging = !onBattery && level < 79.5
            level = onBattery ? max(level - 46 / Double(count) * spells, 38) : min(level + 60 / Double(count) * spells, 80)
            let mac = 7 + 3 * abs(sin(t * 41)) + (charging ? 1.5 : 0)
            data.level.append(level)
            data.macWatts.append(mac)
            data.chargerWatts.append(onBattery ? 0 : charging ? mac + 20 - 8 * (level - 40) / 40 : mac + 0.4)
            data.temperature.append(30.5 + (charging ? 5.5 : onBattery ? 1.5 : 2.5) + 1.2 * sin(t * 17))
            data.health.append(82.6 - 0.5 * t + 0.25 * sin(t * 9))
        }
        return data
    }
}
