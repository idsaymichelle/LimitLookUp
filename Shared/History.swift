import Foundation

/// One reading of one limit. Kept only on this device, for the history chart and the activity grid.
struct Sample: Codable, Equatable {
    let t: Date
    let account: String
    let limit: String
    let p: Double
}

enum History {
    static let keep: TimeInterval = 90 * 86400
    /// Readings closer than this to the previous one for the same limit are skipped, unless the value moved.
    static let minGap: TimeInterval = 20 * 60

    static var url: URL {
        let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Store.group)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LimitLookUp")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }

    static func load() -> [Sample] {
        (try? JSONDecoder().decode([Sample].self, from: Data(contentsOf: url))) ?? []
    }

    static func save(_ s: [Sample]) {
        try? JSONEncoder().encode(s).write(to: url, options: .atomic)
    }

    /// Adds the current readings and drops anything older than 90 days.
    static func record(_ usage: [ServiceUsage], into old: [Sample], now: Date = .now) -> [Sample] {
        var all = old.filter { now.timeIntervalSince($0.t) < keep }
        for u in usage where u.error == nil {
            for l in u.limits {
                let last = all.last { $0.account == u.service && $0.limit == l.name }
                if let last, now.timeIntervalSince(last.t) < minGap, abs(last.p - l.percent) < 1 { continue }
                all.append(Sample(t: now, account: u.service, limit: l.name, p: l.percent))
            }
        }
        return all
    }

    enum Range: String, CaseIterable, Identifiable {
        case h12 = "12h", h24 = "24h", d3 = "3d", d7 = "7d", d30 = "30d", d90 = "90d"
        var id: String { rawValue }
        /// Short label for the range switch, in the user's language.
        var label: String { L(String.LocalizationValue(rawValue)) }
        var span: TimeInterval {
            switch self { case .h12: 12 * 3600; case .h24: 86400; case .d3: 3 * 86400
            case .d7: 7 * 86400; case .d30: 30 * 86400; case .d90: 90 * 86400 }
        }
        /// Bar width: hours for short ranges, days, then weeks.
        var bucket: TimeInterval {
            switch self { case .h12: 3600; case .h24: 2 * 3600; case .d3: 6 * 3600
            case .d7, .d30: 86400; case .d90: 7 * 86400 }
        }
    }

    struct Bar: Identifiable, Equatable { let start: Date; let peak: Double; var id: Date { start } }

    /// Highest reading in each bucket; empty buckets are 0 so gaps stay visible.
    static func bars(_ samples: [Sample], account: String, limit: String, range: Range, now: Date = .now,
                     calendar: Calendar = .current) -> [Bar] {
        let alignedNow = range.bucket >= 86400 ? calendar.startOfDay(for: now) : calendar.dateInterval(of: .hour, for: now)?.start ?? now
        let count = Int((range.span / range.bucket).rounded())
        let first = alignedNow.addingTimeInterval(-range.bucket * Double(count - 1))
        var peaks = Array(repeating: 0.0, count: count)
        for s in samples where s.account == account && s.limit == limit && s.t >= first {
            let i = Int(s.t.timeIntervalSince(first) / range.bucket)
            if i >= 0 && i < count { peaks[i] = max(peaks[i], s.p) }
        }
        return peaks.enumerated().map { Bar(start: first.addingTimeInterval(range.bucket * Double($0.offset)), peak: $0.element) }
    }

    struct Overview: Equatable {
        var weekPeak: Double      // highest reading of any limit in the last 7 days
        var daysNearLimit: Int    // days in the last 30 whose session peak reached the threshold
        var activeDays: Int       // days in the last 30 with any use
        var busiestWeekday: Int?  // 1 = Sunday … 7 = Saturday, by average session peak over 30 days
    }

    static func overview(_ samples: [Sample], threshold: Double, now: Date = .now, calendar: Calendar = .current) -> Overview {
        let week = samples.filter { now.timeIntervalSince($0.t) < 7 * 86400 }
        let days = activity(samples, days: 30, now: now, calendar: calendar)
        var byWeekday: [Int: [Double]] = [:]
        for (d, v) in days where v > 0 { byWeekday[calendar.component(.weekday, from: d), default: []].append(v) }
        let busiest = byWeekday.max { $0.value.reduce(0, +) / Double($0.value.count) < $1.value.reduce(0, +) / Double($1.value.count) }?.key
        return Overview(weekPeak: week.map(\.p).max() ?? 0,
                        daysNearLimit: days.values.filter { $0 >= threshold }.count,
                        activeDays: days.values.filter { $0 > 0 }.count,
                        busiestWeekday: busiest)
    }

    /// Per day, the highest 5-hour-window reading across all accounts (falls back to any limit).
    static func activity(_ samples: [Sample], days: Int, now: Date = .now, calendar: Calendar = .current) -> [Date: Double] {
        let from = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: now))!
        var out: [Date: Double] = [:]
        let session = samples.filter { $0.limit == "5 hours" }
        for s in (session.isEmpty ? samples : session) where s.t >= from {
            let d = calendar.startOfDay(for: s.t)
            out[d] = max(out[d] ?? 0, s.p)
        }
        return out
    }

    /// Plausible readings for demo mode and App Review screenshots.
    static func demo(for usage: [ServiceUsage], now: Date = .now) -> [Sample] {
        var out: [Sample] = []
        var seed: UInt64 = 42
        func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 33) / Double(1 << 31) }
        for u in usage {
            for l in u.limits {
                var t = now.addingTimeInterval(-keep)
                while t < now {
                    let weekday = Calendar.current.component(.weekday, from: t)
                    let day = Int(t.timeIntervalSince1970 / 86400)
                    // Each day gets its own intensity so the activity grid is not uniform.
                    let dayLevel = Double((day &* 2654435761) % 100) / 100
                    let busy = (2...6).contains(weekday) ? 1.0 : 0.3
                    out.append(Sample(t: t, account: u.service, limit: l.name, p: min(100, (0.3 + 0.7 * rnd()) * 100 * busy * dayLevel)))
                    t = t.addingTimeInterval(3 * 3600)
                }
                out.append(Sample(t: now, account: u.service, limit: l.name, p: l.percent))
            }
        }
        return out
    }
}
