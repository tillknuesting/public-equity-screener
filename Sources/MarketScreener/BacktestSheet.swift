import Charts
import SwiftUI

/// Results of replaying the screen at every past VIX spike.
struct BacktestSheet: View {
    @Environment(ScreenerStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Rectangle().fill(Theme.cyan).frame(width: 6, height: 6)
                if let r = store.backtest {
                    Text("Backtest").font(Theme.label(16, .bold)).foregroundStyle(Theme.bright)
                    Text("\(r.universe), \(r.rows.count) \(VolIndex.current.name) spikes, \(r.window)-session reaction window")
                        .font(Theme.label(13)).foregroundStyle(Theme.text)
                } else {
                    Text("Backtest").font(Theme.label(16, .bold)).foregroundStyle(Theme.bright)
                }
                Spacer()
                if let r = store.backtest, r.window != store.window || r.universe != store.universeKind.title {
                    Text("Settings changed since this run").font(Theme.label(12)).foregroundStyle(Theme.orange)
                }
                Button("Rerun") { store.runBacktest() }
                    .buttonStyle(TermButtonStyle(compact: true))
                    .disabled(store.isBacktesting)
                Button("Close") { dismiss() }
                    .buttonStyle(TermButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(Theme.header)
            Theme.border.frame(height: 1)

            if let r = store.backtest, !store.isBacktesting {
                ScrollView { report(r).padding(14) }
            } else {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Replaying the screen at \(store.events.count) past spikes…")
                        .font(Theme.label(13)).foregroundStyle(Theme.text)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 1240, idealWidth: 1320, minHeight: 760, idealHeight: 860)
        .background(Theme.panel)
    }

    private func report(_ r: BacktestReport) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("For each past spike, the screen is rebuilt as it would have looked at the end of the reaction window, then each group is held equal-weight for 1 week, 1 month and 3 months. “Excess” is versus \(store.universeKind.benchmarkName); “hit” is the share of spikes where the group beat it. Biases: today's stock list (survivorship), today's fundamentals (look-ahead in quality), no historical news (that part is neutral), overlapping spikes.")
                .font(Theme.label(12)).foregroundStyle(Theme.text)
                .frame(maxWidth: 900, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            block("Is there alpha?") { alphaTable(r) }

            HStack(alignment: .top, spacing: 18) {
                block("Strategies") { strategyTable(r) }
                    .frame(width: 760)
                block("Average excess return") { excessChart(r) }
            }
            HStack(alignment: .top, spacing: 18) {
                block("Which score parts predict?") { factorTable(r) }
                    .frame(width: 560)
                block("Does stress help? (1M excess)") { splitTable(r) }
            }
            block("Spikes") { eventTable(r) }
        }
    }

    // MARK: Tables

    /// Beta-adjusted alpha with t-statistics, over all spikes and over non-overlapping ones.
    private func alphaTable(_ r: BacktestReport) -> some View {
        let rows: [(String, String)] = [
            ("Thesis − All", "Thesis matches minus all stocks: the rule's own edge"),
            ("Top 10 − Bottom 10", "Does the score rank the winners?"),
            ("Thesis matches", "vs \(store.universeKind.benchmarkName), beta-adjusted"),
            ("Top 10 score", "vs \(store.universeKind.benchmarkName), beta-adjusted"),
        ]
        let reliable = rows.prefix(2).contains { name, _ in
            BacktestReport.horizons.contains { (r.independentStats[name]?[$0.sessions]?.tAlpha ?? 0) >= 2 }
        }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 20) {
                Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow {
                        Caption("Group").gridColumnAlignment(.leading)
                        ForEach(BacktestReport.horizons) { h in Caption("\(h.label) α"); Caption("t") }
                        Caption("1M α, separate spikes"); Caption("t"); Caption("spikes")
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(rows, id: \.0) { name, note in
                        GridRow {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(name).font(Theme.label(13, .semibold)).foregroundStyle(Theme.bright)
                                Text(note).font(Theme.label(11)).foregroundStyle(Theme.muted)
                            }
                            .gridColumnAlignment(.leading)
                            ForEach(BacktestReport.horizons) { h in
                                let s = r.stats[name]?[h.sessions]
                                num(s?.meanAlpha, bold: true)
                                tValue(s?.tAlpha)
                            }
                            let i = r.independentStats[name]?[21]
                            num(i?.meanAlpha, bold: true)
                            tValue(i?.tAlpha)
                            Text("\(i?.events ?? 0)").font(Theme.mono(11)).foregroundStyle(Theme.muted)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Exclude fundamentals (no look-ahead)", isOn: Binding(
                        get: { r.withoutFundamentals },
                        set: { store.runBacktest(withoutFundamentals: $0) }))
                        .toggleStyle(CheckToggleStyle())
                    Text(reliable
                         ? "At least one spread clears t ≥ 2 on separate spikes: worth testing on more history before trusting it."
                         : "No spread clears t ≥ 2 on separate spikes, so there's no reliable alpha yet. Positive numbers with t below 2 can be luck at this sample size.")
                        .font(Theme.label(12.5, .medium))
                        .foregroundStyle(reliable ? Theme.green : Theme.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("α = return − β × benchmark. t ≥ 2 (bold) is the usual bar. Separate spikes are at least one holding period apart, so they don't share returns.")
                        .font(Theme.label(11.5)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 330, alignment: .leading)
            }
        }
    }

    private func tValue(_ t: Double?) -> some View {
        Text(t.map { String(format: "%+.1f", $0) } ?? "—")
            .font(Theme.mono(11, abs(t ?? 0) >= 2 ? .bold : .regular))
            .foregroundStyle(abs(t ?? 0) >= 2 ? Theme.signed(t ?? 0) : Theme.muted)
    }

    private func strategyTable(_ r: BacktestReport) -> some View {
        Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                Caption("Group").gridColumnAlignment(.leading)
                ForEach(BacktestReport.horizons) { h in
                    Caption("\(h.label) avg"); Caption("vs bench"); Caption("hit")
                }
                Caption("spikes")
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(BacktestReport.strategies + ["Benchmark"], id: \.self) { name in
                GridRow {
                    HStack(spacing: 6) {
                        Rectangle().fill(color(name)).frame(width: 8, height: 8)
                        Text(name == "Benchmark" ? store.universeKind.benchmarkName : name)
                            .font(Theme.label(13, .semibold)).foregroundStyle(Theme.bright)
                    }
                    .gridColumnAlignment(.leading)
                    ForEach(BacktestReport.horizons) { h in
                        let s = r.stats[name]?[h.sessions]
                        num(s?.meanReturn)
                        if name == "Benchmark" { Text("") } else { num(s?.meanExcess, bold: true) }
                        Text(s.map { "\(Int(($0.hitRate * 100).rounded()))%" } ?? "—")
                            .font(Theme.mono(11)).foregroundStyle(Theme.text)
                    }
                    Text("\(r.stats[name]?[21]?.events ?? 0)").font(Theme.mono(11)).foregroundStyle(Theme.muted)
                }
            }
        }
    }

    private func excessChart(_ r: BacktestReport) -> some View {
        Chart {
            ForEach(BacktestReport.strategies, id: \.self) { name in
                ForEach(BacktestReport.horizons) { h in
                    if let v = r.stats[name]?[h.sessions]?.meanExcess {
                        BarMark(x: .value("Horizon", h.label), y: .value("Excess", v * 100))
                            .foregroundStyle(by: .value("Group", name))
                            .position(by: .value("Group", name))
                    }
                }
            }
            RuleMark(y: .value("Zero", 0)).foregroundStyle(Theme.muted)
        }
        .chartForegroundStyleScale(domain: BacktestReport.strategies, range: BacktestReport.strategies.map(color))
        .chartLegend(position: .bottom, spacing: 6)
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { v in
                AxisGridLine().foregroundStyle(Theme.border)
                AxisValueLabel { if let d = v.as(Double.self) { Text(String(format: "%+.0f%%", d)) } }
                    .font(Theme.mono(9)).foregroundStyle(Theme.muted)
            }
        }
        .chartXAxis {
            AxisMarks { _ in AxisValueLabel().font(Theme.mono(10)).foregroundStyle(Theme.text) }
        }
        .frame(height: 170)
    }

    private func factorTable(_ r: BacktestReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    Caption("Factor").gridColumnAlignment(.leading)
                    ForEach(BacktestReport.horizons) { Caption("\($0.label) IC") }
                    Caption("t (1M)")
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(r.factors) { f in
                    GridRow {
                        Text(f.name).font(Theme.label(13, .semibold)).foregroundStyle(Theme.bright).gridColumnAlignment(.leading)
                        ForEach(BacktestReport.horizons) { h in
                            if let ic = f.ic[h.sessions] {
                                Text(String(format: "%+.3f", ic.mean)).font(Theme.mono(11, abs(ic.t) >= 2 ? .bold : .regular))
                                    .foregroundStyle(abs(ic.t) >= 2 ? Theme.signed(ic.mean) : Theme.text)
                            } else { Text("—").font(Theme.mono(11)).foregroundStyle(Theme.muted) }
                        }
                        Text(f.ic[21].map { String(format: "%+.1f", $0.t) } ?? "—").font(Theme.mono(11)).foregroundStyle(Theme.muted)
                    }
                }
            }
            Text("Rank IC: how well a factor ordered stocks by what they did next (−1…+1; 0.03–0.05 is useful in practice). Bold = |t| ≥ 2. Quality is flattered by look-ahead.")
                .font(Theme.label(11.5)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func splitTable(_ r: BacktestReport) -> some View {
        Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 6) {
            GridRow {
                Caption("Condition at the spike").gridColumnAlignment(.leading)
                Caption("spikes"); Caption("thesis matches"); Caption("top 10")
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(r.splits) { s in
                GridRow {
                    Text(s.condition).font(Theme.label(13, .semibold)).foregroundStyle(Theme.bright).gridColumnAlignment(.leading)
                    Text("\(s.events)").font(Theme.mono(11)).foregroundStyle(Theme.muted)
                    num(s.thesisExcess, bold: true)
                    num(s.topExcess, bold: true)
                }
            }
        }
    }

    private func eventTable(_ r: BacktestReport) -> some View {
        Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                Caption("Spike").gridColumnAlignment(.leading)
                Caption("\(VolIndex.current.name) jump"); Caption("\(VolIndex.current.name)/3M"); Caption("corr")
                Caption("Thesis matches").gridColumnAlignment(.leading)
                Caption("matches 1M"); Caption("top10 1M"); Caption("all 1M"); Caption("bench 1M"); Text("")
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(r.rows) { row in
                GridRow {
                    Text(TradingDay.label(row.event.day)).font(Theme.mono(11, .semibold)).foregroundStyle(Theme.bright)
                        .gridColumnAlignment(.leading)
                    Text(row.event.change.pct).font(Theme.mono(11)).foregroundStyle(Theme.red)
                    Text(row.termPeak.map { String(format: "%.2f", $0) } ?? "—").font(Theme.mono(11))
                        .foregroundStyle((row.termPeak ?? 0) > 1 ? Theme.magenta : Theme.text)
                    Text(row.correlation.map { String(format: "%.2f", $0) } ?? "—").font(Theme.mono(11)).foregroundStyle(Theme.text)
                    Text(row.picks.isEmpty ? "none" : "\(row.picks.count): " + row.picks.prefix(5).joined(separator: " "))
                        .font(Theme.mono(10)).foregroundStyle(Theme.strong).lineLimit(1)
                        .frame(maxWidth: 300, alignment: .leading)
                        .gridColumnAlignment(.leading)
                    num(row.returns["Thesis matches"]?[21])
                    num(row.returns["Top 10 score"]?[21])
                    num(row.returns["All stocks"]?[21])
                    num(row.benchmark[21])
                    Button("open") {
                        store.pickAnchor(.event(row.event.day))
                        dismiss()
                    }
                    .buttonStyle(TermButtonStyle(compact: true))
                    .help("Show this spike in the screener")
                }
            }
        }
    }

    // MARK: Helpers

    private func block<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Caption(title, color: Theme.accent)
                Theme.border.frame(height: 1)
            }
            content()
        }
    }

    private func num(_ v: Double?, bold: Bool = false) -> some View {
        Text(v?.pct ?? "—")
            .font(Theme.mono(11, bold ? .semibold : .regular))
            .foregroundStyle(v.map(Theme.signed) ?? Theme.muted)
    }

    private func color(_ strategy: String) -> Color {
        switch strategy {
        case "Thesis matches": Theme.cyan
        case "Top 10 score": Theme.green
        case "All stocks": Theme.base0
        case "Bottom 10 score": Theme.red
        default: Theme.yellow
        }
    }
}
