import SwiftUI
import WatchConnectivity

/// The watch only shows what the phone sends; it never signs in or contacts the AI services.
final class WatchModel: NSObject, ObservableObject, WCSessionDelegate {
    @Published var usage = Store.load()

    override init() {
        super.init()
        #if DEBUG
        // -empty: what a new user sees before signing in on the iPhone.
        if CommandLine.arguments.contains("-empty") { usage = []; return }
        // -demo: sample numbers for screenshots, same as the iPhone's demo mode.
        if Demo.on {
            let h: (Double) -> Date = { .now.addingTimeInterval($0 * 3600) }
            usage = [
                ServiceUsage(service: "Claude Code", limits: [Limit(name: "5 hours", percent: 63, resetsAt: h(2.3), window: 18000),
                                                         Limit(name: "Week", percent: 28, resetsAt: h(90), window: 604800),
                                                         Limit(name: "Week, Fable", percent: 34, resetsAt: h(90), window: 604800)],
                             updated: .now, error: nil, identity: "alex@example.com", name: "Alex Morgan", plan: "Max 5x"),
                ServiceUsage(service: "Codex", limits: [Limit(name: "5 hours", percent: 12, resetsAt: h(4), window: 18000),
                                                        Limit(name: "Week", percent: 74, resetsAt: h(51), window: 604800)],
                             updated: .now, error: nil, identity: "alex@example.com", name: "Alex Morgan"),
            ]
            return
        }
        #endif
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func session(_ s: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        apply(s.receivedApplicationContext)
    }

    func session(_ s: WCSession, didReceiveApplicationContext ctx: [String: Any]) { apply(ctx) }
    func session(_ s: WCSession, didReceiveMessage message: [String: Any]) { apply(message) }

    private func apply(_ ctx: [String: Any]) {
        guard let data = ctx["usage"] as? Data, let u = try? JSONDecoder().decode([ServiceUsage].self, from: data) else { return }
        DispatchQueue.main.async {
            self.usage = u
            Store.save(u)
        }
    }
}

@main
struct LimitLookUpWatchApp: App {
    @StateObject private var model = WatchModel()
    var body: some Scene {
        WindowGroup { WatchView().environmentObject(model) }
    }
}

struct WatchView: View {
    @EnvironmentObject var model: WatchModel

    var body: some View {
        let ok = model.usage.filter { $0.error == nil && !$0.limits.isEmpty }
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image("Mark").resizable().interpolation(.high).scaledToFit().frame(width: 20, height: 20)
                    Text(verbatim: "LimitLookUp").font(.custom("AvenirNext-Bold", size: 17)).foregroundStyle(Theme.wordmark)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                if ok.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "iphone").font(.system(size: 30, weight: .light)).foregroundStyle(Theme.accent)
                            .accessibilityHidden(true)
                        Text("Open LimitLookUp on your iPhone to see your limits here.")
                            .font(Theme.font(.footnote)).foregroundStyle(Theme.ink).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18).padding(.horizontal, 10)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                ForEach(ok, id: \.service) { WatchAccount(usage: $0) }
                Color.clear.frame(height: 1).id("end")
            }
            .padding(.horizontal, 4)
        }
        .onAppear {
            #if DEBUG
            // -bottom: open scrolled to the end, for website screenshots.
            if CommandLine.arguments.contains("-bottom") { DispatchQueue.main.async { proxy.scrollTo("end", anchor: .bottom) } }
            #endif
        }
        }
        .background(Theme.watchLight ? Theme.bg : .black) // OLED: true black around the cards
    }
}

/// One account: a coloured band with the service and account name, then each limit with its bar.
struct WatchAccount: View {
    let usage: ServiceUsage
    private var codex: Bool { usage.service.hasPrefix("Codex") }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text(usage.service).font(Theme.font(.footnote, .demi))
                if let n = usage.name { Text(n).font(Theme.font(.caption2)).opacity(0.85).lineLimit(1) }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(LinearGradient(colors: codex ? [Theme.codexLight, Theme.codexDeep] : [Theme.claudeLight, Theme.claude],
                                       startPoint: .leading, endPoint: .trailing))
            VStack(alignment: .leading, spacing: 9) {
                ForEach(usage.limits) { l in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(l.title).font(Theme.font(.footnote)).foregroundStyle(Theme.ink).lineLimit(1)
                            Spacer(minLength: 4)
                            Text("\(Int(l.percent))%").font(Theme.number(.headline)).foregroundStyle(Theme.ink)
                        }
                        PaceBar(limit: l, height: 5)
                        if let r = l.resetText()?.components(separatedBy: " (").first {
                            Text(L("Resets \(r)")).font(Theme.font(.caption2)).foregroundStyle(Theme.sub).lineLimit(1)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(10)
        }
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
