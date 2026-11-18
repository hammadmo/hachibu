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
        func tenths(_ value: Double?) -> Int { Int(((value ?? 0) * 10).rounded()) }
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
        let bytes = [UInt8](data)
        func u16(_ at: Int) -> UInt16 { UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8 }
        guard bytes[13] == Self.version else { return nil }
        let seconds = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        let flags = bytes[5]
        time = Date(timeIntervalSince1970: TimeInterval(seconds))
        percent = Int(bytes[4])
        isPluggedIn = flags & 1 != 0
        isCharging = flags & 2 != 0
        temperatureC = flags & 4 != 0 ? Double(Int16(bitPattern: u16(6))) / 10 : nil
        chargerWatts = flags & 8 != 0 ? Double(u16(8)) / 10 : nil
        macWatts = flags & 16 != 0 ? Double(u16(10)) / 10 : nil
        limit = Int(bytes[12])
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
        let bytes = [UInt8](data)
        guard bytes[5] == 1 else { return nil }
        let seconds = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        time = Date(timeIntervalSince1970: TimeInterval(seconds))
        healthPercent = Int(bytes[4])
        cycles = Int(UInt16(bytes[6]) | UInt16(bytes[7]) << 8)
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

/// What the charts draw for one stretch of time: every series has the same
/// number of points, evenly spaced from `start` to `end`.
public struct HistorySeries: Equatable, Sendable {
    public var start: Date
    public var end: Date
    public var limit: Int
    public var level: [Double] = []
    public var temperature: [Double] = []
    public var chargerWatts: [Double] = []
    public var macWatts: [Double] = []

    /// Builds the series for the last `window` seconds. It starts at the
    /// first sample, never earlier, so nothing is drawn for time that was
    /// not recorded. A stretch with no samples inside (the Mac asleep, or
    /// Hachibu not running) keeps the value before it. nil when there is
    /// under an hour of data.
    public static func build(samples: [HistorySample], window: TimeInterval, now: Date, points: Int) -> HistorySeries? {
        let from = now.addingTimeInterval(-window)
        let inside = samples.filter { $0.time >= from && $0.time <= now }
        guard let first = inside.first, let last = inside.last, points >= 2,
              last.time.timeIntervalSince(first.time) >= HistoryRules.minimumSpan else { return nil }
        let span = now.timeIntervalSince(first.time)
        var series = HistorySeries(start: first.time, end: now, limit: last.limit)
        var buckets = [[HistorySample]](repeating: [], count: points)
        for sample in inside {
            let position = sample.time.timeIntervalSince(first.time) / span
            buckets[min(Int(position * Double(points)), points - 1)].append(sample)
        }
        func line(_ value: (HistorySample) -> Double?) -> [Double] {
            var out: [Double] = []
            var carried = inside.lazy.compactMap(value).first
            for bucket in buckets {
                let values = bucket.compactMap(value)
                if !values.isEmpty { carried = values.reduce(0, +) / Double(values.count) }
                if let carried { out.append(carried) }
            }
            return out.count == points ? out : []
        }
        series.level = line { Double($0.percent) }
        series.temperature = line(\.temperatureC)
        series.chargerWatts = line(\.chargerWatts)
        series.macWatts = line(\.macWatts)
        return series
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
        let all: [HistorySample] = lock.withLock { records(in: samplesURL, size: HistorySample.size, HistorySample.init(encoded:)) }
        let sorted = all.sorted { $0.time < $1.time }
        guard let since else { return sorted }
        return sorted.filter { $0.time >= since }
    }

    /// Adds a health snapshot unless one was already saved today. True when added.
    @discardableResult
    public func appendHealth(_ snapshot: HealthSnapshot, calendar: Calendar = .current) -> Bool {
        lock.withLock {
            let last = records(in: healthURL, size: HealthSnapshot.size, HealthSnapshot.init(encoded:)).map(\.time).max()
            guard HistoryRules.shouldRecordHealth(last: last, now: snapshot.time, calendar: calendar) else { return false }
            append(snapshot.encoded(), to: healthURL)
            return true
        }
    }

    public func healthSnapshots() -> [HealthSnapshot] {
        lock.withLock { records(in: healthURL, size: HealthSnapshot.size, HealthSnapshot.init(encoded:)) }
            .sorted { $0.time < $1.time }
    }

    /// Rewrites the samples file with old samples thinned. Returns how many were dropped.
    @discardableResult
    public func thin(now: Date) -> Int {
        lock.withLock {
            let all = records(in: samplesURL, size: HistorySample.size, HistorySample.init(encoded:)).sorted { $0.time < $1.time }
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

    private func records<T>(in url: URL, size: Int, _ decode: (Data) -> T?) -> [T] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        var out: [T] = []
        out.reserveCapacity(data.count / size)
        var offset = data.startIndex
        while offset + size <= data.endIndex {
            if let record = decode(data.subdata(in: offset..<offset + size)) { out.append(record) }
            offset += size
        }
        return out
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
