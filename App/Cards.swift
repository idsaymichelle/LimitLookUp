import SwiftUI

/// Brand fill for a service's header band: brighter than the brand hues so it stands out on the dark UI.
enum Brand {
    static func fill(_ s: Service) -> LinearGradient {
        let c: [Color] = switch s {
        case .claude: [Theme.claudeLight, Theme.claude]
        case .codex: [Theme.codexLight, Theme.codexDeep]
        default: [Theme.ok, Theme.ok]
        }
        return LinearGradient(colors: c, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

struct AccountBlock: View {
    let service: Service
    /// Name the user gave this account, if any; otherwise the account owner's name from the service.
    let label: String?
    let usage: ServiceUsage?
    let account: Account?
    let onLogin: () -> Void
    let onRename: () -> Void
    let onRemove: () -> Void
    /// Smaller type and padding for the Mac menu bar panel; same content as on iPhone.
    var dense = false

    @AppStorage("showIdentity", store: Store.defaults) private var showIdentity = true
    @AppStorage("compact", store: Store.defaults) private var compact = false

    private var connected: Bool { usage != nil && usage?.error == nil }
    private var name: String? { label ?? usage?.name }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(alignment: .leading, spacing: dense ? (compact ? 8 : 9) : (compact ? 14 : 18)) {
                content
            }
            .padding(dense ? 10 : 18)
        }
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: dense ? 14 : 22, style: .continuous))
    }

    /// Full-width band in the service's color: service, then who the account belongs to.
    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: service.title)
                        .font(.custom("AvenirNext-Bold", size: (dense ? 15 : 20) * Theme.k, relativeTo: .title3))
                        .layoutPriority(1)
                    if showIdentity, let n = name, !n.isEmpty {
                        Text(n).font(Theme.font(dense ? .caption : .body, .medium)).opacity(0.85).lineLimit(1)
                    }
                    if let p = usage?.plan {
                        Text(verbatim: p).font(Theme.font(.caption, .demi))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(.white.opacity(0.22), in: Capsule())
                    }
                }
                if showIdentity, let e = usage?.identity, !e.isEmpty {
                    Text(e).font(Theme.font(dense ? .caption2 : .footnote)).opacity(0.8).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            if account != nil {
                Menu {
                    Button("Sign in again", systemImage: "person.crop.circle", action: onLogin)
                    Button("Rename", systemImage: "pencil", action: onRename)
                    Button("Remove account", systemImage: "trash", role: .destructive, action: onRemove)
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: dense ? 13 : 17, weight: .bold))
                        .frame(width: dense ? 26 : 36, height: dense ? 22 : 30).contentShape(Rectangle())
                }
                #if os(macOS)
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                #endif
                .accessibilityLabel(L("Actions for \(service.title)"))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, dense ? 10 : 18).padding(.vertical, dense ? 8 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.fill(service))
    }

    @ViewBuilder private var content: some View {
            if let u = usage, connected {
                ForEach(u.limits) { LimitRow(limit: $0, dense: dense) }
                HStack {
                    Spacer()
                    Label(Lang.relative(u.updated), systemImage: "clock")
                        .font(Theme.font(.caption)).foregroundStyle(Theme.sub)
                }
            } else {
                Text(usage?.error ?? L("Sign in to see your limits."))
                    .font(Theme.font(.subheadline)).foregroundStyle(Theme.sub)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Sign in", action: onLogin)
                    .font(Theme.font(.subheadline, .medium))
                    .buttonStyle(.bordered)
                    .tint(Theme.ink)
            }
    }
}

struct LimitRow: View {
    let limit: Limit
    /// Smaller type for the Mac menu bar panel. Layout (detailed or compact) follows the same setting as on iPhone.
    var dense = false
    @AppStorage("compact", store: Store.defaults) private var compact = false
    @AppStorage("showRemaining", store: Store.defaults) private var showRemaining = false

    var body: some View {
        if compact { compactBody } else { detailedBody }
    }

    /// One line per limit: name, reset time, percent, then a thin bar.
    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(limit.title).font(Theme.font(dense ? .subheadline : .body)).foregroundStyle(Theme.ink)
                    .lineLimit(1).layoutPriority(1)
                Spacer(minLength: 4)
                if let r = limit.resetsAt {
                    let when = r.timeIntervalSinceNow < 86400 ? Lang.time(r) : Lang.weekdayTime(r)
                    if dense {
                        // Narrow Mac panel: an icon instead of the word, so the limit name stays readable.
                        Label { Text(verbatim: when) } icon: { Image(systemName: "arrow.counterclockwise") }
                            .labelStyle(.titleAndIcon).font(Theme.font(.caption)).foregroundStyle(Theme.sub).lineLimit(1)
                    } else {
                        Text(r.timeIntervalSinceNow < 86400 ? L("Resets at \(when)") : L("Resets \(when)"))
                            .font(Theme.font(.subheadline)).foregroundStyle(Theme.sub).lineLimit(1)
                    }
                }
                Text(verbatim: "\(Int(showRemaining ? max(0, 100 - limit.percent) : limit.percent))%")
                    .font(Theme.number(dense ? .subheadline : .body, .demi)).foregroundStyle(Theme.ink)
                    .contentTransition(.numericText(value: limit.percent))
            }
            PaceBar(limit: limit, height: 6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility)
    }

    @ViewBuilder private var detailedBody: some View {
        if dense { denseDetailedBody } else { phoneDetailedBody }
    }

    /// Mac panel: the same details as on iPhone, with pace and reset time on one line so two accounts fit.
    private var denseDetailedBody: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(limit.title).font(Theme.font(.subheadline, .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                Spacer(minLength: 6)
                Text(verbatim: "\(Int(showRemaining ? max(0, 100 - limit.percent) : limit.percent))%" + (showRemaining ? " " + L("left") : ""))
                    .font(Theme.number(.headline)).foregroundStyle(Theme.ink)
                    .contentTransition(.numericText(value: limit.percent))
            }
            PaceBar(limit: limit, height: 5)
            HStack(spacing: 6) {
                if let r = limit.ratePerHour() {
                    Text(L("\(Lang.decimal(r))%/h")).font(Theme.number(.caption, .regular))
                        .foregroundStyle(limit.pace() == .fast ? Theme.warn : Theme.sub)
                }
                if let r = limit.resetText() {
                    Text(L("Resets \(r)")).font(Theme.font(.caption)).foregroundStyle(Theme.sub).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility)
    }

    private var phoneDetailedBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(limit.title).font(Theme.font(.body, .medium)).foregroundStyle(Theme.ink)
                    if let r = limit.ratePerHour() {
                        Text(L("\(Lang.decimal(r))%/h"))
                            .font(Theme.number(.footnote, .regular))
                            .foregroundStyle(limit.pace() == .fast ? Theme.warn : Theme.sub)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(Int(showRemaining ? max(0, 100 - limit.percent) : limit.percent))%")
                        .font(Theme.number(.title2)).foregroundStyle(Theme.ink)
                        .contentTransition(.numericText(value: limit.percent))
                        .animation(.snappy, value: limit.percent)
                    if showRemaining { Text("left").font(Theme.font(.caption)).foregroundStyle(Theme.sub) }
                }
            }
            PaceBar(limit: limit)
            if let r = limit.resetText() {
                Text(L("Resets \(r)")).font(Theme.font(.footnote)).foregroundStyle(Theme.sub)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility)
    }

    private var accessibility: String {
        var s = L("\(limit.title): \(Int(limit.percent)) percent used")
        if let r = limit.ratePerHour() { s += ", " + L("\(Int(r.rounded())) percent per hour") }
        if let r = limit.resetText() { s += ", " + L("resets \(r)") }
        return s
    }
}

/// Sample of the compact layout, shown in Settings when it is selected.
struct CompactPreview: View {
    var body: some View {
        VStack(spacing: 14) {
            LimitRow(limit: Limit(name: "5 hours", percent: 97, resetsAt: .now.addingTimeInterval(7200), window: 18000))
            LimitRow(limit: Limit(name: "Week", percent: 53, resetsAt: .now.addingTimeInterval(4 * 86400), window: 604800))
        }
        .padding(.vertical, 6)
    }
}
