import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Choosing an account in the widget's settings

struct AccountEntity: AppEntity {
    let id: String // the account's display title, e.g. "Claude Code, Work"
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Account"
    static var defaultQuery = AccountQuery()
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(id)") }
}

struct AccountQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [AccountEntity] { identifiers.map(AccountEntity.init) }
    func suggestedEntities() async throws -> [AccountEntity] { Store.load().map { AccountEntity(id: $0.service) } }
}

struct SelectAccount: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Account"
    static var description = IntentDescription("Which account to show. If none is chosen, the one closest to its limit is shown.")
    @Parameter(title: "Account") var account: AccountEntity?
}

// MARK: - Timeline

struct Entry: TimelineEntry {
    let date: Date
    let usage: ServiceUsage?
}

/// The widget only reads what the app saved; it makes no network requests itself.
struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: .now, usage: Self.sample) }
    func snapshot(for c: SelectAccount, in context: Context) async -> Entry {
        Entry(date: .now, usage: Self.pick(c) ?? Self.sample)
    }
    func timeline(for c: SelectAccount, in context: Context) async -> Timeline<Entry> {
        Timeline(entries: [Entry(date: .now, usage: Self.pick(c))], policy: .after(.now.addingTimeInterval(900)))
    }

    /// Chosen account, or the one with the fullest limit.
    static func pick(_ c: SelectAccount) -> ServiceUsage? {
        let all = Store.load().filter { $0.error == nil && !$0.limits.isEmpty }
        if let id = c.account?.id, let u = all.first(where: { $0.service == id }) { return u }
        return all.max { ($0.limits.map(\.percent).max() ?? 0) < ($1.limits.map(\.percent).max() ?? 0) }
    }

    static let sample = ServiceUsage(service: "Claude Code", limits: [
        Limit(name: "5 hours", percent: 46, resetsAt: .now.addingTimeInterval(8040), window: 18000),
        Limit(name: "Week", percent: 31, resetsAt: .now.addingTimeInterval(3 * 86400), window: 604800),
    ], updated: .now, error: nil)
}

// MARK: - Views

struct UsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry

    var body: some View {
        content.containerBackground(Theme.card, for: .widget)
            .environment(\.locale, Lang.locale) // same language as chosen in the app
    }

    @ViewBuilder private var content: some View {
        if let u = entry.usage, let main = u.limits.first {
            switch family {
            case .accessoryCircular:
                Gauge(value: min(main.percent, 100), in: 0...100) { Text(short(u.service)) } currentValueLabel: {
                    Text("\(Int(main.percent))")
                }
                .gaugeStyle(.accessoryCircular)
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(u.limits.prefix(2)) { l in
                        HStack { Text(l.title); Spacer(); Text("\(Int(l.percent))%").monospacedDigit() }
                            .font(.caption)
                        ProgressView(value: min(l.percent, 100), total: 100)
                    }
                }
            case .accessoryInline:
                Text("\(short(u.service)) \(Int(main.percent))%" + (main.resetsAt.map { " " + L("resets \(Lang.time($0))") } ?? ""))
            case .systemMedium:
                HStack(alignment: .top, spacing: 18) {
                    big(u, main)
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(u.limits.dropFirst().prefix(3)) { row($0) }
                    }
                }
            default:
                VStack(alignment: .leading, spacing: 8) {
                    big(u, main)
                    Spacer(minLength: 0)
                    if let second = u.limits.dropFirst().first { row(second) }
                }
            }
        } else {
            Text("Open LimitLookUp and sign in to an account").font(Theme.font(.caption)).foregroundStyle(Theme.sub)
        }
    }

    private func big(_ u: ServiceUsage, _ l: Limit) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(u.service).font(Theme.font(.caption, .demi)).foregroundStyle(Theme.ok).lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text("\(Int(l.percent))").font(.custom("AvenirNext-DemiBold", size: 40)).monospacedDigit()
                Text("%").font(Theme.font(.title3, .demi))
            }
            .foregroundStyle(Theme.ink)
            Text(l.title + (l.resetsAt.map { ", " + L("resets \(Lang.time($0))") } ?? ""))
                .font(Theme.font(.caption2)).foregroundStyle(Theme.sub).lineLimit(1)
            PaceBar(limit: l, height: 6)
        }
    }

    private func row(_ l: Limit) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(l.title).font(Theme.font(.caption, .medium)).foregroundStyle(Theme.ink)
                Spacer()
                Text("\(Int(l.percent))%").font(Theme.number(.caption)).foregroundStyle(Theme.ink)
            }
            PaceBar(limit: l, height: 6)
        }
    }

    /// Two-letter tag for tight spots: "CC", "CX", "KI", "QW".
    private func short(_ service: String) -> String {
        if service.hasPrefix("Claude") { return "CC" }
        if service.hasPrefix("Codex") { return "CX" }
        return String(service.prefix(2)).uppercased()
    }
}

@main
struct UsageWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "UsageWidget", intent: SelectAccount.self, provider: Provider()) { UsageWidgetView(entry: $0) }
            .configurationDisplayName("AI limits")
            .description("Limits of the chosen account. Touch and hold the widget to choose an account.")
            .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
