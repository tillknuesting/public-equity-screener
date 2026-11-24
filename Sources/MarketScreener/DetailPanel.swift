import Charts
import SwiftUI

/// Per-stock detail: thesis checklist, chart, score breakdown, fundamentals and headlines.
struct DetailPanel: View {
    @Environment(ScreenerStore.self) private var store

    var body: some View {
        Panel("Detail", marker: Theme.blue) {
            if let m = store.selectedMetrics, let series = store.series[m.symbol] {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header(m)
                        ThesisChecklist(m: m)
                        PriceChart(bars: series.bars, windowStart: m.windowStartDay, windowEnd: m.windowEndDay,
                                   onTap: { withAnimation(Motion.ui) { store.openChart(m.symbol) } })
                            .frame(height: 190)
                            .overlay(alignment: .topTrailing) {
                                Text("Click to open in Chart").font(Theme.label(10.5)).foregroundStyle(Theme.muted).padding(6)
                            }
                        scoreSection(m)
                        reactionSection(m)
                        fundamentalsSection(m)
                        newsSection(m)
                    }
                    .padding(12)
                }
            } else {
                VStack(spacing: 8) {
                    Text("Select a stock in the screener or the top picks.")
                        .font(Theme.label(13)).foregroundStyle(Theme.text)
                    Text("↑ ↓ move through the list")
                        .font(Theme.label(11.5)).foregroundStyle(Theme.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func header(_ m: StockMetrics) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(m.instrument.flag) \(m.name)").font(Theme.label(19, .bold)).foregroundStyle(Theme.bright)
                    .contentTransition(.opacity)
                HStack(spacing: 8) {
                    Text(m.symbol).font(Theme.mono(11, .semibold)).foregroundStyle(Theme.strong)
                    Text(m.instrument.sector).font(Theme.label(12)).foregroundStyle(Theme.text)
                }
                .contentTransition(.opacity)
                HStack(spacing: 8) {
                    Text(String(format: "%.2f %@", m.price, m.currency)).font(Theme.mono(12, .semibold)).foregroundStyle(Theme.strong)
                    Text(m.windowReturn.pct).font(Theme.mono(12, .semibold)).foregroundStyle(Theme.signed(m.windowReturn))
                }
                .contentTransition(.numericText())
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                Readout(text: String(format: "%.0f", m.score.total), size: 46, color: Theme.score(m.score.total))
                Caption("Score")
            }
        }
    }

    private func scoreSection(_ m: StockMetrics) -> some View {
        Section(title: "Score breakdown") {
            ScoreLine(title: "Sold off hard", value: m.score.drop, max: ScoreBreakdown.maxDrop,
                      detail: String(format: "%.1fσ vs its own daily volatility", m.zScore))
            ScoreLine(title: "Momentum before", value: m.score.momentum, max: ScoreBreakdown.maxMomentum,
                      detail: "12-1M \(m.momentum12_1?.pct ?? "n/a") · \(Int((m.momentumRank * 100).rounded()))th percentile")
            ScoreLine(title: "Quality", value: m.score.quality, max: ScoreBreakdown.maxQuality,
                      detail: m.instrument.isFund ? "Not applicable to ETFs (held neutral)"
                          : m.instrument.isFinancial ? "Earnings yield + revenue growth (financial)" : "FCF yield, FCF margin, revenue growth")
            ScoreLine(title: "No company news", value: m.score.flow, max: ScoreBreakdown.maxFlow, detail: newsDetail(m.news))
            ScoreLine(title: "Volume surge", value: m.score.volume, max: ScoreBreakdown.maxVolume,
                      detail: m.volumeRatio.map { String(format: "%.1f× normal volume during the drop", $0) } ?? "No volume data")
            ScoreLine(title: "Oversold", value: m.score.oversold, max: ScoreBreakdown.maxOversold,
                      detail: String(format: "RSI(14) %.0f", m.rsi))
        }
    }

    private func reactionSection(_ m: StockMetrics) -> some View {
        Section(title: "Reaction") {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                row("Window", "\(TradingDay.label(m.windowStartDay)) → \(TradingDay.label(m.windowEndDay))")
                row("Move", m.windowReturn.pct, color: Theme.signed(m.windowReturn))
                row("\(store.universeKind.benchmarkName), same days", m.benchmarkReturn.pct)
                row("Beyond beta (β \(String(format: "%.2f", m.beta)))", m.excessReturn.pct, color: Theme.signed(m.excessReturn))
                row("Volume vs normal", m.volumeRatio.map { String(format: "%.1f×", $0) } ?? "—",
                    color: (m.volumeRatio ?? 0) >= 1.5 ? Theme.cyan : Theme.bright)
                row("3M before", m.return3m?.pct ?? "—")
                row("vs 200-day avg", m.vsSMA200.pct)
                row("From 52W high", m.fromHigh52w.pct)
                if let since = m.sincePreSpike { row("Now vs start", since.pct, color: Theme.signed(since)) }
                if let fwd = m.forwardReturn {
                    row("Since period end", fwd.pct, color: Theme.signed(fwd))
                    if let b = m.benchmarkForward { row("\(store.universeKind.benchmarkName) since", b.pct) }
                }
            }
        }
    }

    @ViewBuilder private func fundamentalsSection(_ m: StockMetrics) -> some View {
        if m.instrument.isFund {
            Section(title: "Fundamentals") {
                Text("ETF: no company fundamentals. The quality part of the score is held neutral (10/20).")
                    .font(Theme.label(12)).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            companyFundamentals(m)
        }
    }

    private func companyFundamentals(_ m: StockMetrics) -> some View {
        let f = m.fundamentals
        func percent(_ v: Double?) -> String { v.map { String(format: "%.1f%%", $0 * 100) } ?? "—" }
        return Section(title: "Fundamentals (TTM)") {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                row("Market cap", f.marketCapUSD.map { "$" + $0.compact } ?? "—")
                row("Free cash flow", f.fcfUSD.map { "$" + $0.compact } ?? "—", color: (f.fcfUSD ?? 0) < 0 ? Theme.red : Theme.bright)
                row("FCF yield", m.instrument.isFinancial ? "n/m" : percent(f.fcfYield))
                row("FCF margin", percent(f.fcfMargin))
                row("Operating margin", percent(f.operatingMargin))
                row("Revenue growth", f.revenueGrowth?.pct ?? "—", color: f.revenueGrowth.map(Theme.signed) ?? Theme.bright)
                row("P/E · fwd P/E", "\(f.pe.map { String(format: "%.1f", $0) } ?? "—") · \(f.forwardPE.map { String(format: "%.1f", $0) } ?? "—")")
            }
        }
    }

    private func newsSection(_ m: StockMetrics) -> some View {
        let items = store.news[m.symbol] ?? []
        let from = TradingDay.date(m.windowStartDay)
        let to = TradingDay.date(m.windowEndDay).addingTimeInterval(86_400)
        return Section(title: "Headlines") {
            if items.isEmpty {
                Text(store.isLoading ? "Loading headlines…" : "No headlines in the feed.")
                    .font(Theme.label(12)).foregroundStyle(Theme.muted)
            } else {
                VStack(spacing: 0) {
                    ForEach(items.prefix(15)) { item in
                        NewsRow(item: item, highlightCatalyst: true, inWindow: item.date >= from && item.date <= to)
                    }
                }
                .id(m.symbol)
                .transition(.opacity)
                .overlay(Rectangle().stroke(Theme.border, lineWidth: 1))
            }
        }
    }

    private func newsDetail(_ n: NewsSignal) -> String {
        switch n {
        case .quiet(let h): "No catalyst headlines in the drop (\(h) headline\(h == 1 ? "" : "s"))"
        case .catalysts(let c, let h): "\(c) of \(h) headlines look like company catalysts"
        case .unknown: "News feed doesn't reach back this far"
        }
    }

    private func row(_ label: String, _ value: String, color: Color = Theme.bright) -> some View {
        GridRow {
            Text(label).font(Theme.label(12.5)).foregroundStyle(Theme.text)
            Text(value).font(Theme.mono(11.5, .semibold)).foregroundStyle(color).contentTransition(.numericText())
        }
    }
}

private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Caption(title, color: Theme.accent)
                Theme.border.frame(height: 1)
            }
            content()
        }
    }
}

/// The thesis as a pass/fail checklist.
struct ThesisChecklist: View {
    let m: StockMetrics

    var body: some View {
        let newsQuiet: Bool? = { if case .unknown = m.news { return nil }; return m.news.isQuiet }()
        let checks: [(String, Bool?)] = [
            ("Sold off hard (≤ -1.5σ)", m.zScore <= -1.5),
            ("Momentum leader before (top third)", m.momentum12_1 == nil ? nil : m.isMomentumLeader),
            ("No catalyst headlines in the drop", newsQuiet),
            ("No earnings report in the window", m.earnings.known ? m.earnings.inWindow == nil : nil),
            ("Heavy volume (≥ 1.5× normal)", m.volumeRatio.map { $0 >= 1.5 }),
            ("Generates free cash flow", m.instrument.isFinancial || m.instrument.isFund ? nil : m.fundamentals.fcfYield.map { $0 > 0 }),
            ("Long-term trend intact (> 200D)", m.vsSMA200 > 0),
        ]
        let passed = checks.filter { $0.1 == true }.count
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Caption("Thesis check", color: Theme.accent)
                Spacer()
                Tag(text: "\(passed)/\(checks.count)", color: passed >= 4 ? Theme.green : passed >= 3 ? Theme.yellow : Theme.muted)
            }
            ForEach(checks, id: \.0) { label, ok in
                HStack(spacing: 8) {
                    Text(ok == true ? "✓" : ok == false ? "✗" : "–")
                        .font(Theme.mono(12, .bold))
                        .foregroundStyle(ok == true ? Theme.green : ok == false ? Theme.red : Theme.muted)
                        .frame(width: 12)
                    Text(label).font(Theme.label(12.5)).foregroundStyle(ok == false ? Theme.text : Theme.bright)
                }
            }
        }
        .padding(10)
        .background(Theme.header.opacity(0.5), in: Rectangle())
        .overlay(Rectangle().stroke(Theme.border, lineWidth: 1))
    }
}

struct ScoreLine: View {
    let title: String
    let value: Double
    let max: Double
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(Theme.label(12.5, .semibold)).foregroundStyle(Theme.bright)
                Spacer()
                Text(String(format: "%.0f/%.0f", value, max)).font(Theme.mono(11)).foregroundStyle(Theme.text)
                    .contentTransition(.numericText())
            }
            Meter(fraction: value / max, color: value / max >= 0.6 ? Theme.green : Theme.yellow)
                .frame(height: 4)
            Text(detail).font(Theme.label(11.5)).foregroundStyle(Theme.text).contentTransition(.opacity)
        }
    }
}

struct PriceChart: View {
    struct Point: Identifiable {
        let date: Date
        let value: Double
        let series: String
        var id: String { "\(series)-\(date.timeIntervalSince1970)" }
    }

    let bars: [Bar]
    let windowStart: Int
    let windowEnd: Int
    /// Sessions shown before and after the window end.
    var lookback = 180
    var lookahead = 90
    var onTap: (() -> Void)?
    @State private var hover: Bar?

    var body: some View {
        let points = makePoints()
        let values = points.map(\.value)
        let lo = values.min() ?? 0, hi = values.max() ?? 1
        let pad = (hi - lo) * 0.06
        let start = bars.lastIndex(onOrBefore: windowStart).map { bars[$0].close }

        Chart {
            RectangleMark(xStart: .value("Start", TradingDay.date(windowStart)),
                          xEnd: .value("End", TradingDay.date(windowEnd)))
                .foregroundStyle(Theme.red.opacity(0.18))
            ForEach(points) { p in
                LineMark(x: .value("Date", p.date), y: .value("Price", p.value), series: .value("Series", p.series))
                    .foregroundStyle(by: .value("Series", p.series))
                    .lineStyle(StrokeStyle(lineWidth: p.series == "Price" ? 1.5 : 1))
            }
            if let hover {
                RuleMark(x: .value("Hover", hover.date))
                    .foregroundStyle(Theme.muted)
                    .annotation(position: .top, spacing: 2, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        Text(readout(hover, start: start))
                            .font(Theme.mono(10, .semibold)).foregroundStyle(Theme.bright)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.header, in: Rectangle())
                            .overlay(Rectangle().stroke(Theme.border, lineWidth: 1))
                            .fixedSize()
                    }
            }
        }
        .chartForegroundStyleScale(["Price": Theme.bright, "50D": Theme.yellow, "200D": Theme.violet])
        .chartYScale(domain: (lo - pad)...(hi + pad))
        .chartLegend(position: .top, alignment: .leading, spacing: 4)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisGridLine().foregroundStyle(Theme.border)
                AxisValueLabel(format: lookback > 200 ? .dateTime.month(.abbreviated).year(.twoDigits) : .dateTime.month(.abbreviated))
                    .font(Theme.mono(9)).foregroundStyle(Theme.muted)
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisGridLine().foregroundStyle(Theme.border)
                AxisValueLabel().font(Theme.mono(9)).foregroundStyle(Theme.muted)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                let plot = proxy.plotFrame.map { geo[$0] } ?? .zero
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onTapGesture { onTap?() }
                    .onContinuousHover { phase in
                        guard case .active(let location) = phase,
                              let date: Date = proxy.value(atX: min(max(location.x, plot.minX), plot.maxX) - plot.minX) else {
                            hover = nil
                            return
                        }
                        hover = bars.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
                    }
            }
        }
        .padding(8)
        .overlay(Rectangle().stroke(Theme.border, lineWidth: 1))
    }

    private func readout(_ bar: Bar, start: Double?) -> String {
        let vsStart = start.map { "  \((bar.close / $0 - 1).pct) vs start" } ?? ""
        return "\(TradingDay.label(bar.day))  \(String(format: "%.2f", bar.close))\(vsStart)"
    }

    private func makePoints() -> [Point] {
        guard let end = bars.lastIndex(onOrBefore: windowEnd) else { return [] }
        let from = max(0, end - lookback)
        let to = min(bars.count - 1, end + lookahead)
        let closes = bars.map(\.close)
        var out: [Point] = []
        for i in from...to {
            let d = bars[i].date
            out.append(Point(date: d, value: closes[i], series: "Price"))
            if let s = Stats.sma(closes, period: 50, end: i) { out.append(Point(date: d, value: s, series: "50D")) }
            if let s = Stats.sma(closes, period: 200, end: i) { out.append(Point(date: d, value: s, series: "200D")) }
        }
        return out
    }
}
