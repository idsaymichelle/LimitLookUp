import Foundation

/// Shares the account list and percentages between the user's own devices through iCloud key-value storage.
/// Only what is already on screen travels: service, account name/email, plan, limits, reset times. Never cookies,
/// tokens or sign-ins: each device keeps its own login, and accounts from another device are read-only here.
///
/// Needs the `com.apple.developer.ubiquity-kvstore-identifier` entitlement (paid developer team, same identifier
/// on iPhone and Mac). Without it the store is simply empty and the app works as before.
enum CloudSync {
    struct Snapshot: Codable {
        let device: String
        let updated: Date
        let usage: [ServiceUsage]
        /// Hourly peaks of the last 30 days, so every device shows the same stats. Missing in older versions.
        var history: [Series]? = nil
    }

    /// One limit's readings, reduced to the highest value per hour: [hours since 1970, percent].
    struct Series: Codable, Equatable {
        let key: String      // service + email (or name), to find the same account on another device
        let service: String  // display title on the sending device, used when there is no match
        let limit: String
        let points: [[Int]]
    }

    static let historyDays = 30

    private static let store = NSUbiquitousKeyValueStore.default
    private static let prefix = "device."
    /// Snapshots older than this are from a device no longer in use and are ignored.
    private static let maxAge: TimeInterval = 7 * 86400

    /// Stable per-install id, so each device writes only its own key.
    static var deviceID: String {
        if let id = Store.defaults.string(forKey: "deviceID") { return id }
        let id = UUID().uuidString
        Store.defaults.set(id, forKey: "deviceID")
        return id
    }

    static func publish(_ usage: [ServiceUsage], history: [Sample], device: String) {
        let ok = usage.filter { $0.error == nil && !$0.limits.isEmpty }
        let snap = Snapshot(device: device, updated: .now, usage: ok, history: series(history, usage: usage))
        guard let data = try? JSONEncoder().encode(snap) else { return }
        store.set(data, forKey: prefix + deviceID)
        store.synchronize()
    }

    /// Accounts other devices published, newest first, skipping stale devices.
    static func others(now: Date = .now) -> [Snapshot] {
        store.dictionaryRepresentation
            .filter { $0.key.hasPrefix(prefix) && $0.key != prefix + deviceID }
            .compactMap { ($0.value as? Data).flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) } }
            .filter { now.timeIntervalSince($0.updated) < maxAge }
            .sorted { $0.updated > $1.updated }
    }

    /// Same account on any device: service (without the local label, e.g. "Codex 2") plus email, else name.
    static func key(_ u: ServiceUsage) -> String {
        let service = serviceTitles.filter { u.service.hasPrefix($0) }.max { $0.count < $1.count } ?? u.service
        return service + "|" + (u.identity ?? u.name ?? u.service)
    }

    /// This device's readings of the last 30 days as hourly peaks, per account and limit.
    static func series(_ samples: [Sample], usage: [ServiceUsage], now: Date = .now) -> [Series] {
        let keys = Dictionary(usage.map { ($0.service, key($0)) }, uniquingKeysWith: { a, _ in a })
        let since = now.addingTimeInterval(-Double(historyDays) * 86400)
        var peaks: [String: [Int: Int]] = [:]   // "account\u{1}limit" -> hour -> percent
        for s in samples where s.t >= since && keys[s.account] != nil {
            let h = Int(s.t.timeIntervalSince1970 / 3600)
            peaks["\(s.account)\u{1}\(s.limit)", default: [:]][h] = max(peaks["\(s.account)\u{1}\(s.limit)"]?[h] ?? 0, Int(s.p.rounded()))
        }
        return peaks.keys.sorted().compactMap { id in
            let parts = id.split(separator: "\u{1}", maxSplits: 1).map(String.init)
            guard parts.count == 2, let k = keys[parts[0]], let byHour = peaks[id] else { return nil }
            return Series(key: k, service: parts[0], limit: parts[1], points: byHour.keys.sorted().map { [$0, byHour[$0]!] })
        }
    }

    /// Readings other devices took, as samples named after the matching account here (or the sender's name).
    static func remoteSamples(local: [ServiceUsage], in snapshots: [Snapshot]) -> [Sample] {
        let titles = Dictionary(local.map { (key($0), $0.service) }, uniquingKeysWith: { a, _ in a })
        return snapshots.flatMap { snap in
            (snap.history ?? []).flatMap { s in
                s.points.compactMap { p -> Sample? in
                    guard p.count == 2 else { return nil }
                    return Sample(t: Date(timeIntervalSince1970: Double(p[0]) * 3600), account: titles[s.key] ?? s.service,
                                  limit: s.limit, p: Double(p[1]))
                }
            }
        }
    }

    /// Remote accounts not already signed in on this device (matched by service and email, else service and name).
    static func missing(from local: [ServiceUsage], in snapshots: [Snapshot]) -> [(device: String, usage: ServiceUsage)] {
        var seen = Set(local.map(key))
        var out: [(String, ServiceUsage)] = []
        for s in snapshots {
            for u in s.usage where seen.insert(key(u)).inserted { out.append((s.device, u)) }
        }
        return out
    }

    /// Same as `Service.title` in App/Fetcher.swift (not visible to the widget, which also builds this file).
    static let serviceTitles = ["Claude Code", "Codex", "Kimi Code", "Kimi Code (kimi.ai)", "Qwen Cloud"]

    static func removeThisDevice() {
        store.removeObject(forKey: prefix + deviceID)
        store.synchronize()
    }

    static func start(onChange: @escaping @Sendable () -> Void) {
        NotificationCenter.default.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                                               object: store, queue: .main) { _ in onChange() }
        store.synchronize()
    }
}
