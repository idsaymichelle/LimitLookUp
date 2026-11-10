import SwiftUI
#if os(iOS)
import UIKit
#endif
import WebKit
import WidgetKit
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published var usage = Store.load()
    /// Local readings for the history chart and activity grid (demo mode shows generated ones).
    @Published var history = History.load()
    /// Readings from the user's other devices (iCloud), so every device shows the same stats.
    @Published var remoteHistory: [Sample] = []
    /// What the Stats screen shows: this device's readings plus the other devices'.
    var statsHistory: [Sample] { remoteHistory.isEmpty ? history : (history + remoteHistory).sorted { $0.t < $1.t } }
    @Published var loading = false
    /// Accounts signed in on the user's other devices (iCloud), shown read-only.
    @Published var remote: [(device: String, usage: ServiceUsage)] = []
    /// Bumped after each finished refresh; drives the success haptic.
    @Published var refreshCount = 0
    /// Signed-in sessions, several per service allowed. Only these are shown and refreshed.
    @Published var accounts: [Account] = AppModel.loadAccounts() {
        didSet { Store.defaults.set(try? JSONEncoder().encode(accounts), forKey: "accounts") }
    }
    private let fetcher = Fetcher()

    /// A fresh install starts with no accounts; the welcome screen adds the first one.
    private static func loadAccounts() -> [Account] {
        (try? JSONDecoder().decode([Account].self, from: Store.defaults.data(forKey: "accounts") ?? Data())) ?? []
    }

    /// New accounts of a service already present get a number, so they can be told apart until renamed.
    /// Uses the smallest free number, so names stay short; a removed account's history is deleted with it.
    func addAccount(_ s: Service) -> Account {
        let taken = Set(accounts.filter { $0.service == s }.map { $0.label.map { Int($0) ?? 0 } ?? 1 })
        let n = (1...).first { !taken.contains($0) }!
        let a = Account(service: s, label: n == 1 ? nil : "\(n)")
        accounts.append(a)
        return a
    }

    func rename(_ a: Account, to label: String) {
        guard let i = accounts.firstIndex(of: a) else { return }
        let t = label.trimmingCharacters(in: .whitespaces)
        let old = accounts[i].title
        accounts[i].label = t.isEmpty ? nil : t
        let new = accounts[i].title
        // History is keyed by title; move it so the chart keeps the account's past readings.
        history = history.map { $0.account == old ? Sample(t: $0.t, account: new, limit: $0.limit, p: $0.p) : $0 }
        History.save(history)
        if let j = usage.firstIndex(where: { $0.accountID == a.id }) { usage[j].service = accounts[i].title }
        Store.save(usage)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Like `refresh()`, but waits for a refresh already in progress instead of skipping, so the result
    /// includes accounts added just now. Used right after a sign-in sheet closes.
    func refreshAfterLogin() async {
        while loading { try? await Task.sleep(for: .milliseconds(200)) }
        await refresh()
    }

    static var deviceName: String {
        #if os(macOS)
        Host.current().localizedName ?? "Mac"
        #else
        UIDevice.current.model // "iPhone"; the user-chosen name needs a special entitlement
        #endif
    }

    func startCloudSync() {
        CloudSync.start { Task { @MainActor in AppModel.shared.updateRemote() } }
        updateRemote()
    }

    func updateRemote() {
        let snaps = Demo.on ? [] : CloudSync.others()
        remote = CloudSync.missing(from: usage, in: snaps)
        remoteHistory = CloudSync.remoteSamples(local: usage, in: snaps)
    }

    func refresh() async {
        // Demo mode (debug builds only, `-demo`): sample numbers for screenshots. App Review gets a test account instead.
        if Demo.on {
            let h: (Double) -> Date = { .now.addingTimeInterval($0 * 3600) }
            usage = [
                ServiceUsage(service: "Claude Code", limits: [Limit(name: "5 hours", percent: 63, resetsAt: h(2.3), window: 18000),
                                                         Limit(name: "Week", percent: 28, resetsAt: h(90), window: 604800),
                                                         Limit(name: "Week, Fable", percent: 34, resetsAt: h(90), window: 604800)],
                             updated: .now, error: nil, identity: "alex@example.com", name: "Alex Morgan", plan: "Max 5x"),
                ServiceUsage(service: "Claude Code 2", limits: [Limit(name: "5 hours", percent: 22, resetsAt: h(3.6), window: 18000),
                                                                 Limit(name: "Week", percent: 47, resetsAt: h(60), window: 604800)],
                             updated: .now, error: nil, identity: "alex@company.example", name: "Alex Morgan"),
                ServiceUsage(service: "Codex", limits: [Limit(name: "5 hours", percent: 12, resetsAt: h(4), window: 18000),
                                                        Limit(name: "Week", percent: 74, resetsAt: h(51), window: 604800)],
                             updated: .now, error: nil, identity: "alex@example.com", name: "Alex Morgan"),
            ]
            Store.save(usage)
            history = History.demo(for: usage)
            WidgetCenter.shared.reloadAllTimelines()
            #if os(iOS)
            WatchSync.shared.send(usage)
            #endif
            return
        }
        guard !loading else { return }
        loading = true
        defer { loading = false }
        var result: [ServiceUsage] = []
        var fresh: [ServiceUsage] = []
        for a in accounts {
            let r = await fetcher.fetch(a)
            // A failed background load must not wipe good numbers from the widget and watch; keep the last ones,
            // with their old "updated" time so it is clear they are not new.
            if r.temporary == true, let last = usage.first(where: { $0.accountID == a.id && $0.error == nil && !$0.limits.isEmpty }) {
                result.append(last)
            } else {
                result.append(r)
                fresh.append(r)
            }
        }
        // An account removed during this refresh must not come back in the widget, watch or alerts.
        result.removeAll { r in !accounts.contains { $0.id == r.accountID } }
        fresh.removeAll { r in !accounts.contains { $0.id == r.accountID } }
        usage = result
        Store.save(result)
        history = History.record(fresh, into: History.load())
        History.save(history)
        #if os(iOS)
        WatchSync.shared.send(result)
        #endif
        WidgetCenter.shared.reloadAllTimelines()
        Notifier.check(result)
        CloudSync.publish(result, history: history, device: Self.deviceName)
        updateRemote()
        refreshCount += 1
    }

    /// Everything the app stored: accounts and their sign-ins, history, usage, settings, profile, this device's iCloud entry.
    func deleteAll() async {
        while loading { try? await Task.sleep(for: .milliseconds(200)) } // a running refresh would write it all back
        for a in accounts { try? await WKWebsiteDataStore.remove(forIdentifier: a.id) }
        accounts = []; usage = []; history = []; remote = []; remoteHistory = []
        Store.save([]); History.save([])
        CloudSync.removeThisDevice()
        if let d = UserDefaults(suiteName: Store.group) { d.dictionaryRepresentation().keys.forEach(d.removeObject(forKey:)) }
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        WidgetCenter.shared.reloadAllTimelines()
        #if os(iOS)
        WatchSync.shared.send([])
        #endif
    }

    func logout(_ a: Account) async {
        try? await WKWebsiteDataStore.remove(forIdentifier: a.id)
        usage.removeAll { $0.accountID == a.id }
        accounts.removeAll { $0.id == a.id }
        // Its name can be reused by a new account; don't hand over this account's readings.
        history.removeAll { $0.account == a.title }
        History.save(history)
        Store.save(usage)
        WidgetCenter.shared.reloadAllTimelines()
        CloudSync.publish(usage, history: history, device: Self.deviceName) // other devices stop listing it
        Notifier.forget(a.title)
    }
}

enum Notifier {
    static var threshold: Double { Store.defaults.object(forKey: "threshold") as? Double ?? 80 }

    static func request() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// A removed account must not send a "limit reset" alert later, and a new account that reuses its name
    /// must not inherit its "already notified" state.
    static func forget(_ account: String) {
        let center = UNUserNotificationCenter.current()
        let mine: (String) -> Bool = { $0.hasPrefix("notified.\(account).") || $0.hasPrefix("early.\(account).") }
        center.getPendingNotificationRequests { reqs in
            center.removePendingNotificationRequests(withIdentifiers: reqs.map(\.identifier).filter(mine))
        }
        let d = Store.defaults
        if var log = try? JSONDecoder().decode([String: Date].self, from: d.data(forKey: "alertLog") ?? Data()) {
            log = log.filter { !mine($0.key) }
            d.set(try? JSONEncoder().encode(log), forKey: "alertLog")
        }
        if var states = try? JSONDecoder().decode([String: EarlyReset.State].self, from: d.data(forKey: "earlyReset") ?? Data()) {
            states = states.filter { !$0.key.hasPrefix("\(account).") }
            d.set(try? JSONEncoder().encode(states), forKey: "earlyReset")
        }
    }

    /// One alert per limit per reset period, plus an alert when that limit resets.
    static func check(_ usage: [ServiceUsage]) {
        let d = Store.defaults
        let center = UNUserNotificationCenter.current()
        var states = (try? JSONDecoder().decode([String: EarlyReset.State].self,
                                                from: d.data(forKey: "earlyReset") ?? Data())) ?? [:]
        for u in usage {
            for l in u.limits {
                let id = "\(u.service).\(l.name)"
                let (notify, next) = EarlyReset.check(previous: states[id], current: l)
                states[id] = next
                guard notify, d.object(forKey: "notifyEarly") as? Bool ?? true else { continue }
                // The "limit reset" alert scheduled for the old time is now wrong.
                center.getPendingNotificationRequests { reqs in
                    center.removePendingNotificationRequests(withIdentifiers:
                        reqs.map(\.identifier).filter { $0.hasPrefix("notified.\(id).") })
                }
                let c = UNMutableNotificationContent()
                c.title = L("\(u.service): limit reset early")
                c.body = L("The “\(l.title)” limit is available again, earlier than announced.")
                c.sound = .default
                center.add(UNNotificationRequest(identifier: "early.\(id).\(Int(Date.now.timeIntervalSince1970))",
                                                 content: c, trigger: nil))
            }
        }
        d.set(try? JSONEncoder().encode(states), forKey: "earlyReset")
        var sent = AlertLog.pruned((try? JSONDecoder().decode([String: Date].self, from: d.data(forKey: "alertLog") ?? Data())) ?? [:])
        defer { d.set(try? JSONEncoder().encode(sent), forKey: "alertLog") }
        for u in usage {
            for l in u.limits where l.percent >= threshold && d.object(forKey: "notifyThreshold") as? Bool ?? true {
                let key = AlertLog.key(service: u.service, limit: l.name, resetsAt: l.resetsAt)
                guard sent[key] == nil else { continue }
                sent[key] = l.resetsAt ?? .now.addingTimeInterval(86400)
                let c = UNMutableNotificationContent()
                c.title = L("\(u.service): limit almost used up")
                c.body = l.resetsAt.map { L("“\(l.title)”: \(Int(l.percent))% used. Resets at \(Lang.time($0)).") }
                    ?? L("“\(l.title)”: \(Int(l.percent))% used.")
                c.sound = .default
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: key, content: c, trigger: nil))

                if let reset = l.resetsAt, reset > .now, d.object(forKey: "notifyReset") as? Bool ?? true {
                    let r = UNMutableNotificationContent()
                    r.title = L("\(u.service): limit reset")
                    r.body = L("The “\(l.title)” limit is available again.")
                    r.sound = .default
                    let t = UNTimeIntervalNotificationTrigger(timeInterval: reset.timeIntervalSinceNow, repeats: false)
                    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: key + ".reset", content: r, trigger: t))
                }
            }
        }
    }
}
