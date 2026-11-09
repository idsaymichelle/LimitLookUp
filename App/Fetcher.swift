import Foundation
import WebKit

/// One row per AI service. Adding a service = a new case here, its JS request and its parser below.
enum Service: String, CaseIterable, Identifiable, Codable {
    case claude, codex, kimi, kimiIntl, qwen
    var id: String { rawValue }

    /// Services offered in the app right now. Kimi and Qwen stay in the code but are hidden for now.
    static let available: [Service] = [.claude, .codex]

    var title: String {
        switch self {
        case .claude: "Claude Code"; case .codex: "Codex"; case .kimi: "Kimi Code"
        case .kimiIntl: "Kimi Code (kimi.ai)"; case .qwen: "Qwen Cloud"
        }
    }
    var host: String {
        switch self {
        case .claude: "claude.ai"; case .codex: "chatgpt.com"; case .kimi: "www.kimi.com"
        case .kimiIntl: "www.kimi.ai"; case .qwen: "home.qwencloud.com"
        }
    }
    var origin: URL {
        self == .qwen ? loginURL : URL(string: "https://\(host)/")!
    }
    var loginURL: URL {
        switch self {
        case .claude: URL(string: "https://claude.ai/login")!
        case .codex: URL(string: "https://chatgpt.com/auth/login")!
        case .kimi: URL(string: "https://www.kimi.com/code/console")!
        case .kimiIntl: URL(string: "https://www.kimi.ai/code/console")!
        case .qwen: URL(string: "https://home.qwencloud.com/billing/subscription/token-plan-individual")!
        }
    }
    var script: String {
        switch self {
        case .claude: Fetcher.claudeJS; case .codex: Fetcher.codexJS
        case .kimi, .kimiIntl: Fetcher.kimiJS; case .qwen: Fetcher.qwenJS
        }
    }
}

/// One signed-in session. Each account has its own isolated WebKit storage, so several accounts
/// of the same service never share cookies.
struct Account: Codable, Identifiable, Hashable {
    var id = UUID()
    let service: Service
    var label: String?

    /// Unique key for this account's data. Shown to people only through `service.title` and the account name.
    var title: String { label.map { "\(service.title) \($0)" } ?? service.title }

    @MainActor var store: WKWebsiteDataStore { WKWebsiteDataStore(forIdentifier: id) }
}

/// Reads limits in an invisible WKWebView: requests go from the service's own page with your cookies,
/// so the session never leaves WebKit's storage and nothing is sent anywhere except the service's own site.
@MainActor
final class Fetcher: NSObject, WKNavigationDelegate {
    private var web: WKWebView?
    private var pending: CheckedContinuation<Void, Error>?
    /// Bumped per page load, so a late timeout from an earlier account cannot cancel the current one.
    private var loadID = 0

    func fetch(_ a: Account) async -> ServiceUsage {
        let s = a.service
        defer { web = nil }
        var result: ServiceUsage
        do {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = a.store
            let w = WKWebView(frame: .zero, configuration: config)
            web = w
            w.navigationDelegate = self
            try await withCheckedThrowingContinuation { c in
                pending = c
                loadID += 1
                let myLoad = loadID
                w.load(URLRequest(url: s.origin))
                // Without this a page that never finishes (no network, challenge loop) would hang refresh forever.
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(25))
                    guard let self, self.loadID == myLoad, let p = self.pending else { return }
                    self.pending = nil
                    w.stopLoading()
                    p.resume(throwing: URLError(.timedOut))
                }
            }
            // Never run the script on a foreign page (for example after a redirect to a login site).
            if let h = w.url?.host, h == s.host || "www." + h == s.host {
                // Kimi's API wants the login token as a Bearer header. It is read locally and sent only back to the
                // same Kimi site. kimi.com keeps it in the `kimi-auth` cookie; kimi.ai may keep it in localStorage (read by the JS).
                var args: [String: Any] = ["token": ""]
                if s == .kimi || s == .kimiIntl {
                    let domain = s == .kimi ? "kimi.com" : "kimi.ai"
                    let cookies = await a.store.httpCookieStore.allCookies()
                    args["token"] = cookies.first { $0.name == "kimi-auth" && $0.domain.hasSuffix(domain) }?.value ?? ""
                }
                let raw = try await w.callAsyncJavaScript(s.script, arguments: args,
                                                          contentWorld: .defaultClient) as? String ?? ""
                result = try Self.parse(s, raw)
            } else {
                result = Self.failure(s, L("Sign in to see your limits."))
            }
        } catch {
            result = Self.failure(s, Self.describe(error))
            result.temporary = true // network trouble, not a signed-out account: keep showing the last numbers
        }
        result.service = a.title
        result.accountID = a.id
        return result
    }

    static func failure(_ s: Service, _ msg: String) -> ServiceUsage {
        ServiceUsage(service: s.title, limits: [], updated: .now, error: msg)
    }

    /// Plain-language errors instead of system strings.
    static func describe(_ error: Error) -> String {
        switch (error as? URLError)?.code {
        case .timedOut: L("The site didn’t respond in 25 seconds. Pull down to try again.")
        case .notConnectedToInternet, .networkConnectionLost: L("No internet connection. Limits will update when you’re back online.")
        default: L("Couldn’t get your limits. Pull down to try again.")
        }
    }

    nonisolated func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
        MainActor.assumeIsolated { pending?.resume(); pending = nil }
    }
    nonisolated func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) {
        MainActor.assumeIsolated { fail(e) }
    }
    nonisolated func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) {
        MainActor.assumeIsolated { fail(e) }
    }
    /// A page that starts a new navigation (a script redirect) cancels the old one; wait for the new one to finish.
    private func fail(_ e: Error) {
        if Self.isInterrupted(e) { return }
        pending?.resume(throwing: e); pending = nil
    }
    nonisolated static func isInterrupted(_ e: Error) -> Bool {
        let n = e as NSError
        return (n.domain == NSURLErrorDomain && n.code == NSURLErrorCancelled) || (n.domain == "WebKitErrorDomain" && n.code == 102)
    }

    // MARK: - Requests (read-only, same-origin)

    nonisolated static let claudeJS = """
    const get = async (p) => {
      const r = await fetch(p, {credentials: 'include', signal: AbortSignal.timeout(15000)});
      if (r.status === 403 && r.headers.get('cf-mitigated')) throw new Error('blocked');
      if (r.status === 401 || r.status === 403) throw new Error('auth');
      if (!r.ok) throw new Error('HTTP ' + r.status);
      return r.json();
    };
    try {
      const orgs = await get('/api/organizations');
      const org = orgs.find(o => (o.capabilities || []).includes('chat')) || orgs[0];
      if (!org) return JSON.stringify({error: 'auth'});
      const usage = await get('/api/organizations/' + org.uuid + '/usage');
      // Which account this is, shown only on this device.
      try {
        const a = await get('/api/account');
        usage._name = a.full_name || a.display_name || a.name || null;
        usage._identity = a.email_address || a.email || null;
      } catch (_) {}
      if (!usage._name && !usage._identity) usage._name = org.name || null;
      // Plan, used to explain which limits exist (Fable models have their own weekly limit on Max).
      usage._plan = org.rate_limit_tier || ((org.capabilities || []).find(c => /max|pro|team|enterprise/i.test(c))) || null;
      return JSON.stringify(usage);
    } catch (e) { return JSON.stringify({error: String(e.message || e)}); }
    """

    nonisolated static let codexJS = """
    try {
      const t = () => AbortSignal.timeout(15000);
      const sr = await fetch('/api/auth/session', {credentials: 'include', signal: t()});
      if (sr.status === 403 && sr.headers.get('cf-mitigated')) return JSON.stringify({error: 'blocked'});
      const s = await sr.json();
      if (!s.accessToken) return JSON.stringify({error: 'auth'});
      const r = await fetch('/backend-api/wham/usage', {headers: {Authorization: 'Bearer ' + s.accessToken}, signal: t()});
      if (r.status === 403 && r.headers.get('cf-mitigated')) return JSON.stringify({error: 'blocked'});
      if (r.status === 401 || r.status === 403) return JSON.stringify({error: 'auth'});
      if (!r.ok) return JSON.stringify({error: 'HTTP ' + r.status});
      const j = await r.json();
      j._name = (s.user && s.user.name) || null;
      j._identity = (s.user && s.user.email) || null;
      return JSON.stringify(j);
    } catch (e) { return JSON.stringify({error: String(e.message || e)}); }
    """

    // `token` is passed in as an argument by fetch(). Endpoint and body as in CodexBar's KimiUsageFetcher.
    nonisolated static let kimiJS = """
    try {
      const tk = token || localStorage.getItem('access_token');
      if (!tk) return JSON.stringify({error: 'auth'});
      const r = await fetch('/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages', {
        method: 'POST', credentials: 'include', signal: AbortSignal.timeout(15000),
        headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer ' + tk,
                  'connect-protocol-version': '1', 'x-msh-platform': 'web'},
        body: JSON.stringify({scope: ['FEATURE_CODING']})
      });
      if (r.status === 403 && r.headers.get('cf-mitigated')) return JSON.stringify({error: 'blocked'});
      if (r.status === 401 || r.status === 403) return JSON.stringify({error: 'auth'});
      if (!r.ok) return JSON.stringify({error: 'HTTP ' + r.status});
      return JSON.stringify(await r.json());
    } catch (e) { return JSON.stringify({error: String(e.message || e)}); }
    """

    /// Qwen Cloud Token Plan, as in CodexBar's QwenCloud provider: the console page holds a `sec_token`,
    /// and the usage call goes to Qwen's own data gateway (cs-data.qwencloud.com) with the page's cookies.
    nonisolated static let qwenJS = """
    try {
      const html = document.documentElement.innerHTML;
      const pick = (re) => { const m = html.match(re); return m && m[1]; };
      const cookie = (n) => { const m = document.cookie.match(new RegExp('(?:^|; )' + n + '=([^;]+)')); return m && decodeURIComponent(m[1]); };
      const sec = pick(/"secToken"\\s*:\\s*"([^"]+)"/) || pick(/sec_token\\s*=\\s*"([^"]+)"/) || cookie('sec_token');
      if (!sec) return JSON.stringify({error: 'auth'});
      const api = 'zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage';
      const params = {Api: api, V: '1.0', Data: {commodityCode: 'sfm_tokenplansolo_public_intl', cornerstoneParam: {
        feTraceId: crypto.randomUUID(), feURL: location.href, protocol: 'V2', console: 'ONE_CONSOLE', productCode: 'p_efm',
        domain: location.host, consoleSite: 'QWENCLOUD', userNickName: '', userPrincipalName: '', xsp_lang: 'en-US'}}};
      const body = new URLSearchParams({product: 'sfm_bailian', action: 'IntlBroadScopeAspnGateway', sec_token: sec,
        region: 'ap-southeast-1', language: 'en-US', params: JSON.stringify(params)});
      const headers = {'X-Requested-With': 'XMLHttpRequest'};
      const csrf = cookie('login_aliyunid_csrf') || cookie('csrf');
      if (csrf) { headers['x-xsrf-token'] = csrf; headers['x-csrf-token'] = csrf; }
      const url = 'https://cs-data.qwencloud.com/data/api.json?action=IntlBroadScopeAspnGateway&product=sfm_bailian&api='
        + encodeURIComponent(api) + '&_v=undefined';
      const r = await fetch(url, {method: 'POST', credentials: 'include', body, headers, signal: AbortSignal.timeout(15000)});
      if (r.status === 401 || r.status === 403) return JSON.stringify({error: 'auth'});
      if (!r.ok) return JSON.stringify({error: 'HTTP ' + r.status});
      return JSON.stringify(await r.json());
    } catch (e) { return JSON.stringify({error: String(e.message || e)}); }
    """

    // MARK: - Parsing

    static func parse(_ s: Service, _ raw: String) throws -> ServiceUsage {
        guard let obj = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        if let e = obj["error"] as? String {
            let msg = e == "auth" ? L("Sign in to see your limits.")
                : e == "blocked" ? L("The site wants to check you’re not a robot. Open “Sign in again” and complete the check.") : L("The site returned an error (\(e)). Pull down to try again.")
            return ServiceUsage(service: s.title, limits: [], updated: .now, error: msg)
        }
        var limits: [Limit] = []
        if s == .claude {
            // Newer: {"limits": [{"group": "weekly", "percent": 0, "resets_at": "...", "scope": {"model": {"display_name": "Fable"}}}, ...]}
            // Anthropic adds scoped limits there on its own; each becomes a row.
            for d in (obj["limits"] as? [[String: Any]]) ?? [] {
                guard let u = num(d["percent"]) else { continue }
                let scope = d["scope"] as? [String: Any]
                let label = ["model", "surface"].lazy.compactMap { (scope?[$0] as? [String: Any])?["display_name"] as? String }.first
                let group = d["group"] as? String ?? d["kind"] as? String ?? "limit"
                let base: (name: String, window: Double?) = group == "session" ? ("5 hours", 18000) : group == "weekly" ? ("Week", 604800) : (claudeName(group), nil)
                limits.append(Limit(name: label.map { base.name + ", " + $0 } ?? base.name, percent: u,
                                    resetsAt: (d["resets_at"] as? String).flatMap(parseISO), window: base.window))
            }
            // Older: {"five_hour": {"utilization": 12, "resets_at": "..."}, "seven_day": {...}, "seven_day_opus": {...}}
            if limits.isEmpty {
                for (key, value) in obj {
                    guard let d = value as? [String: Any], let u = num(d["utilization"]) else { continue }
                    limits.append(Limit(name: claudeName(key), percent: u,
                                        resetsAt: (d["resets_at"] as? String).flatMap(parseISO), window: claudeWindow(key)))
                }
            }
            let order = ["5 hours", "Week"]
            limits.sort { (order.firstIndex(of: $0.name) ?? 9, $0.name) < (order.firstIndex(of: $1.name) ?? 9, $1.name) }
        } else if s == .kimi || s == .kimiIntl {
            // {"usages":[{"scope":"FEATURE_CODING","detail":{"limit":"100","used":"25","resetTime":"..."},
            //   "limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{...}}]}]}
            let coding = (obj["usages"] as? [[String: Any]])?.first { $0["scope"] as? String == "FEATURE_CODING" }
            for l in (coding?["limits"] as? [[String: Any]]) ?? [] {
                let w = l["window"] as? [String: Any]
                let units: [String: Double] = ["TIME_UNIT_MINUTE": 1, "TIME_UNIT_HOUR": 60, "TIME_UNIT_DAY": 1440]
                let mult = units[w?["timeUnit"] as? String ?? ""] ?? 0
                let sec = (num(w?["duration"]) ?? 0) * mult * 60
                if let d = l["detail"] as? [String: Any], let lim = kimiLimit(windowName(sec), d, window: sec > 0 ? sec : nil) { limits.append(lim) }
            }
            if let d = coding?["detail"] as? [String: Any], let lim = kimiLimit("Week", d, window: 604800) { limits.append(lim) }
        } else if s == .qwen {
            // Somewhere under Data/data: {"per5HourPercentage": 0.03, "per5HourResetTime": 1700003600000, "per1WeekPercentage": ...}
            if let d = findDict(obj, containing: "per5HourPercentage") ?? findDict(obj, containing: "per1WeekPercentage") {
                for (key, name, window) in [("per5Hour", "5 hours", 18000.0), ("per1Week", "Week", 604800), ("per1Month", "Month", 2_592_000)] {
                    guard let f = num(d[key + "Percentage"]) else { continue }
                    let reset = num(d[key + "ResetTime"]).map { Date(timeIntervalSince1970: $0 > 1e11 ? $0 / 1000 : $0) }
                    limits.append(Limit(name: name, percent: min(max(f <= 1 ? f * 100 : f, 0), 100), resetsAt: reset, window: window))
                }
            }
        } else if let rl = obj["rate_limit"] as? [String: Any] {
            // {"rate_limit": {"primary_window": {"used_percent": 4, "reset_at": 1762..., "limit_window_seconds": 18000}, ...}}
            for key in ["primary_window", "secondary_window"] {
                guard let d = rl[key] as? [String: Any], let u = d["used_percent"] as? Double else { continue }
                let sec = d["limit_window_seconds"] as? Double ?? 0
                limits.append(Limit(name: sec > 0 ? windowName(sec) : key, percent: u,
                                    resetsAt: (d["reset_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
                                        ?? (d["reset_after_seconds"] as? Double).map { Date.now.addingTimeInterval($0) },
                                    window: sec > 0 ? sec : nil))
            }
        }
        return ServiceUsage(service: s.title, limits: limits, updated: .now,
                            error: limits.isEmpty ? L("The site sent no limit data. This account may not have a subscription.") : nil, identity: obj["_identity"] as? String, name: obj["_name"] as? String, plan: (obj["_plan"] as? String).flatMap(planName))
    }

    /// Depth-first search for the first dictionary that has `key`.
    static func findDict(_ v: Any, containing key: String) -> [String: Any]? {
        if let d = v as? [String: Any] {
            if d[key] != nil { return d }
            for x in d.values { if let f = findDict(x, containing: key) { return f } }
        } else if let a = v as? [Any] {
            for x in a { if let f = findDict(x, containing: key) { return f } }
        }
        return nil
    }

    static func windowName(_ sec: Double) -> String {
        sec == 604800 ? "Week" : sec == 18000 ? "5 hours"
            : sec >= 86400 ? "\(Int(sec / 86400)) days" : sec >= 3600 ? "\(Int(sec / 3600)) hours" : "\(Int(sec / 60)) min"
    }

    /// Kimi sends numbers as strings ("100"); accept both.
    static func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue ?? (v as? String).flatMap(Double.init) }

    static func kimiLimit(_ name: String, _ d: [String: Any], window: Double? = nil) -> Limit? {
        guard let limit = num(d["limit"]), limit > 0 else { return nil }
        let used = num(d["used"]) ?? num(d["remaining"]).map { limit - $0 } ?? 0
        let reset = (d["resetTime"] ?? d["reset_time"] ?? d["resetAt"] ?? d["reset_at"]) as? String
        return Limit(name: name, percent: min(max(used / limit * 100, 0), 100), resetsAt: reset.flatMap(parseISO), window: window)
    }

    /// "default_claude_max_5x" → "Max 5x", "claude_pro" → "Pro". Unknown values are left out.
    static func planName(_ raw: String) -> String? {
        let r = raw.lowercased()
        if r.contains("max") { return r.contains("20") ? "Max 20x" : r.contains("5") ? "Max 5x" : "Max" }
        if r.contains("pro") { return "Pro" }
        if r.contains("team") { return "Team" }
        if r.contains("enterprise") { return "Enterprise" }
        return nil
    }

    /// Claude adds per-model limits on its own ("seven_day_fable", "five_hour_opus", …): each becomes its own row.
    static let claudeBases: [(prefix: String, name: String, window: Double)] = [("five_hour", "5 hours", 18000), ("seven_day", "Week", 604800)]

    static func claudeName(_ key: String) -> String {
        let words = { (k: Substring) in k.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ") }
        for b in claudeBases {
            if key == b.prefix { return b.name }
            if key.hasPrefix(b.prefix + "_") { return b.name + ", " + words(key.dropFirst(b.prefix.count + 1)) }
        }
        return words(Substring(key))
    }

    static func claudeWindow(_ key: String) -> Double? {
        claudeBases.first { key == $0.prefix || key.hasPrefix($0.prefix + "_") }?.window
    }

    static func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
