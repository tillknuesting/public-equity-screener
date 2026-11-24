import Charts
import SwiftUI

/// The risk-budget reversal factor: where it pays, how each variant did, and today's highest-ranked names.
struct FactorSheet: View {
    @Environment(ScreenerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var selected = "Weekly, momentum leaders"

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Risk-budget factor").font(Theme.label(16, .bold)).foregroundStyle(Theme.bright)
                if let r = store.factor {
                    Text("\(r.universe), weekly and monthly rebalancing, 2011–today").font(Theme.label(13)).foregroundStyle(Theme.text)
                }
                Spacer()
                Button("Rerun") { store.runFactor() }
                    .buttonStyle(TermButtonStyle(compact: true))
                    .disabled(store.isComputingFactor)
                Button("Close") { dismiss() }
                    .buttonStyle(TermButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(Theme.header)
            .overlay(alignment: .top) { Theme.magenta.frame(height: 2) }
            Theme.border.frame(height: 1)

            if let r = store.factor, !store.isComputingFactor {
                ScrollView { report(r).padding(14) }
            } else {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Rebuilding the factor every week since 2011…").font(Theme.label(13)).foregroundStyle(Theme.text)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 1240, idealWidth: 1320, minHeight: 780, idealHeight: 880)
        .background(Theme.panel)
    }

    private func report(_ r: FactorReport) -> some View {
        let variant = r.variants.first { $0.spec.name == selected } ?? r.variants[0]
        return VStack(alignment: .leading, spacing: 18) {
            Text("Institutions size positions by risk. When a stock's volatility jumps, its risk weight rises and holders trim regardless of value; whoever absorbs that selling is paid when it recovers. Each week the factor ranks stocks by −(drop in σ) × (recent ÷ prior volatility), and compares the top fifth with the bottom fifth. Survivorship bias mostly cancels in long−short; long-only is measured against the same universe.")
                .font(Theme.label(12.5)).foregroundStyle(Theme.text)
                .frame(maxWidth: 980, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            gate(r)

            HStack(alignment: .top, spacing: 18) {
                block("Where it pays: \(variant.spec.name.lowercased())") { regimeTable(variant) }
                    .frame(width: 560)
                block("Cumulative long−short return") { cumulativeChart(variant) }
            }
            block("All variants") { variantTable(r) }
            block("Highest-ranked today (momentum leaders, weekly signal)") { holdings(r) }
        }
    }

    // MARK: Sections

    private func gate(_ r: FactorReport) -> some View {
        HStack(alignment: .center, spacing: 14) {
            HStack(spacing: 8) {
                if r.gateOpen { PulseDot(color: Theme.green) } else { Circle().fill(Theme.muted).frame(width: 6, height: 6) }
                Text(r.gateOpen ? "Stress gate open" : "Stress gate closed")
                    .font(Theme.label(15, .bold)).foregroundStyle(r.gateOpen ? Theme.green : Theme.text)
            }
            Text(gateReason(r)).font(Theme.label(12.5)).foregroundStyle(Theme.text)
            Spacer()
        }
        .padding(10)
        .background((r.gateOpen ? Theme.green : Theme.muted).opacity(0.1))
        .overlay(Rectangle().stroke((r.gateOpen ? Theme.green : Theme.border).opacity(0.6), lineWidth: 1))
    }

    private func gateReason(_ r: FactorReport) -> String {
        var parts: [String] = []
        if let v = r.vixNow, let m = r.vixMedian {
            parts.append(String(format: "\(VolIndex.current.name) %.1f is %@ its 1-year median of %.1f", v, v > m ? "above" : "below", m))
        }
        if let c = r.creditWeek {
            parts.append(String(format: "high-yield spreads moved %+.0f bp over the last week%@", c, c >= 15 ? " (widening)" : ""))
        }
        let why = parts.joined(separator: "; ")
        return r.gateOpen
            ? "\(why). Historically the factor earned most in conditions like these."
            : "\(why). In calm conditions the weekly factor has had no reliable edge after costs."
    }

    private func regimeTable(_ v: FactorReport.Variant) -> some View {
        let rows: [(String, FactorReport.Summary)] = [
            ("All periods, before costs", v.gross),
            ("After 5 bp per side", v.net5),
            ("After 10 bp per side", v.net10),
            ("Long-only vs universe (5 bp)", v.longOnly),
            ("Calm: \(VolIndex.current.name) below 1-year median", v.calm),
            ("Stressed: \(VolIndex.current.name) above median", v.stressed),
            ("\(VolIndex.current.name) shock weeks (+20%)", v.shock),
            ("Credit spreads widening", v.creditWidening),
            ("Risk-budget: stress, BBB − AAA calm", v.riskBudget),
            ("Credit crisis: BBB − AAA widening", v.creditCrisis),
        ]
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(RiskBudgetFactor.specs, id: \.name) { spec in
                    Button(spec.name.replacingOccurrences(of: "momentum leaders", with: "mom. leaders")) {
                        withAnimation(Motion.ui) { selected = spec.name }
                    }
                    .buttonStyle(TermButtonStyle(selected: selected == spec.name, compact: true))
                }
            }
            Text(v.spec.note).font(Theme.label(11.5)).foregroundStyle(Theme.muted)
            Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    Caption("Regime").gridColumnAlignment(.leading)
                    Caption("per year"); Caption("Sharpe"); Caption("t"); Caption("periods")
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(rows, id: \.0) { label, s in
                    GridRow {
                        Text(label).font(Theme.label(12.5, .semibold)).foregroundStyle(Theme.bright).gridColumnAlignment(.leading)
                        Text(s.annReturn.pct).font(Theme.mono(11.5, .semibold)).foregroundStyle(Theme.signed(s.annReturn))
                        Text(String(format: "%+.2f", s.sharpe)).font(Theme.mono(11.5)).foregroundStyle(Theme.text)
                        tValue(s.t)
                        Text("\(s.periods)").font(Theme.mono(11)).foregroundStyle(Theme.muted)
                    }
                }
            }
            .animation(Motion.ui, value: selected)
        }
    }

    private func cumulativeChart(_ v: FactorReport.Variant) -> some View {
        struct Point: Identifiable { let date: Date; let value: Double; let series: String; var id: String { "\(series)\(date.timeIntervalSince1970)" } }
        var gross = 0.0, net = 0.0
        var points: [Point] = []
        for p in v.periods {
            gross += log(1 + p.longShort)
            net += log(1 + p.longShort - p.turnover * 2 * 2 * 5 / 10_000)
            let d = TradingDay.date(p.day)
            points.append(Point(date: d, value: exp(gross) - 1, series: "Before costs"))
            points.append(Point(date: d, value: exp(net) - 1, series: "After 5 bp"))
        }
        let stressed = v.periods.filter { $0.stressed || $0.creditWidening }
        return Chart {
            ForEach(stressed, id: \.day) { p in
                RectangleMark(xStart: .value("Start", TradingDay.date(p.day)),
                              xEnd: .value("End", TradingDay.date(p.day).addingTimeInterval(Double(v.spec.hold) * 1.45 * 86_400)))
                    .foregroundStyle(Theme.magenta.opacity(0.07))
            }
            RuleMark(y: .value("Zero", 0)).foregroundStyle(Theme.muted.opacity(0.6))
            ForEach(points) { p in
                LineMark(x: .value("Date", p.date), y: .value("Return", p.value * 100), series: .value("Series", p.series))
                    .foregroundStyle(by: .value("Series", p.series))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
        }
        .chartForegroundStyleScale(["Before costs": Theme.cyan, "After 5 bp": Theme.yellow])
        .chartLegend(position: .top, alignment: .leading)
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisGridLine().foregroundStyle(Theme.border)
                AxisValueLabel { if let d = value.as(Double.self) { Text(String(format: "%+.0f%%", d)) } }
                    .font(Theme.mono(9.5)).foregroundStyle(Theme.muted)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 8)) { _ in
                AxisGridLine().foregroundStyle(Theme.border)
                AxisValueLabel(format: .dateTime.year()).font(Theme.mono(9.5)).foregroundStyle(Theme.muted)
            }
        }
        .overlay(alignment: .bottomLeading) {
            Text("Shaded: stressed or credit-widening periods").font(Theme.label(11)).foregroundStyle(Theme.muted).padding(6)
        }
        .frame(height: 250)
        .animation(Motion.smooth, value: selected)
    }

    private func variantTable(_ r: FactorReport) -> some View {
        Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 6) {
            GridRow {
                Caption("Variant").gridColumnAlignment(.leading)
                Caption("gross"); Caption("t"); Caption("after 5 bp"); Caption("after 10 bp"); Caption("long-only")
                Caption("calm"); Caption("stressed"); Caption("credit widening"); Caption("t"); Caption("turnover")
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(r.variants) { v in
                GridRow {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(v.spec.name).font(Theme.label(12.5, .semibold)).foregroundStyle(selected == v.spec.name ? Theme.blue : Theme.bright)
                        Text(v.spec.note).font(Theme.label(10.5)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    .frame(maxWidth: 360, alignment: .leading)
                    .gridColumnAlignment(.leading)
                    num(v.gross.annReturn); tValue(v.gross.t)
                    num(v.net5.annReturn); num(v.net10.annReturn); num(v.longOnly.annReturn)
                    num(v.calm.annReturn); num(v.stressed.annReturn); num(v.creditWidening.annReturn); tValue(v.creditWidening.t)
                    Text(String(format: "%.0f%%", v.turnover * 100)).font(Theme.mono(11)).foregroundStyle(Theme.muted)
                }
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(Motion.ui) { selected = v.spec.name } }
            }
        }
    }

    private func holdings(_ r: FactorReport) -> some View {
        Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 5) {
            GridRow {
                Caption("#").gridColumnAlignment(.leading)
                Caption("Ticker").gridColumnAlignment(.leading)
                Caption("Name").gridColumnAlignment(.leading)
                Caption("5-day move"); Caption("drop σ"); Caption("vol shock"); Caption("momentum pct"); Caption("signal"); Text("")
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(Array(r.holdings.prefix(15).enumerated()), id: \.element.id) { i, h in
                GridRow {
                    Text("\(i + 1)").font(Theme.mono(11)).foregroundStyle(Theme.muted)
                    Text(h.instrument.symbol).font(Theme.mono(11.5, .bold)).foregroundStyle(Theme.bright)
                    Text("\(h.instrument.flag) \(h.instrument.name)").font(Theme.label(12.5)).foregroundStyle(Theme.strong).lineLimit(1)
                        .frame(maxWidth: 260, alignment: .leading)
                    num(h.move)
                    Text(String(format: "%.1fσ", h.z)).font(Theme.mono(11.5)).foregroundStyle(h.z <= -2 ? Theme.red : Theme.text)
                    Text(String(format: "%.1f×", h.volShock)).font(Theme.mono(11.5)).foregroundStyle(h.volShock >= 1.5 ? Theme.cyan : Theme.text)
                    Text("\(Int((h.momentumRank * 100).rounded()))").font(Theme.mono(11.5)).foregroundStyle(Theme.yellow)
                    Text(String(format: "%.1f", h.signal)).font(Theme.mono(11.5, .semibold)).foregroundStyle(Theme.bright)
                    Button("open") {
                        store.selection = h.id
                        dismiss()
                    }
                    .buttonStyle(TermButtonStyle(compact: true))
                    .disabled(!store.results.contains { $0.id == h.id })
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

    private func num(_ v: Double) -> some View {
        Text(v.pct).font(Theme.mono(11.5, .semibold)).foregroundStyle(Theme.signed(v))
    }

    private func tValue(_ t: Double) -> some View {
        Text(String(format: "%+.1f", t))
            .font(Theme.mono(11, abs(t) >= 2 ? .bold : .regular))
            .foregroundStyle(abs(t) >= 2 ? Theme.signed(t) : Theme.muted)
    }
}
