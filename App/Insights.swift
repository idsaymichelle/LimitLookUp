import SwiftUI
import Charts

/// Peak usage of one limit over time, as bars. Data comes only from readings this device has taken.
struct HistoryCard: View {
    let samples: [Sample]
    let usage: [ServiceUsage]
    let threshold: Double
    @State private var range: History.Range = .d7
    @State private var pick: String?

    /// "account|limit" pairs the user can chart, from the current data.
    private var options: [(key: String, account: String, limit: String)] {
        usage.flatMap { u in u.limits.map { ("\(u.service)|\($0.name)", u.service, $0.name) } }
    }
    private var selected: (key: String, account: String, limit: String)? {
        options.first { $0.key == pick } ?? options.first { $0.limit == "Week" } ?? options.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("History").font(Theme.font(.headline, .demi)).foregroundStyle(Theme.ink)
                Spacer()
                if let sel = selected {
                    Menu {
                        ForEach(options, id: \.key) { o in Button("\(o.account): \(Limit(name: o.limit, percent: 0, resetsAt: nil).title)") { pick = o.key } }
                    } label: {
                        Label("\(sel.account): \(Limit(name: sel.limit, percent: 0, resetsAt: nil).title)", systemImage: "chevron.up.chevron.down")
                            .labelStyle(TrailingIcon())
                            .font(Theme.font(.caption, .medium)).foregroundStyle(Theme.sub).lineLimit(1)
                    }
                    #if os(macOS)
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize() // one arrow, not two
                    #endif
                }
            }

            RangePicker(range: $range)

            if let sel = selected {
                let bars = History.bars(samples, account: sel.account, limit: sel.limit, range: range)
                Chart {
                    ForEach(bars) { b in
                        BarMark(x: .value("Time", b.start, unit: unit), y: .value("Peak", b.peak), width: .ratio(0.62))
                            .foregroundStyle(b == bars.last ? Theme.accent : Theme.accent.opacity(0.45))
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                    RuleMark(y: .value("Threshold", threshold))
                        .foregroundStyle(Theme.warn.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                .chartYScale(domain: 0...100)
                .chartYAxis {
                    AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { v in
                        AxisGridLine().foregroundStyle(Theme.line)
                        AxisValueLabel { Text("\(v.as(Int.self) ?? 0)%").font(Theme.font(.caption2)).foregroundStyle(Theme.sub) }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 7)) { v in
                        // Charts uses the phone's language; format by hand so labels follow the app's language.
                        AxisValueLabel {
                            if let d = v.as(Date.self) {
                                Text(verbatim: d.formatted(xFormat.locale(Lang.locale)))
                                    .font(Theme.font(.caption2)).foregroundStyle(Theme.sub)
                            }
                        }
                    }
                }
                .frame(height: 170)
                .accessibilityLabel(L("Peak usage chart, \(range.label)"))

                let peak = bars.map(\.peak).max() ?? 0
                VStack(alignment: .leading, spacing: 4) {
                    if let f = bars.first, let l = bars.last {
                        Text(verbatim: "\(Lang.dayMonth(f.start)) – \(Lang.dayMonth(l.start))")
                            .font(Theme.font(.caption)).foregroundStyle(Theme.sub)
                    }
                    HStack(spacing: 6) {
                        Circle().fill(Theme.accent).frame(width: 7, height: 7)
                        Text(peak > 0 ? L("Peak for the period: \(Int(peak))%") : L("No data for this period yet"))
                            .font(Theme.font(.subheadline, .medium)).foregroundStyle(Theme.ink)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Theme.track.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                Text("History appears after the first refresh.").font(Theme.font(.subheadline)).foregroundStyle(Theme.sub)
            }
        }
        .padding(18 * Theme.k)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 22 * Theme.k, style: .continuous))
    }

    private var unit: Calendar.Component { range.bucket >= 86400 ? .day : .hour }
    private var xFormat: Date.FormatStyle {
        switch range {
        case .h12, .h24: .dateTime.hour()
        case .d3: .dateTime.weekday(.abbreviated)
        case .d7: .dateTime.weekday(.abbreviated)
        case .d30, .d90: .dateTime.day().month(.defaultDigits)
        }
    }
}

struct RangePicker: View {
    @Binding var range: History.Range
    var body: some View {
        HStack(spacing: 2) {
            ForEach(History.Range.allCases) { r in
                Button { range = r } label: {
                    Text(r.label)
                        .font(Theme.font(.footnote, r == range ? .demi : .regular))
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .foregroundStyle(r == range ? Theme.ink : Theme.sub)
                        .background(r == range ? Theme.bg : .clear, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(r == range ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Theme.track, in: Capsule())
    }
}

/// Days as squares, darker = closer to the 5-hour limit that day. Columns are weeks.
struct ActivityCard: View {
    let samples: [Sample]
    private let weeks = 13 // ~90 days, the length of kept history
    private let cell: CGFloat = 18

    var body: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        // Start on the first day of the week, `weeks` columns back, so rows line up with weekdays.
        let thisWeek = cal.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let start = cal.date(byAdding: .weekOfYear, value: -(weeks - 1), to: thisWeek)!
        let days = cal.dateComponents([.day], from: start, to: today).day! + 1
        let values = History.activity(samples, days: days)

        VStack(alignment: .leading, spacing: 12) {
            Text("Activity").font(Theme.font(.headline, .demi)).foregroundStyle(Theme.ink)
            HStack(alignment: .top, spacing: 4) {
                ForEach(0..<weeks, id: \.self) { w in
                    VStack(spacing: 4) {
                        let weekStart = cal.date(byAdding: .weekOfYear, value: w, to: start)!
                        Text(monthLabel(weekStart, cal)).font(Theme.font(.caption2)).foregroundStyle(Theme.sub)
                            .fixedSize().frame(width: cell, height: 14, alignment: .leading)
                        ForEach(0..<7, id: \.self) { d in
                            let day = cal.date(byAdding: .day, value: d, to: weekStart)!
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(day > today ? .clear : color(values[day]))
                                .frame(width: cell, height: cell)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L("Active days in the last \(weeks) weeks: \(values.values.filter { $0 > 0 }.count)"))

            HStack(spacing: 4) {
                Text("Less").font(Theme.font(.caption2)).foregroundStyle(Theme.sub)
                ForEach([0.0, 20, 45, 70, 95], id: \.self) { v in
                    RoundedRectangle(cornerRadius: 3).fill(color(v)).frame(width: 11, height: 11)
                }
                Text("More").font(Theme.font(.caption2)).foregroundStyle(Theme.sub)
            }
        }
        .padding(18 * Theme.k)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 22 * Theme.k, style: .continuous))
    }

    private func color(_ v: Double?) -> Color {
        guard let v, v > 0 else { return Theme.track }
        return Theme.accent.opacity(v < 25 ? 0.3 : v < 50 ? 0.5 : v < 75 ? 0.75 : 1)
    }

    /// Month name above the first column of each month.
    private func monthLabel(_ weekStart: Date, _ cal: Calendar) -> String {
        let prev = cal.date(byAdding: .weekOfYear, value: -1, to: weekStart)!
        guard cal.component(.month, from: prev) != cal.component(.month, from: weekStart) else { return "" }
        return Lang.month(weekStart).replacingOccurrences(of: ".", with: "")
    }
}

/// Text first, icon after.
struct TrailingIcon: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.title; configuration.icon.imageScale(.small) }
    }
}

/// Four headline numbers for the last weeks.
struct OverviewCard: View {
    let samples: [Sample]
    let threshold: Double

    var body: some View {
        let o = History.overview(samples, threshold: threshold)
        VStack(alignment: .leading, spacing: 14 * Theme.k) {
            Text("Overview").font(Theme.font(.headline, .demi)).foregroundStyle(Theme.ink)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                tile(Text(verbatim: "\(Int(o.weekPeak))%"), "Peak this week", tint: o.weekPeak >= threshold ? Theme.over : Theme.ok)
                tile(Text(verbatim: "\(o.daysNearLimit)"), "Days near the limit", tint: o.daysNearLimit > 0 ? Theme.amber : Theme.ok)
                tile(Text(verbatim: "\(o.activeDays)"), "Active days", tint: Theme.ok)
                tile(Text(verbatim: o.busiestWeekday.map(weekdayName) ?? "—"), "Busiest day", tint: Theme.warn)
            }
            Text("Last 30 days, from readings on your devices.").font(Theme.font(.caption)).foregroundStyle(Theme.sub)
        }
        .padding(18 * Theme.k)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 22 * Theme.k, style: .continuous))
    }

    private func tile(_ value: Text, _ label: LocalizedStringKey, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Long weekday names ("Понедельник", "Donnerstag") shrink instead of being cut off.
            value.font(.custom("AvenirNext-Bold", size: 28 * Theme.k, relativeTo: .title)).foregroundStyle(tint)
                .lineLimit(1).minimumScaleFactor(0.4)
            Text(label).font(Theme.font(.footnote)).foregroundStyle(Theme.sub)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14 * Theme.k)
        .background(Theme.bg.opacity(0.6), in: RoundedRectangle(cornerRadius: 16 * Theme.k, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func weekdayName(_ w: Int) -> String {
        var cal = Calendar.current
        cal.locale = Lang.locale
        return cal.standaloneWeekdaySymbols[w - 1].capitalized(with: Lang.locale)
    }
}
