import Charts
import SwiftUI

/// The period being analysed: key numbers, period shortcuts and an interactive VIX chart.
struct RegimePanel: View {
    @Environment(ScreenerStore.self) private var store

    var body: some View {
        Panel(title, marker: Theme.orange) {
            HStack(spacing: 3) {
                Caption("Zoom").padding(.trailing, 3)
                ForEach([("3M", 63), ("6M", 126), ("1Y", 252), ("2Y", 504), ("All", Int.max)], id: \.1) { label, span in
                    Button(label) { withAnimation(Motion.smooth) { store.chartSpan = span } }
                        .buttonStyle(TermButtonStyle(selected: store.chartSpan == span, compact: true))
                }
                Button("Expand") { store.expandedChart = .vix }
                    .buttonStyle(TermButtonStyle(compact: true))
                    .padding(.leading, 6)
                    .help("Open the \(VolIndex.current.name) chart large")
            }
        } content: {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    tiles
                    StressGauges()
                    Text(caption)
                        .font(Theme.label(11.5))
                        .foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    HStack(spacing: 4) {
                        Caption("Period").padding(.trailing, 3)
                        Button("1W") { withAnimation(Motion.ui) { store.pickRecent(sessions: 5) } }
                        Button("1M") { withAnimation(Motion.ui) { store.pickRecent(sessions: 21) } }
                        Button("3M") { withAnimation(Motion.ui) { store.pickRecent(sessions: 63) } }
                        Button("YTD") { withAnimation(Motion.ui) { store.pickYearToDate() } }
                        Button("Last spike") { withAnimation(Motion.ui) { store.resetToLatestSpike() } }
                            .help("Back to the most recent \(VolIndex.current.name) spike")
                    }
                    .buttonStyle(TermButtonStyle(compact: true))
                }
                .frame(width: 430, alignment: .leading)
                .animation(Motion.ui, value: store.period)
                .animation(Motion.ui, value: store.universeKind)
                VIXChart()
            }
            .padding(10)
        }
        .frame(height: 268)
    }

    private var title: String {
        if let r = store.selectedRange { return "Custom period · \(TradingDay.label(r.from)) → \(TradingDay.label(r.to))" }
        if let e = store.selectedEvent { return "Spike reaction · \(TradingDay.label(e.day))" }
        if let s = store.vixStatus { return "Last session · \(TradingDay.label(s.day))" }
        return "Volatility regime"
    }

    private var caption: String {
        let n = "\(store.window) session\(store.window == 1 ? "" : "s")"
        if store.selectedRange != nil {
            return "From the close before the period to its last close (\(store.rangeSessions) sessions). Drag on the chart to change it."
        }
        if store.selectedEvent != nil {
            return "Drop from each stock's last close before the shock, over \(n). Drag on the chart for any period."
        }
        return "Moves over the last \(n). Drag on the chart to pick a period, or click a red dot for a spike."
    }

    @ViewBuilder private var tiles: some View {
        let vix = store.vix.flatMap { move(of: $0.bars) }
        let bench = store.benchmark.flatMap { move(of: $0.bars) }
        HStack(alignment: .top, spacing: 18) {
            if store.anchor == .latest, let s = store.vixStatus {
                BigStat(label: VolIndex.current.name, value: String(format: "%.2f", s.level))
                BigStat(label: "\(VolIndex.current.name) 1D", value: s.change.pct, color: Theme.signed(-s.change))
                BigStat(label: "1Y pctile", value: "\(Int((s.percentile1y * 100).rounded()))")
            } else if let vix {
                BigStat(label: "\(VolIndex.current.name) chg", value: vix.move.pct, color: Theme.signed(-vix.move))
                BigStat(label: "\(VolIndex.current.name) peak", value: String(format: "%.1f", vix.peak))
            }
            if let bench {
                BigStat(label: store.universeKind.benchmarkName, value: bench.move.pct, color: Theme.signed(bench.move))
                if let since = bench.since { BigStat(label: "since", value: since.pct, color: Theme.signed(since)) }
            }
        }
    }

    /// Move over the selected period, the highest close inside it, and the move since it ended.
    private func move(of bars: [Bar]) -> (move: Double, peak: Double, since: Double?)? {
        guard let (start, end) = Screener.bounds(store.period, bars: bars), start >= 0, end > start else { return nil }
        let peak = bars[(start + 1)...end].map(\.close).max() ?? bars[end].close
        let since = !store.period.isTrailing && end < bars.count - 1 ? bars[bars.count - 1].close / bars[end].close - 1 : nil
        return (bars[end].close / bars[start].close - 1, peak, since)
    }
}

/// Market-wide footprints of forced selling over the selected period.
struct StressGauges: View {
    @Environment(ScreenerStore.self) private var store

    var body: some View {
        let g = store.gauges
        let corrHot = (g.correlation ?? 0) >= (g.correlationMedian ?? 1) + 0.1
        let spreadHot = (g.momentumSpread ?? 0) <= -0.02
        let termHot = (g.vixTermPeak ?? 0) > 1
        HStack(alignment: .top, spacing: 12) {
            gauge("Correlation", g.correlation.map { String(format: "%.2f", $0) },
                  note: g.correlationMedian.map { String(format: "median %.2f", $0) } ?? "", hot: corrHot)
                .help("Average pairwise correlation of daily returns (20 sessions, US-session names). When everything moves together, selling is indiscriminate de-risking.")
            gauge("Mom. spread", g.momentumSpread?.pct, note: "leaders − laggards", hot: spreadHot)
                .help("Move of the top-third momentum names minus the bottom third over the period. Strongly negative = momentum being unwound.")
            gauge("HY spread", g.creditChange.map { String(format: "%+.0f bp", $0) },
                  note: (g.creditChange ?? 0) >= 15 ? "widening" : "over the period", hot: (g.creditChange ?? 0) >= 15)
                .help("Implied high-yield credit spread change over the period, from HYG vs. 3–7y Treasuries (IEI). Widening spreads mean risk budgets are being cut across markets.")
            gauge("BBB − AAA", g.qualityChange.map { String(format: "%+.0f bp", $0) },
                  note: g.qualityWidening ? "credit crisis" : "4-week change", hot: g.qualityWidening)
                .help("Quality spread: Baa (BBB) minus Aaa corporate yields, change over 4 weeks (\(store.qualitySource)). It flags a credit crisis when the move is unusually large for the past year.")
            gauge("\(VolIndex.current.name) ÷ \(VolIndex.current.threeMonthName)", g.vixTermPeak.map { String(format: "%.2f", $0) }, note: termHot ? "inverted" : "normal", hot: termHot)
                .help("Peak \(VolIndex.current.name) ÷ \(VolIndex.current.threeMonthName) in the period. Above 1 the curve is inverted: acute, short-term stress.")
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 9)
        .background(Theme.header.opacity(0.5))
        .overlay(Rectangle().stroke(Theme.border, lineWidth: 1))
        .animation(Motion.ui, value: g.correlation)
        .animation(Motion.ui, value: g.momentumSpread)
        .animation(Motion.ui, value: g.vixTermPeak)
        .animation(Motion.ui, value: g.creditChange)
        .animation(Motion.ui, value: g.qualityChange)
    }

    private func gauge(_ label: String, _ value: String?, note: String, hot: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Caption(label)
            HStack(alignment: .center, spacing: 5) {
                Readout(text: value ?? "—", size: 18, color: hot ? Theme.magenta : Theme.bright)
                if hot { PulseDot() }
            }
            Text(note).font(Theme.label(10.5)).foregroundStyle(Theme.muted)
        }
    }
}

struct BigStat: View {
    let label: String
    let value: String
    var color: Color = Theme.bright

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Caption(label)
            Readout(text: value, size: 26, color: color)
        }
    }
}

/// VIX history. Drag to select a period, click near a red dot to pick that spike, hover to read values.
struct VIXChart: View {
    @Environment(ScreenerStore.self) private var store
    @State private var dragRange: ClosedRange<Date>?
    @State private var hover: Bar?

    var body: some View {
        let all = store.vix?.bars ?? []
        let bars = visibleBars(all)
        let spikes = bars.filter { store.spikeDays.contains($0.day) }
        let selection = dragRange ?? committedRange

        Chart {
            ForEach(bars, id: \.day) { bar in
                AreaMark(x: .value("Date", bar.date), y: .value("\(VolIndex.current.name)", bar.close))
                    .foregroundStyle(LinearGradient(colors: [Theme.yellow.opacity(0.22), Theme.yellow.opacity(0)],
                                                    startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Date", bar.date), y: .value("\(VolIndex.current.name)", bar.close))
                    .foregroundStyle(Theme.yellow)
                    .lineStyle(StrokeStyle(lineWidth: 1.2))
            }
            if let selection {
                RectangleMark(xStart: .value("From", selection.lowerBound), xEnd: .value("To", selection.upperBound))
                    .foregroundStyle(Theme.cyan.opacity(0.16))
                RuleMark(x: .value("From", selection.lowerBound)).foregroundStyle(Theme.cyan).lineStyle(StrokeStyle(lineWidth: 1))
                RuleMark(x: .value("To", selection.upperBound)).foregroundStyle(Theme.cyan).lineStyle(StrokeStyle(lineWidth: 1))
            } else if let anchor = (store.anchorDay ?? all.last?.day).map(TradingDay.date) {
                RuleMark(x: .value("Anchor", anchor))
                    .foregroundStyle(Theme.cyan)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            }
            ForEach(spikes, id: \.day) { bar in
                PointMark(x: .value("Date", bar.date), y: .value("\(VolIndex.current.name)", bar.close))
                    .symbolSize(16)
                    .foregroundStyle(Theme.red)
            }
            if let hover, dragRange == nil {
                RuleMark(x: .value("Hover", hover.date))
                    .foregroundStyle(Theme.muted)
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, spacing: 2, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        readout("\(TradingDay.label(hover.day))  \(VolIndex.current.name) \(String(format: "%.2f", hover.close))")
                    }
            }
        }
        .chartXScale(domain: (bars.first?.date ?? .now)...(bars.last?.date ?? .now))
        .chartYScale(domain: .automatic(includesZero: true))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                AxisGridLine().foregroundStyle(Theme.border)
                AxisValueLabel(format: store.chartSpan <= 126 ? .dateTime.day().month(.abbreviated) : .dateTime.month(.abbreviated).year(.twoDigits))
                    .font(Theme.mono(9)).foregroundStyle(Theme.muted)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(Theme.border)
                AxisValueLabel().font(Theme.mono(9)).foregroundStyle(Theme.muted)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                let plot = proxy.plotFrame.map { geo[$0] } ?? .zero
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard abs(value.translation.width) > 4,
                                      let a = date(at: value.startLocation.x, proxy, plot),
                                      let b = date(at: value.location.x, proxy, plot) else { return }
                                dragRange = min(a, b)...max(a, b)
                            }
                            .onEnded { value in
                                if let range = dragRange {
                                    store.pickRange(range)
                                } else if let d = date(at: value.location.x, proxy, plot) {
                                    store.selectNearestEvent(to: d)
                                }
                                dragRange = nil
                            }
                    )
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            hover = date(at: location.x, proxy, plot).flatMap { nearest(to: $0, in: bars) }
                        case .ended:
                            hover = nil
                        }
                    }
                if let dragRange {
                    readout(dragLabel(dragRange, in: all))
                        .position(x: plot.midX, y: plot.minY + 10)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private var committedRange: ClosedRange<Date>? {
        store.selectedRange.map { TradingDay.date($0.from)...TradingDay.date($0.to) }
    }

    /// The zoomed slice, widened if needed so the selected period stays in view.
    private func visibleBars(_ all: [Bar]) -> [Bar] {
        guard !all.isEmpty else { return [] }
        var from = max(0, all.count - min(store.chartSpan, all.count))
        let focusDay = store.selectedRange?.from ?? store.anchorDay
        if let day = focusDay, let i = all.lastIndex(onOrBefore: day) { from = min(from, max(0, i - 10)) }
        return Array(all[from...])
    }

    private func date(at x: CGFloat, _ proxy: ChartProxy, _ plot: CGRect) -> Date? {
        proxy.value(atX: min(max(x, plot.minX), plot.maxX) - plot.minX)
    }

    private func nearest(to date: Date, in bars: [Bar]) -> Bar? {
        bars.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }

    private func dragLabel(_ range: ClosedRange<Date>, in bars: [Bar]) -> String {
        let lo = TradingDay.day(from: range.lowerBound), hi = TradingDay.day(from: range.upperBound)
        let sessions = bars.filter { $0.day >= lo && $0.day <= hi }.count
        return "\(TradingDay.label(lo)) → \(TradingDay.label(hi)) · \(sessions) sessions"
    }

    private func readout(_ text: String) -> some View {
        Text(text)
            .font(Theme.mono(10, .semibold))
            .foregroundStyle(Theme.bright)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.header, in: Rectangle())
            .overlay(Rectangle().stroke(Theme.border, lineWidth: 1))
            .fixedSize()
    }
}
