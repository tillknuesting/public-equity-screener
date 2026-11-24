import Charts
import SwiftUI

/// The factor screen: the stress regime, the names ranked highest by the forced-selling factor,
/// how the ranking changed since last week, and a research backtest. Screening only: no orders.
struct TradeDesk: View {
    @Environment(ScreenerStore.self) private var store

    var body: some View {
        Group {
            if let r = store.strategy {
                VStack(spacing: 6) {
                    HStack(alignment: .top, spacing: 6) {
                        StressMeterPanel(report: r).frame(width: 380)
                        SectorPanel(report: r).frame(width: 470)
                        TrackRecordPanel(report: r)
                    }
                    .frame(height: 290)
                    HStack(alignment: .top, spacing: 6) {
                        TradeCardsPanel(report: r)
                        RankingChangesPanel(report: r).frame(width: 360)
                    }
                }
            } else {
                Panel("Factor screen") {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(store.results.isEmpty ? "Waiting for prices…" : "Ranking the universe and running the 16-year backtest…")
                            .font(Theme.label(13)).foregroundStyle(Theme.text)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task(id: store.universeKind) {
            if store.strategy == nil || store.strategy?.universe != store.universeKind.title { store.runStrategy() }
        }
    }
}

// MARK: - Stress meter

private struct StressMeterPanel: View {
    @Environment(ScreenerStore.self) private var store
    let report: StrategyReport
    @State private var shown = 0.0

    /// 0…1 blend of how far VIX is above its median, last week's VIX jump, and credit widening.
    private var level: Double {
        let r = report.readings
        let vix = r.vix.flatMap { v in r.vixMedian.map { Stats.clamp01((v / $0 - 0.8) / 0.6) } } ?? 0
        let shock = Stats.clamp01((r.vixWeekChange ?? 0) / 0.3)
        let credit = Stats.clamp01((r.creditWeek ?? 0) / 30)
        return 0.5 * vix + 0.25 * shock + 0.25 * credit
    }

    var body: some View {
        Panel("Stress regime", marker: report.gateOpen ? Theme.green : Theme.muted) {
            HStack(alignment: .center, spacing: 16) {
                ZStack {
                    StressRing(level: shown)
                        .frame(width: 176, height: 176)
                        .help("Stress level blends \(VolIndex.current.name) versus its median (half), this week's \(VolIndex.current.name) jump and credit widening. The stress signal is on when any of the first three conditions holds.")
                    VStack(spacing: 0) {
                        Readout(text: "\(Int((shown * 100).rounded()))", size: 46, color: StressRing.color(shown))
                        Caption("stress level")
                        Text(report.gateOpen ? "Stress on" : "Calm")
                            .font(Theme.label(12.5, .bold))
                            .foregroundStyle(report.gateOpen ? Theme.base03 : Theme.text)
                            .padding(.horizontal, 9).padding(.vertical, 2)
                            .background(report.gateOpen ? Theme.green : Theme.header, in: Capsule())
                            .padding(.top, 5)
                    }
                    .offset(y: 6)
                }
                VStack(alignment: .leading, spacing: 6) {
                    condition("\(VolIndex.current.name) above 1-year median", on: report.readings.stressed,
                              detail: report.readings.vix.flatMap { v in report.readings.vixMedian.map { String(format: "%.1f vs %.1f", v, $0) } })
                    condition("\(VolIndex.current.name) jump ≥ 20% in a week", on: report.readings.shock,
                              detail: report.readings.vixWeekChange.map { "\($0.pct) this week" })
                    condition("HY spreads +15 bp in a week", on: report.readings.creditWidening,
                              detail: report.readings.creditWeek.map { String(format: "%+.0f bp this week", $0) })
                    condition("BBB − AAA widening fast", on: report.readings.qualityWidening, crisis: true,
                              detail: report.readings.qualityChange.map { String(format: "%+.0f bp over 4 weeks", $0) })
                    regimeLine
                }
            }
            .padding(12)
        }
        .onAppear { withAnimation(Motion.reduce ? nil : .spring(duration: 1.4, bounce: 0.15)) { shown = level } }
        .onChange(of: level) { _, new in withAnimation(Motion.smooth) { shown = new } }
    }

    /// Which regime we're in, described (not prescribed).
    private var regimeLine: some View {
        let r = report.readings
        let (title, detail, color): (String, String, Color) =
            !report.gateOpen ? ("Calm", "No stress condition is met. Historically the factor had no reliable edge in calm weeks.", Theme.text)
            : r.qualityWidening ? ("Credit crisis", "Quality spreads are widening. Historically the factor's largest but noisiest regime.", Theme.magenta)
            : ("Risk-budget selling", "Volatility stress while credit quality holds. Historically the factor's most reliable regime.", Theme.green)
        return VStack(alignment: .leading, spacing: 1) {
            Text(title).font(Theme.label(13, .bold)).foregroundStyle(color)
            Text(detail).font(Theme.label(11.5)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
    }

    private func condition(_ label: String, on: Bool, crisis: Bool = false, detail: String?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: on ? (crisis ? "exclamationmark.triangle.fill" : "checkmark.circle.fill") : "circle")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(on ? (crisis ? Theme.magenta : Theme.green) : Theme.muted)
            VStack(alignment: .leading, spacing: 0) {
                Text(label).font(Theme.label(12.5, .semibold)).foregroundStyle(on ? Theme.bright : Theme.text)
                if let detail { Text(detail).font(Theme.mono(10)).foregroundStyle(Theme.muted) }
            }
        }
    }
}

/// A 270° arc gauge with a heat gradient, tick marks and a glowing tip.
private struct StressRing: View, Animatable {
    var level: Double
    var animatableData: Double {
        get { level }
        set { level = newValue }
    }

    static func color(_ v: Double) -> Color {
        v < 0.35 ? Theme.green : v < 0.55 ? Theme.yellow : v < 0.75 ? Theme.orange : Theme.red
    }

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let line: CGFloat = 15
            let radius = size / 2 - line / 2
            // Trim starts at 3 o'clock; rotating by 135° makes the 270° arc open at the bottom.
            let gradient = AngularGradient(colors: [Theme.green, Theme.yellow, Theme.orange, Theme.red, Theme.magenta],
                                           center: .center, startAngle: .degrees(0), endAngle: .degrees(270))
            ZStack {
                Circle().trim(from: 0, to: 0.75)
                    .stroke(Theme.header, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(135))
                    .padding(line / 2)
                ForEach(0..<11) { i in
                    Capsule().fill(Theme.border)
                        .frame(width: 2, height: 7)
                        .offset(y: -(radius - line / 2 - 8))
                        .rotationEffect(.degrees(135 + Double(i) * 27 + 90))
                }
                Circle().trim(from: 0, to: 0.75 * max(level, 0.001))
                    .stroke(gradient, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(135))
                    .padding(line / 2)
                    .shadow(color: Self.color(level).opacity(0.65), radius: 10)
                Circle()
                    .fill(Self.color(level))
                    .frame(width: line + 5, height: line + 5)
                    .overlay(Circle().stroke(Theme.base3.opacity(0.85), lineWidth: 2))
                    .shadow(color: Self.color(level), radius: 8)
                    .offset(y: -radius)
                    .rotationEffect(.degrees(135 + 270 * level + 90))
            }
            .frame(width: size, height: size)
        }
    }
}

// MARK: - Portfolio donut

private struct SectorPanel: View {
    let report: StrategyReport
    @State private var shown = false

    private struct Slice: Identifiable {
        let name: String
        let count: Int
        var id: String { name }
    }

    private var slices: [Slice] {
        Dictionary(grouping: report.positions, by: { $0.instrument.sector })
            .map { Slice(name: $0.key, count: $0.value.count) }
            .sorted { ($0.count, $1.name) > ($1.count, $0.name) }
    }

    private static let palette: [Color] = [Theme.cyan, Theme.blue, Theme.violet, Theme.magenta, Theme.orange,
                                           Theme.yellow, Theme.green, Theme.red, Theme.base1, Theme.base01]

    var body: some View {
        let slices = slices
        let colors = slices.indices.map { Self.palette[$0 % Self.palette.count] }
        Panel("Top-ranked names by sector", marker: Theme.cyan) {
            HStack(spacing: 14) {
                ZStack {
                    Chart(slices) { s in
                        SectorMark(angle: .value("Names", s.count), innerRadius: .ratio(0.64), angularInset: 1.4)
                            .cornerRadius(3)
                            .foregroundStyle(by: .value("Sector", s.name))
                    }
                    .chartForegroundStyleScale(domain: slices.map(\.name), range: colors)
                    .chartLegend(.hidden)
                    .frame(width: 196, height: 196)
                    .shadow(color: Theme.cyan.opacity(0.22), radius: 12)
                    VStack(spacing: 0) {
                        Readout(text: "\(report.positions.count)", size: 34, color: Theme.cyan)
                        Text("top-ranked names").font(Theme.label(12)).foregroundStyle(Theme.text)
                        Text("of \(report.allRanked.count) momentum leaders").font(Theme.label(11)).foregroundStyle(Theme.muted)
                    }
                }
                .scaleEffect(shown ? 1 : 0.9)
                .opacity(shown ? 1 : 0)
                .rotationEffect(.degrees(shown ? 0 : -25))

                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(zip(slices, colors)), id: \.0.id) { s, color in
                        HStack(spacing: 7) {
                            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
                            Text(s.name).font(Theme.label(12.5)).foregroundStyle(Theme.strong).lineLimit(1)
                            Spacer(minLength: 4)
                            Text("\(s.count)").font(Theme.mono(11, .semibold)).foregroundStyle(Theme.bright)
                        }
                    }
                    Spacer(minLength: 0)
                    Text("Where the forced-selling signal is concentrating right now. Counts, not weights.")
                        .font(Theme.label(11)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
        }
        .onAppear { withAnimation(Motion.reduce ? nil : .spring(duration: 0.9, bounce: 0.2)) { shown = true } }
    }
}

// MARK: - Track record

private struct TrackRecordPanel: View {
    @Environment(ScreenerStore.self) private var store
    let report: StrategyReport
    @State private var hover: StrategyReport.CurvePoint?

    var body: some View {
        let monthly = store.deskPolicy != "weekly"
        let main = report.results.first { $0.config.name == (monthly ? "Low turnover: monthly review" : "Switch 50%, broad gate") }
        let control = report.results.first { $0.config.sleeve == .allLeaders && $0.config.turnover == (monthly ? .monthly : .weekly) }
        Panel("Backtest (research) · stress-gated 50% tilt vs \(report.benchmarkName), after costs", marker: Theme.violet) {
            HStack(spacing: 0) {
                Button("Monthly review") { withAnimation(Motion.ui) { store.deskPolicy = "monthly" } }
                    .buttonStyle(TermButtonStyle(selected: monthly, compact: true))
                Button("Weekly") { withAnimation(Motion.ui) { store.deskPolicy = "weekly" } }
                    .buttonStyle(TermButtonStyle(selected: !monthly, compact: true))
            }
            .help("Which rule the backtest uses: rebuild the ranking weekly, or review it every 4 weeks with a rank buffer (lower turnover)")
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                if let main {
                    HStack(alignment: .top, spacing: 20) {
                        stat("Excess / yr", main.excessCAGR.pct, Theme.signed(main.excessCAGR))
                        stat("Info ratio", String(format: "%.2f", main.infoRatio), Theme.bright)
                        stat("t-stat", String(format: "%.1f", main.tExcess), abs(main.tExcess) >= 2 ? Theme.green : Theme.yellow)
                        stat("Max drawdown", main.maxDrawdown.pct, Theme.red)
                        stat("Costs / yr", String(format: "%.2f%%", main.costPerYear * 100), Theme.orange)
                        if let control {
                            stat("Ranking vs control", (main.excessCAGR - control.excessCAGR).pct,
                                 Theme.signed(main.excessCAGR - control.excessCAGR))
                        }
                    }
                }
                chart
            }
            .padding(10)
        }
    }

    private func stat(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Caption(label)
            Readout(text: value, size: 21, color: color)
        }
    }

    private var chart: some View {
        let curve = store.deskPolicy == "weekly" ? report.curve : report.monthlyCurve
        return Chart {
            ForEach(curve.filter(\.tilted), id: \.day) { p in
                RectangleMark(xStart: .value("Start", TradingDay.date(p.day)),
                              xEnd: .value("End", TradingDay.date(p.day).addingTimeInterval(7 * 86_400)))
                    .foregroundStyle(Theme.magenta.opacity(0.07))
            }
            ForEach(curve, id: \.day) { p in
                AreaMark(x: .value("Date", TradingDay.date(p.day)), yStart: .value("Base", 1), yEnd: .value("Growth", p.strategy))
                    .foregroundStyle(LinearGradient(colors: [Theme.cyan.opacity(0.28), Theme.cyan.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Date", TradingDay.date(p.day)), y: .value("Growth", p.strategy), series: .value("Series", "Strategy"))
                    .foregroundStyle(Theme.cyan)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                LineMark(x: .value("Date", TradingDay.date(p.day)), y: .value("Growth", p.control), series: .value("Series", "Control"))
                    .foregroundStyle(Theme.yellow.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                LineMark(x: .value("Date", TradingDay.date(p.day)), y: .value("Growth", p.index), series: .value("Series", "Index"))
                    .foregroundStyle(Theme.base0)
                    .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
            }
            if let hover {
                RuleMark(x: .value("Hover", TradingDay.date(hover.day)))
                    .foregroundStyle(Theme.muted)
                    .annotation(position: .top, spacing: 2, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(TradingDay.label(hover.day)).font(Theme.label(11, .semibold)).foregroundStyle(Theme.bright)
                            Text(String(format: "strategy %.2f×  control %.2f×  index %.2f×", hover.strategy, hover.control, hover.index))
                                .font(Theme.mono(10)).foregroundStyle(Theme.text)
                        }
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Theme.header).overlay(Rectangle().stroke(Theme.border, lineWidth: 1))
                    }
            }
        }
        .chartYScale(type: .log)
        .chartYAxis {
            AxisMarks(values: [1, 1.5, 2, 3, 4, 6, 8]) { v in
                AxisGridLine().foregroundStyle(Theme.border)
                AxisValueLabel { if let d = v.as(Double.self) { Text(String(format: "%g×", d)) } }
                    .font(Theme.mono(9.5)).foregroundStyle(Theme.muted)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 8)) { _ in
                AxisGridLine().foregroundStyle(Theme.border)
                AxisValueLabel(format: .dateTime.year()).font(Theme.mono(9.5)).foregroundStyle(Theme.muted)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                let plot = proxy.plotFrame.map { geo[$0] } ?? .zero
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        guard case .active(let location) = phase,
                              let date: Date = proxy.value(atX: location.x - plot.minX) else { hover = nil; return }
                        hover = curve.min { abs(TradingDay.date($0.day).timeIntervalSince(date)) < abs(TradingDay.date($1.day).timeIntervalSince(date)) }
                    }
            }
        }
        .overlay(alignment: .topLeading) {
            HStack(spacing: 12) {
                legend(Theme.cyan, "Strategy")
                legend(Theme.yellow, "Control: all momentum leaders")
                legend(Theme.base0, report.benchmarkName, dashed: true)
                legend(Theme.magenta.opacity(0.5), "Gate open")
            }
            .padding(6)
        }
    }

    private func legend(_ color: Color, _ text: String, dashed: Bool = false) -> some View {
        HStack(spacing: 5) {
            Rectangle().fill(color).frame(width: 14, height: dashed ? 1.5 : 2.5)
            Text(text).font(Theme.label(11)).foregroundStyle(Theme.text)
        }
    }
}

// MARK: - Trade cards

private struct TradeCardsPanel: View {
    @Environment(ScreenerStore.self) private var store
    let report: StrategyReport

    var body: some View {
        let metrics = Dictionary(uniqueKeysWithValues: store.results.map { ($0.id, $0) })
        let shown = report.positions
        Panel("Top-ranked by the forced-selling factor · \(shown.count) momentum leaders\(report.gateOpen ? "" : " (stress signal off)")", marker: Theme.green) {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 268, maximum: 360), spacing: 8)], spacing: 8) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { i, p in
                        TradeCard(position: p, metrics: metrics[p.id], earnings: store.recentEarnings(p.id),
                                  series: store.series[p.id], index: i)
                            .onTapGesture { openChart(p.id) }
                    }
                }
                .padding(8)
            }
        }
    }

    private func openChart(_ id: String) {
        withAnimation(Motion.ui) { store.openChart(id) }
    }
}

private struct TradeCard: View {
    let position: StrategyReport.Position
    let metrics: StockMetrics?
    let earnings: EarningsTiming
    let series: PriceSeries?
    let index: Int
    @State private var hover = false
    @State private var appeared = false

    private var actionColor: Color { Theme.cyan }

    /// 1–3 match strength: a high factor rank, no company news, and positive free cash flow.
    private var conviction: Int {
        var c = position.rank <= 5 ? 2 : position.rank <= 12 ? 1 : 0
        if let m = metrics {
            if m.news.isQuiet { c += 1 }
            if case .catalysts = m.news { c -= 1 }
            if (m.fundamentals.fcfYield ?? 0) > 0 || m.instrument.isFinancial { c += 0 } else { c -= 1 }
        }
        return min(max(c, 1), 3)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("#\(position.rank)")
                    .font(Theme.mono(11.5, .bold))
                    .foregroundStyle(Theme.base03)
                    .padding(.horizontal, 7).padding(.vertical, 1.5)
                    .background(Theme.cyan, in: Capsule())
                Text(position.instrument.symbol).font(Theme.mono(14, .bold)).foregroundStyle(Theme.bright)
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: -2) {
                    Readout(text: String(format: "%.1f", position.signal), size: 22, color: Theme.cyan)
                    Text("signal").font(Theme.label(10)).foregroundStyle(Theme.muted)
                }
            }
            HStack(spacing: 6) {
                Text("\(position.instrument.flag) \(position.instrument.name)").font(Theme.label(13)).foregroundStyle(Theme.strong).lineLimit(1)
                Spacer(minLength: 4)
                Text(position.instrument.sector).font(Theme.label(11)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Sparkline(bars: Array((series?.bars ?? []).suffix(66)), highlight: 5, color: position.move < 0 ? Theme.red : Theme.green)
                .frame(height: 54)
            HStack(spacing: 10) {
                MiniGauge(label: "drop", value: String(format: "%.1fσ", position.z), fraction: Stats.clamp01(-position.z / 4), color: Theme.red)
                MiniGauge(label: "vol shock", value: String(format: "%.1f×", position.volShock), fraction: Stats.clamp01((position.volShock - 0.5) / 2), color: Theme.cyan)
                MiniGauge(label: "momentum", value: "\(Int((position.momentumRank * 100).rounded()))", fraction: position.momentumRank, color: Theme.yellow)
            }
            HStack(spacing: 5) {
                ConvictionBars(level: conviction)
                if let y = metrics?.fundamentals.fcfYield, metrics?.instrument.isFinancial == false {
                    Tag(text: String(format: "FCF %.1f%%", y * 100), color: y > 0 ? Theme.green : Theme.red)
                }
                if case .catalysts(let n, _) = metrics?.news { Tag(text: "news \(n)", color: Theme.magenta) }
                if metrics?.news.isQuiet == true { Tag(text: "no news", color: Theme.muted) }
                EarningsMark(timing: earnings)
                Spacer(minLength: 0)
                Text(position.move.pct + " 5d").font(Theme.mono(10.5, .semibold)).foregroundStyle(Theme.signed(position.move))
            }
        }
        .padding(10)
        .background {
            ZStack {
                Theme.header.opacity(0.35)
                LinearGradient(colors: [actionColor.opacity(hover ? 0.14 : 0.07), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .overlay(alignment: .leading) { actionColor.frame(width: 2) }
        .overlay(Rectangle().stroke(hover ? actionColor.opacity(0.8) : Theme.border, lineWidth: 1))
        .shadow(color: hover ? actionColor.opacity(0.35) : .clear, radius: 10)
        .scaleEffect(hover && !Motion.reduce ? 1.012 : 1)
        .animation(Motion.reduce ? nil : .snappy(duration: 0.18), value: hover)
        .onHover { hover = $0 }
        .contentShape(Rectangle())
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 12)
        .onAppear { withAnimation(Motion.stagger(min(index, 12))) { appeared = true } }
        .help("Signal = −(5-day drop in σ) × volatility shock. Click to open it in Chart.")
    }
}

/// Three-month price line with a gradient fill and the last week shaded.
private struct Sparkline: View {
    let bars: [Bar]
    let highlight: Int
    let color: Color

    var body: some View {
        let closes = bars.map(\.close)
        let lo = closes.min() ?? 0, hi = closes.max() ?? 1
        let pad = (hi - lo) * 0.08
        Chart {
            if bars.count > highlight {
                RectangleMark(xStart: .value("Start", bars[bars.count - highlight - 1].date), xEnd: .value("End", bars[bars.count - 1].date))
                    .foregroundStyle(color.opacity(0.12))
            }
            ForEach(bars, id: \.day) { b in
                AreaMark(x: .value("Date", b.date), yStart: .value("Low", lo - pad), yEnd: .value("Close", b.close))
                    .foregroundStyle(LinearGradient(colors: [Theme.cyan.opacity(0.22), Theme.cyan.opacity(0)], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Date", b.date), y: .value("Close", b.close))
                    .foregroundStyle(Theme.cyan)
                    .lineStyle(StrokeStyle(lineWidth: 1.4))
            }
            if let last = bars.last {
                PointMark(x: .value("Date", last.date), y: .value("Close", last.close))
                    .symbolSize(28)
                    .foregroundStyle(color)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: (lo - pad)...(hi + pad))
    }
}

private struct MiniGauge: View {
    let label: String
    let value: String
    let fraction: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(Theme.label(10.5)).foregroundStyle(Theme.muted)
                Spacer(minLength: 2)
                Text(value).font(Theme.mono(10.5, .semibold)).foregroundStyle(Theme.bright)
            }
            Meter(fraction: fraction, color: color).frame(height: 3)
        }
    }
}

private struct ConvictionBars: View {
    let level: Int

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...3, id: \.self) { i in
                Rectangle()
                    .fill(i <= level ? Theme.green : Theme.header)
                    .frame(width: 4, height: CGFloat(4 + i * 3))
            }
        }
        .help("Conviction \(level)/3: signal rank, no company news, positive free cash flow")
        .padding(.trailing, 2)
    }
}

// MARK: - Ranking changes

/// How the top of the ranking moved since last week. Neutral screening information only.
private struct RankingChangesPanel: View {
    @Environment(ScreenerStore.self) private var store
    let report: StrategyReport

    var body: some View {
        let rank = Dictionary(uniqueKeysWithValues: report.allRanked.map { ($0.id, $0.rank) })
        let (entered, left) = store.rankingChanges
        let top = Set(report.positions.map(\.id))
        Panel("Ranking changes", marker: Theme.yellow) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(store.previousRanking.map { "Versus the top list recorded in week \($0.week % 100)." }
                         ?? "First week recorded. From next week this shows which names entered or left the top list.")
                        .font(Theme.label(12)).foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)

                    if store.previousRanking != nil {
                        section("New in the top \(report.cut)", entered, color: Theme.green, rank: rank)
                        section("Left the top \(report.cut)", left, color: Theme.muted, rank: rank)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) { Caption("Next in the ranking", color: Theme.accent); Theme.border.frame(height: 1) }
                        ForEach(report.allRanked.filter { !top.contains($0.id) }.prefix(10)) { p in
                            HStack(spacing: 8) {
                                Text("#\(p.rank)").font(Theme.mono(10.5)).foregroundStyle(Theme.muted).frame(width: 30, alignment: .leading)
                                Text(p.instrument.symbol).font(Theme.mono(11.5, .bold)).foregroundStyle(Theme.bright)
                                Text(p.instrument.name).font(Theme.label(12)).foregroundStyle(Theme.strong).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(p.move.pct).font(Theme.mono(10.5)).foregroundStyle(Theme.signed(p.move))
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) { Caption("How the ranking works", color: Theme.accent); Theme.border.frame(height: 1) }
                        ForEach([
                            "Universe: the top half by 12-1 month momentum (momentum leaders).",
                            "Signal: the 5-day drop in units of each stock's own volatility, times how much its volatility just jumped.",
                            "Top-ranked: the top fifth of leaders by signal, at most \(SwitchingStrategy.maxNames) names.",
                            "Stress regime: \(VolIndex.current.name) above its 1-year median, a 20% \(VolIndex.current.name) jump, or high-yield spreads +15 bp in a week.",
                        ], id: \.self) { line in
                            HStack(alignment: .top, spacing: 6) {
                                Text("›").font(Theme.mono(11, .bold)).foregroundStyle(Theme.cyan)
                                Text(line).font(Theme.label(12)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Text("A screening aid, not a recommendation. Backtests use today's lists, which flatters them.")
                            .font(Theme.label(11)).foregroundStyle(Theme.muted)
                            .padding(.top, 4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [String], color: Color, rank: [String: Int]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) { Caption(title, color: color); Theme.border.frame(height: 1) }
            if items.isEmpty {
                Text("None").font(Theme.label(12)).foregroundStyle(Theme.muted)
            }
            ForEach(items, id: \.self) { symbol in
                HStack(spacing: 8) {
                    Text(rank[symbol].map { "#\($0)" } ?? "—").font(Theme.mono(10.5)).foregroundStyle(Theme.muted).frame(width: 30, alignment: .leading)
                    Text(symbol).font(Theme.mono(11.5, .bold)).foregroundStyle(Theme.bright)
                    Spacer()
                }
            }
        }
    }
}
