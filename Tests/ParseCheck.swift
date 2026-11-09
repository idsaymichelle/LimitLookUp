// Self-check for response parsing. Run: swiftc -parse-as-library Shared/Models.swift Shared/Theme.swift Shared/History.swift Shared/Lang.swift Shared/CloudSync.swift App/Fetcher.swift Tests/ParseCheck.swift -o /tmp/pc && /tmp/pc
import Foundation
@main struct ParseCheck {
    @MainActor static func main() throws {
        let c = try Fetcher.parse(.claude, #"{"five_hour":{"utilization":42,"resets_at":"2026-11-08T05:00:00.123+00:00"},"seven_day":{"utilization":7.5,"resets_at":null},"seven_day_opus":null,"extra":5}"#)
        assert(c.error == nil && c.limits.map(\.name) == ["5 hours", "Week"], "\(c)")
        assert(c.limits[0].percent == 42 && c.limits[0].resetsAt != nil && c.limits[1].resetsAt == nil)
        let x = try Fetcher.parse(.codex, #"{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":4,"reset_at":1762578000,"limit_window_seconds":18000},"secondary_window":{"used_percent":61,"reset_at":1763000000,"limit_window_seconds":604800}}}"#)
        assert(x.limits.map(\.name) == ["5 hours", "Week"] && x.limits[1].percent == 61, "\(x)")
        let y = try Fetcher.parse(.codex, #"{"rate_limit":{"primary_window":{"used_percent":9,"reset_after_seconds":600,"limit_window_seconds":18000}}}"#)
        assert(y.limits.first?.resetsAt != nil, "reset_after_seconds fallback")
        let b = try Fetcher.parse(.claude, #"{"error":"blocked"}"#)
        assert(b.error?.hasPrefix("The site wants") == true)
        let e = try Fetcher.parse(.codex, #"{"error":"auth"}"#)
        assert(e.error == "Sign in to see your limits.")
        // Kimi: CodexBar fixture shape, numbers as strings
        let k = try Fetcher.parse(.kimi, #"{"usages":[{"scope":"FEATURE_CODING","detail":{"limit":"100","used":"25","remaining":"75","resetTime":"2026-11-15T00:00:00Z"},"limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"50","remaining":"10"}}]}]}"#)
        assert(k.error == nil && k.limits.map(\.name) == ["5 hours", "Week"], "\(k)")
        assert(k.limits[0].percent == 80 && k.limits[1].percent == 25 && k.limits[1].resetsAt != nil, "\(k)")
        let ki = try Fetcher.parse(.kimiIntl, #"{"usages":[{"scope":"FEATURE_CODING","detail":{"limit":10,"used":5}}]}"#)
        assert(ki.service == "Kimi Code (kimi.ai)" && ki.limits.first?.percent == 50, "\(ki)")
        // Qwen Cloud: CodexBar fixture, fractions and millisecond timestamps, nested under "data"
        let q = try Fetcher.parse(.qwen, #"{"code":"200","data":{"per5HourPercentage":0.03,"per5HourResetTime":1700003600000,"per1WeekPercentage":0.01,"per1WeekResetTime":1700086400000}}"#)
        assert(q.limits.map(\.name) == ["5 hours", "Week"] && abs(q.limits[0].percent - 3) < 0.001, "\(q)")
        assert(q.limits[0].resetsAt == Date(timeIntervalSince1970: 1_700_003_600), "\(q)")
        let ke = try Fetcher.parse(.kimi, #"{"usages":[]}"#)
        assert(ke.error?.hasPrefix("The site sent no") == true)
        assert(c.limits[0].window == 18000 && c.limits[1].window == 604800 && k.limits[1].window == 604800 && x.limits[0].window == 18000)
        // Pace: 2.5 h left of a 5 h window = half elapsed
        let now = Date(timeIntervalSince1970: 2_000_000), half = now.addingTimeInterval(9000)
        assert(Limit(name: "a", percent: 80, resetsAt: half, window: 18000).pace(now: now) == .fast)
        assert(Limit(name: "a", percent: 50, resetsAt: half, window: 18000).pace(now: now) == .even)
        assert(Limit(name: "a", percent: 20, resetsAt: half, window: 18000).pace(now: now) == .spare)
        assert(Limit(name: "a", percent: 80, resetsAt: half).pace(now: now) == nil, "no window, no pace")
        // Rate: 50% over 2.5 elapsed hours = 20%/h; reset text has relative and absolute parts
        assert(abs((Limit(name: "a", percent: 50, resetsAt: half, window: 18000).ratePerHour(now: now) ?? 0) - 20) < 0.01)
        let rt = Limit(name: "a", percent: 1, resetsAt: half, window: 18000).resetText(now: now) ?? ""
        assert(rt.hasPrefix("in 2") && rt.contains("("), rt)
        // History: throttling, 90-day pruning, bucket peaks
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let t0h = Date(timeIntervalSince1970: 1_800_000_000)
        let use = [ServiceUsage(service: "A", limits: [Limit(name: "5 hours", percent: 10, resetsAt: nil)], updated: t0h, error: nil)]
        var hist = History.record(use, into: [Sample(t: t0h.addingTimeInterval(-100 * 86400), account: "A", limit: "5 hours", p: 1)], now: t0h)
        assert(hist.count == 1, "old sample pruned, new one added")
        hist = History.record(use, into: hist, now: t0h.addingTimeInterval(60))
        assert(hist.count == 1, "same value within 20 min is skipped")
        hist.append(Sample(t: t0h.addingTimeInterval(-86400), account: "A", limit: "5 hours", p: 70))
        let bars = History.bars(hist, account: "A", limit: "5 hours", range: .d7, now: t0h, calendar: cal)
        assert(bars.count == 7 && bars.last?.peak == 10 && bars[5].peak == 70, "\(bars.map(\.peak))")
        assert(History.activity(hist, days: 7, now: t0h, calendar: cal).count == 2)
        // Overview: two days, one above an 80% threshold
        let ov = History.overview(hist, threshold: 50, now: t0h, calendar: cal)
        assert(ov.weekPeak == 70 && ov.daysNearLimit == 1 && ov.activeDays == 2 && ov.busiestWeekday != nil, "\(ov)")
        // Alert keys: a few seconds of drift is the same window; old entries are dropped
        let r1 = Date(timeIntervalSince1970: 1_900_000_000)
        assert(AlertLog.key(service: "Codex", limit: "5 hours", resetsAt: r1) == AlertLog.key(service: "Codex", limit: "5 hours", resetsAt: r1.addingTimeInterval(40)))
        assert(AlertLog.key(service: "Codex", limit: "5 hours", resetsAt: r1) != AlertLog.key(service: "Codex", limit: "5 hours", resetsAt: r1.addingTimeInterval(18000)))
        assert(AlertLog.pruned(["old": r1, "new": r1.addingTimeInterval(3 * 86400)], now: r1.addingTimeInterval(2 * 86400)).keys.sorted() == ["new"])
        // Fable limit on Max: picked up as its own weekly row; missing (null) on plans without it
        let fb = try Fetcher.parse(.claude, #"{"five_hour":{"utilization":10,"resets_at":null},"seven_day":{"utilization":20,"resets_at":null},"seven_day_fable":{"utilization":34,"resets_at":null},"_plan":"default_claude_max_5x"}"#)
        assert(fb.limits.map(\.name).contains("Week, Fable") && fb.plan == "Max 5x", "\(fb)")
        let nw = try Fetcher.parse(.claude, #"{"five_hour":{"utilization":1,"resets_at":null},"seven_day_opus_4":{"utilization":2,"resets_at":null},"five_hour_fable":{"utilization":3,"resets_at":null}}"#)
        assert(nw.limits.map(\.name) == ["5 hours", "5 hours, Fable", "Week, Opus 4"], "\(nw.limits.map(\.name))")
        assert(nw.limits.map(\.window) == [18000, 18000, 604800])
        let ns = try Fetcher.parse(.claude, #"{"five_hour":{"utilization":5,"resets_at":null},"seven_day":{"utilization":82,"resets_at":null},"seven_day_opus":null,"limits":[{"kind":"session","group":"session","percent":5,"resets_at":"2026-11-10T01:29:59.552459+00:00","scope":null},{"kind":"weekly_all","group":"weekly","percent":82,"resets_at":"2026-11-11T20:59:59.552480+00:00","scope":null},{"kind":"weekly_scoped","group":"weekly","percent":0,"resets_at":"2026-11-11T20:59:59.552794+00:00","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null}}],"seven_day_breakdown":{"rows":[{"key":"chat","percent":0}]}}"#)
        assert(ns.limits.map(\.name) == ["5 hours", "Week", "Week, Fable"], "\(ns.limits.map(\.name))")
        assert(ns.limits.map(\.window) == [18000, 604800, 604800] && ns.limits[2].resetsAt != nil)
        let pr = try Fetcher.parse(.claude, #"{"five_hour":{"utilization":10,"resets_at":null},"seven_day_fable":null,"_plan":"claude_pro"}"#)
        assert(!pr.limits.map(\.name).contains("Week, Fable") && pr.plan == "Pro", "\(pr)")
        // Cloud sync: an account already signed in here is not shown again from another device
        let lim = [Limit(name: "5 hours", percent: 10, resetsAt: nil)]
        let mine = ServiceUsage(service: "Claude Code", limits: lim, updated: .now, error: nil, identity: "a@x.com")
        let snap = CloudSync.Snapshot(device: "iPhone", updated: .now, usage: [
            ServiceUsage(service: "Claude Code 2", limits: lim, updated: .now, error: nil, identity: "a@x.com"),
            ServiceUsage(service: "Codex", limits: lim, updated: .now, error: nil, identity: "a@x.com")])
        let miss = CloudSync.missing(from: [mine], in: [snap])
        assert(miss.count == 1 && miss[0].usage.service == "Codex" && miss[0].device == "iPhone", "\(miss)")
        // Same Codex account under a numbered name on the other device is still recognised
        let codex2 = CloudSync.Snapshot(device: "Mac", updated: .now, usage: [
            ServiceUsage(service: "Codex 2", limits: lim, updated: .now, error: nil, identity: "a@x.com")])
        let localCodex = ServiceUsage(service: "Codex", limits: lim, updated: .now, error: nil, identity: "a@x.com")
        assert(CloudSync.missing(from: [localCodex], in: [codex2]).isEmpty, "Codex 2 matched by email")
        assert(Set(CloudSync.serviceTitles) == Set(Service.allCases.map(\.title)), "sync titles match services")
        // History sync: readings from another device land on the matching local account (by email), as hourly peaks
        let h0 = Date(timeIntervalSince1970: 3600 * 500_000)
        let mine2 = [ServiceUsage(service: "Claude Code", limits: lim, updated: h0, error: nil, identity: "a@x.com")]
        let remoteUsage = [ServiceUsage(service: "Claude Code 2", limits: lim, updated: h0, error: nil, identity: "a@x.com")]
        let remoteSamples = [Sample(t: h0, account: "Claude Code 2", limit: "seven_day", p: 40),
                             Sample(t: h0.addingTimeInterval(600), account: "Claude Code 2", limit: "seven_day", p: 55)]
        let ser = CloudSync.series(remoteSamples, usage: remoteUsage, now: h0.addingTimeInterval(3600))
        assert(ser.count == 1 && ser[0].points == [[500_000, 55]], "\(ser)")
        let back = CloudSync.remoteSamples(local: mine2, in: [CloudSync.Snapshot(device: "iPhone", updated: h0, usage: remoteUsage, history: ser)])
        assert(back.count == 1 && back[0].account == "Claude Code" && back[0].p == 55, "\(back)")
        // A script redirect cancels the first load; that is not a failure
        assert(Fetcher.isInterrupted(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)))
        assert(!Fetcher.isInterrupted(URLError(.timedOut)))
        // Early reset detection
        let t0 = Date(timeIntervalSince1970: 1_000_000), sched = t0.addingTimeInterval(3 * 3600)
        let high = EarlyReset.State(percent: 70, resetsAt: sched)
        let low = Limit(name: "5 hours", percent: 0, resetsAt: nil)
        let s1 = EarlyReset.check(previous: high, current: low, now: t0)
        assert(!s1.notify && s1.next.pendingLow, "first low sample only arms")
        assert(EarlyReset.check(previous: s1.next, current: low, now: t0.addingTimeInterval(600)).notify, "second low confirms")
        let moved = Limit(name: "5 hours", percent: 1, resetsAt: sched.addingTimeInterval(5 * 3600))
        assert(EarlyReset.check(previous: high, current: moved, now: t0).notify, "moved reset time confirms at once")
        assert(!EarlyReset.check(previous: high, current: low, now: sched.addingTimeInterval(10)).notify, "on-time reset is not early")
        let blip = EarlyReset.check(previous: s1.next, current: Limit(name: "5 hours", percent: 71, resetsAt: sched), now: t0)
        assert(!blip.notify && !blip.next.pendingLow, "glitch then normal clears pending")
        print("ok")
    }
}
