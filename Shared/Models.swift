import Foundation
import SwiftUI

struct Limit: Codable, Identifiable, Hashable {
    var id: String { name }
    let name: String
    let percent: Double
    let resetsAt: Date?
    /// Window length in seconds (5 h = 18000, week = 604800); nil when the service does not say.
    var window: Double? = nil

    var color: Color { percent >= 90 ? Theme.over : percent >= 70 ? Theme.warn : Theme.ok }

    /// Share of the window already elapsed, 0...1. Needed to judge pace.
    func elapsed(now: Date = .now) -> Double? {
        guard let window, window > 0, let resetsAt else { return nil }
        return min(max(1 - resetsAt.timeIntervalSince(now) / window, 0), 1)
    }

    /// Average spend per hour since the window started, in percentage points.
    func ratePerHour(now: Date = .now) -> Double? {
        guard let e = elapsed(now: now), let window, e * window >= 600 else { return nil } // too early to be meaningful
        return percent / (e * window / 3600)
    }

    /// Name for display. `name` itself is a stable English key ("5 hours", "Week, Opus") used for history.
    var title: String {
        if name.hasPrefix("Week, ") { return L("Week, \(String(name.dropFirst(6)))") }
        if name.hasPrefix("5 hours, ") { return L("5 hours") + ", " + name.dropFirst(9) }
        return L(String.LocalizationValue(name))
    }

    /// "in 2h 14m (14:30)" within a day, "in 3 days (Mon 09:00)" beyond, in the user's language.
    func resetText(now: Date = .now) -> String? {
        guard let r = resetsAt else { return nil }
        let left = r.timeIntervalSince(now)
        guard left > 0 else { return L("now") }
        let f = DateComponentsFormatter()
        var cal = Calendar.current
        cal.locale = Lang.locale // unit names ("h", "ч", "時間") follow the app language
        f.calendar = cal
        f.maximumUnitCount = 2
        if left < 86400 {
            f.unitsStyle = .abbreviated
            f.allowedUnits = [.hour, .minute]
            let rel = f.string(from: left) ?? ""
            return L("in \(rel) (\(Lang.time(r)))")
        }
        f.unitsStyle = .full
        f.allowedUnits = [.day]
        let rel = f.string(from: (left / 86400).rounded() * 86400) ?? ""
        return L("in \(rel) (\(Lang.weekdayTime(r)))")
    }

    enum Pace { case spare, even, fast }

    /// Compares spent share to elapsed share; a 10-point band counts as "even".
    func pace(now: Date = .now) -> Pace? {
        guard let e = elapsed(now: now), e >= 0.05 else { return nil }
        let used = percent / 100
        return used > e + 0.1 ? .fast : used < e - 0.1 ? .spare : .even
    }
}

struct ServiceUsage: Codable, Hashable {
    /// Display title, including the account label ("Claude Code, Work").
    var service: String
    let limits: [Limit]
    let updated: Date
    let error: String?
    /// Email or name of the signed-in account, as the service reports it. Shown only on this device.
    var identity: String? = nil
    /// The account owner's name, as the service reports it. Shown only on this device.
    var name: String? = nil
    /// Subscription plan as the service reports it ("Max 5x"), if known.
    var plan: String? = nil
    /// Set when the page could not be loaded (network, timeout), as opposed to a signed-out account.
    var temporary: Bool? = nil
    var accountID: UUID? = nil
}

/// Detects a reset the service did on its own, before the announced time.
/// Same idea as CodexBar: a single low sample may be a glitch, so it needs a second low sample
/// unless the reset time itself moved forward (that is proof enough).
enum EarlyReset {
    struct State: Codable { var percent: Double; var resetsAt: Date?; var pendingLow = false }

    /// Returns whether to notify now, and the state to remember for next time.
    static func check(previous: State?, current: Limit, now: Date = .now) -> (notify: Bool, next: State) {
        var next = State(percent: current.percent, resetsAt: current.resetsAt)
        guard let p = previous, p.percent >= 20, current.percent <= 5,
              let scheduled = p.resetsAt, now < scheduled.addingTimeInterval(-60) else { return (false, next) }
        // Usage stays low after a reset, so keep the previous high value while waiting for confirmation.
        if let r = current.resetsAt, r > scheduled.addingTimeInterval(60) { return (true, next) }
        if p.pendingLow { return (true, next) }
        next = State(percent: p.percent, resetsAt: p.resetsAt, pendingLow: true)
        return (false, next)
    }
}

/// Remembers which "almost used up" alerts were sent, one per limit per reset window.
enum AlertLog {
    /// Reset time rounded to 10 minutes: services that report "resets in N seconds" give a slightly
    /// different time on every refresh, which must not count as a new window.
    static func key(service: String, limit: String, resetsAt: Date?) -> String {
        let t = resetsAt.map { Int(($0.timeIntervalSince1970 / 600).rounded()) * 600 } ?? 0
        return "notified.\(service).\(limit).\(t)"
    }

    /// Keeps entries whose window has not ended yet (plus a day), so the log does not grow forever.
    static func pruned(_ log: [String: Date], now: Date = .now) -> [String: Date] {
        log.filter { $0.value > now.addingTimeInterval(-86400) }
    }
}

/// Shared between the app and the widget through an App Group. Only percentages and dates are stored, never cookies or tokens.
enum Store {
    static let group = "group.com.limitlookup.app"
    static var defaults: UserDefaults { UserDefaults(suiteName: group) ?? .standard }

    static func load() -> [ServiceUsage] {
        guard let data = defaults.data(forKey: "usage") else { return [] }
        return (try? JSONDecoder().decode([ServiceUsage].self, from: data)) ?? []
    }

    static func save(_ usage: [ServiceUsage]) {
        defaults.set(try? JSONEncoder().encode(usage), forKey: "usage")
    }
}

/// Sample numbers for screenshots and development: launch a debug build with `-demo`. Never on in release builds.
enum Demo {
    static var on: Bool {
        #if DEBUG
        CommandLine.arguments.contains("-demo")
        #else
        false
        #endif
    }
}

/// Public pages for the app: everything lives in the GitHub repository.
enum Site {
    static let base = URL(string: "https://github.com/idsaymichelle/LimitLookUp")!
    static let privacy = URL(string: "https://github.com/idsaymichelle/LimitLookUp#privacy")!
    static var terms: URL { base.appending(path: "blob/main/LICENSE") }
    static var support: URL { base.appending(path: "issues") }
}
