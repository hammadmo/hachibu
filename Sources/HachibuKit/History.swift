import Foundation

/// One reading of the battery, as History keeps it: once a minute while
/// Hachibu runs.
public struct HistorySample: Equatable, Sendable {
    public var time: Date
    public var percent: Int
    public var isPluggedIn: Bool
    public var isCharging: Bool
    public var temperatureC: Double?
    public var chargerWatts: Double?
    public var macWatts: Double?
    /// The limit macOS held. 100 means none.
    public var limit: Int

    public init(time: Date, percent: Int, isPluggedIn: Bool, isCharging: Bool, temperatureC: Double? = nil,
                chargerWatts: Double? = nil, macWatts: Double? = nil, limit: Int = 100) {
        self.time = time
        self.percent = percent
        self.isPluggedIn = isPluggedIn
        self.isCharging = isCharging
        self.temperatureC = temperatureC
        self.chargerWatts = chargerWatts
        self.macWatts = macWatts
        self.limit = limit
    }

    /// Each sample is 16 bytes on disk: three months of minutes is about 2 MB.
    public static let size = 16
    private static let version: UInt8 = 1

    public func encoded() -> Data {
        var data = Data(capacity: Self.size)
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        // Clamped as a Double first: a wild sensor value must not trap here.
        func tenths(_ value: Double?) -> Int { Int((min(max(value ?? 0, -10_000), 10_000) * 10).rounded()) }
        var flags: UInt8 = 0
        if isPluggedIn { flags |= 1 }
        if isCharging { flags |= 2 }
        if temperatureC != nil { flags |= 4 }
        if chargerWatts != nil { flags |= 8 }
        if macWatts != nil { flags |= 16 }
        put(UInt32(clamping: Int(time.timeIntervalSince1970.rounded())))
        put(UInt8(clamping: percent))
        put(flags)
        put(Int16(clamping: tenths(temperatureC)))
        put(UInt16(clamping: tenths(chargerWatts)))
        put(UInt16(clamping: tenths(macWatts)))
        put(UInt8(clamping: limit))
        put(Self.version)
        put(UInt16(0))
        return data
    }

    /// nil for a record that is the wrong size or from an unknown version.
    public init?(encoded data: Data) {
        guard data.count == Self.size else { return nil }
        let base = data.startIndex
        func byte(_ at: Int) -> UInt8 { data[base + at] }
        func u16(_ at: Int) -> UInt16 { UInt16(byte(at)) | UInt16(byte(at + 1)) << 8 }
        guard byte(13) == Self.version else { return nil }
        let seconds = UInt32(byte(0)) | UInt32(byte(1)) << 8 | UInt32(byte(2)) << 16 | UInt32(byte(3)) << 24
        let flags = byte(5)
        time = Date(timeIntervalSince1970: TimeInterval(seconds))
        percent = Int(byte(4))
        isPluggedIn = flags & 1 != 0
        isCharging = flags & 2 != 0
        temperatureC = flags & 4 != 0 ? Double(Int16(bitPattern: u16(6))) / 10 : nil
        chargerWatts = flags & 8 != 0 ? Double(u16(8)) / 10 : nil
        macWatts = flags & 16 != 0 ? Double(u16(10)) / 10 : nil
        limit = Int(byte(12))
    }
}

/// Battery health on one day.
public struct HealthSnapshot: Equatable, Sendable {
    public var time: Date
    public var healthPercent: Int
    public var cycles: Int

    public init(time: Date, healthPercent: Int, cycles: Int) {
        self.time = time
        self.healthPercent = healthPercent
        self.cycles = cycles
    }

    public static let size = 8

    public func encoded() -> Data {
        var data = Data(capacity: Self.size)
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        put(UInt32(clamping: Int(time.timeIntervalSince1970.rounded())))
        put(UInt8(clamping: healthPercent))
        put(UInt8(1))
        put(UInt16(clamping: cycles))
        return data
    }

    public init?(encoded data: Data) {
        guard data.count == Self.size else { return nil }
        let base = data.startIndex
        func byte(_ at: Int) -> UInt8 { data[base + at] }
        guard byte(5) == 1 else { return nil }
        let seconds = UInt32(byte(0)) | UInt32(byte(1)) << 8 | UInt32(byte(2)) << 16 | UInt32(byte(3)) << 24
        time = Date(timeIntervalSince1970: TimeInterval(seconds))
        healthPercent = Int(byte(4))
        cycles = Int(UInt16(byte(6)) | UInt16(byte(7)) << 8)
    }
}

/// The rules for what History keeps.
public enum HistoryRules {
    /// At most one sample this often.
    public static let sampleInterval: TimeInterval = 60
    /// Samples older than this are thinned to one per hour.
    public static let fullDetail: TimeInterval = 90 * 24 * 3600
    /// Less recorded time than this is "Collecting data", not a chart.
    public static let minimumSpan: TimeInterval = 3600

    public static func shouldRecord(last: Date?, now: Date) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= sampleInterval || now < last
    }

    /// One health snapshot per calendar day, at most.
    public static func shouldRecordHealth(last: Date?, now: Date, calendar: Calendar = .current) -> Bool {
        guard let last else { return true }
        return !calendar.isDate(last, inSameDayAs: now) && now > last
    }

    /// Keeps every sample from the last 90 days and the first sample of
    /// each hour before that. `samples` is in time order, and so is the result.
    public static func thinned(_ samples: [HistorySample], now: Date) -> [HistorySample] {
        let cutoff = now.addingTimeInterval(-fullDetail)
        var kept: [HistorySample] = []
        var lastHour: Int?
        for sample in samples {
            if sample.time >= cutoff {
                kept.append(sample)
            } else {
                let hour = Int(sample.time.timeIntervalSince1970 / 3600)
                if hour != lastHour { kept.append(sample) }
                lastHour = hour
            }
        }
        return kept
    }
}

/// What the charts draw for one stretch of time. Every line has the same
/// number of points, evenly spaced from `start` to `end`: point 0 is at
/// `start` and the last point is at `end`. A point where nothing was
/// measured is `.nan`, and charts leave a gap there: nothing is carried
/// across time that was not recorded.
public struct HistorySeries: Equatable, Sendable {
    public var start: Date
    public var end: Date
    /// The limit, when it was the same for the whole stretch (100 is none).
    /// nil when it changed: one line could not show it truthfully.
    public var limit: Int?
    public var level: [Double] = []
    /// Empty when never measured in this stretch.
    public var temperature: [Double] = []
    public var chargerWatts: [Double] = []
    public var macWatts: [Double] = []

    public static func == (a: HistorySeries, b: HistorySeries) -> Bool {
        func same(_ x: [Double], _ y: [Double]) -> Bool {
            x.count == y.count && zip(x, y).allSatisfy { ($0.isNaN && $1.isNaN) || $0 == $1 }
        }
        return a.start == b.start && a.end == b.end && a.limit == b.limit && same(a.level, b.level)
            && same(a.temperature, b.temperature) && same(a.chargerWatts, b.chargerWatts) && same(a.macWatts, b.macWatts)
    }

    /// Builds the series for the `window` seconds before `now`. nil when
    /// what was recorded in that time covers under an hour.
    public static func build(samples: [HistorySample], window: TimeInterval, now: Date, points: Int) -> HistorySeries? {
        let from = now.addingTimeInterval(-window)
        let inside = samples.filter { $0.time >= from && $0.time <= now }
        guard let first = inside.first, let last = inside.last, points >= 2, window > 0,
              last.time.timeIntervalSince(first.time) >= HistoryRules.minimumSpan else { return nil }
        let limits = Set(inside.map(\.limit))
        var series = HistorySeries(start: from, end: now, limit: limits.count == 1 ? limits.first : nil)
        // Each sample goes to the point nearest to it in time.
        var buckets = [[HistorySample]](repeating: [], count: points)
        for sample in inside {
            let position = sample.time.timeIntervalSince(from) / window
            buckets[min(max(Int((position * Double(points - 1)).rounded()), 0), points - 1)].append(sample)
        }
        func line(_ value: (HistorySample) -> Double?) -> [Double] {
            let out = buckets.map { bucket -> Double in
                let values = bucket.compactMap(value)
                return values.isEmpty ? .nan : values.reduce(0, +) / Double(values.count)
            }
            return out.contains { !$0.isNaN } ? out : []
        }
        series.level = line { Double($0.percent) }
        series.temperature = line(\.temperatureC)
        series.chargerWatts = line(\.chargerWatts)
        series.macWatts = line(\.macWatts)
        return series
    }

    /// Battery health along the same axis. Health is a daily figure, so each
    /// point shows the latest snapshot at or before its time; points before
    /// the first snapshot are `.nan`. Empty when there is no snapshot at all.
    public static func healthLine(_ snapshots: [HealthSnapshot], start: Date, end: Date, points: Int) -> [Double] {
        let sorted = snapshots.filter { $0.time <= end }.sorted { $0.time < $1.time }
        guard !sorted.isEmpty, points >= 2 else { return [] }
        let step = end.timeIntervalSince(start) / Double(points - 1)
        var next = 0
        var current = Double.nan
        return (0..<points).map { index in
            let time = start.addingTimeInterval(Double(index) * step)
            while next < sorted.count, sorted[next].time <= time {
                current = Double(sorted[next].healthPercent)
                next += 1
            }
            return current
        }
    }
}

/// History on disk: two append-only files of fixed-size records. Safe to
/// call from any thread.
public final class HistoryStore: @unchecked Sendable {
    private let samplesURL: URL
    private let healthURL: URL
    private let lock = NSLock()

    /// `file` holds the samples; health snapshots go in a file beside it.
    public init(file: URL) {
        samplesURL = file
        healthURL = file.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent + "-health")
    }

    public func append(_ sample: HistorySample) {
        lock.withLock { append(sample.encoded(), to: samplesURL) }
    }

    /// Samples in time order, optionally only those at or after `since`.
    public func samples(since: Date? = nil) -> [HistorySample] {
        let all: [HistorySample] = lock.withLock { records(in: samplesURL, size: HistorySample.size, HistorySample.init(encoded:)).found }
        // Appends arrive in time order, so sorting is rarely needed.
        let inOrder = zip(all, all.dropFirst()).allSatisfy { $0.time <= $1.time }
        let sorted = inOrder ? all : all.sorted { $0.time < $1.time }
        guard let since else { return sorted }
        return sorted.filter { $0.time >= since }
    }

    /// Adds a health snapshot unless one was already saved today. True when added.
    @discardableResult
    public func appendHealth(_ snapshot: HealthSnapshot, calendar: Calendar = .current) -> Bool {
        lock.withLock {
            let last = records(in: healthURL, size: HealthSnapshot.size, HealthSnapshot.init(encoded:)).found.map(\.time).max()
            guard HistoryRules.shouldRecordHealth(last: last, now: snapshot.time, calendar: calendar) else { return false }
            append(snapshot.encoded(), to: healthURL)
            return true
        }
    }

    public func healthSnapshots() -> [HealthSnapshot] {
        lock.withLock { records(in: healthURL, size: HealthSnapshot.size, HealthSnapshot.init(encoded:)).found }
            .sorted { $0.time < $1.time }
    }

    /// Rewrites the samples file with old samples thinned. Returns how many
    /// were dropped. A file with records this build cannot read (written by
    /// a newer one, or damaged) is left exactly as it is.
    @discardableResult
    public func thin(now: Date) -> Int {
        lock.withLock {
            let read = records(in: samplesURL, size: HistorySample.size, HistorySample.init(encoded:))
            guard read.unreadable == 0 else { return 0 }
            let all = read.found.sorted { $0.time < $1.time }
            let kept = HistoryRules.thinned(all, now: now)
            guard kept.count < all.count else { return 0 }
            var data = Data(capacity: kept.count * HistorySample.size)
            for sample in kept { data.append(sample.encoded()) }
            try? data.write(to: samplesURL, options: .atomic)
            return all.count - kept.count
        }
    }

    public var sizeInBytes: Int {
        lock.withLock {
            [samplesURL, healthURL].reduce(0) { total, url in
                total + ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0)
            }
        }
    }

    private func append(_ record: Data, to url: URL) {
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            manager.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        // A write cut short (a crash, a full disk) leaves a partial record.
        // Start the next one on a record boundary so the rest stays readable.
        let end = (try? handle.seekToEnd()) ?? 0
        let extra = end % UInt64(record.count)
        if extra != 0 { try? handle.truncate(atOffset: end - extra) }
        try? handle.write(contentsOf: record)
    }

    /// Every record that decodes, and how many whole records did not.
    private func records<T>(in url: URL, size: Int, _ decode: (Data) -> T?) -> (found: [T], unreadable: Int) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return ([], 0) }
        var out: [T] = []
        out.reserveCapacity(data.count / size)
        var unreadable = 0
        var offset = data.startIndex
        while offset + size <= data.endIndex {
            if let record = decode(data[offset..<offset + size]) { out.append(record) } else { unreadable += 1 }
            offset += size
        }
        return (out, unreadable)
    }
}

/// Watts along the power flow card.
public struct PowerFlow: Equatable, Sendable {
    public var charger: Double?
    public var mac: Double?
    /// Positive into the battery, negative out of it.
    public var battery: Double?
    /// The arrow between the Mac and the battery points to the Mac.
    public var batteryFeedsMac: Bool

    public init(_ reading: BatteryReading?) {
        // Off the charger nothing comes from it, whatever a stale reading says.
        charger = reading.map { $0.isPluggedIn ? $0.chargerWatts : 0 } ?? nil
        mac = reading?.systemWatts
        battery = reading?.batteryWatts
        batteryFeedsMac = (battery ?? 0) < 0
    }
}
