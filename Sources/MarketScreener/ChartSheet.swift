import Charts
import SwiftUI

private let spans: [(String, Int)] = [("3M", 63), ("6M", 126), ("1Y", 252), ("2Y", 504), ("All", 10_000)]

/// A chart opened large: the VIX chart, or a stock's price chart with VIX underneath.
struct ChartSheet: View {
    let chart: ExpandedChart
    @Environment(ScreenerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var priceSpan = 252

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                title
                Spacer()
                if chart != .shockMap {
                    Caption("Zoom")
                    HStack(spacing: 3) {
                        ForEach(spans, id: \.1) { label, span in
                            Button(label) { withAnimation(Motion.smooth) { setSpan(span) } }
                                .buttonStyle(TermButtonStyle(selected: currentSpan == span, compact: true))
                        }
                    }
                }
                Button("Close") { dismiss() }
                    .buttonStyle(TermButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .padding(.leading, 8)
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(Theme.header)
            .overlay(alignment: .top) { (chart == .vix ? Theme.orange : chart == .shockMap ? Theme.green : Theme.blue).frame(height: 2) }
            Theme.border.frame(height: 1)

            content
                .padding(14)
        }
        .frame(minWidth: 1200, idealWidth: 1400, minHeight: 720, idealHeight: 820)
        .background(Theme.panel)
    }

    private var currentSpan: Int { chart == .vix ? min(store.chartSpan, 10_000) : priceSpan }

    private func setSpan(_ span: Int) {
        if chart == .vix { store.chartSpan = span } else { priceSpan = span }
    }

    @ViewBuilder private var title: some View {
        switch chart {
        case .shockMap:
            Text("Shock map").font(Theme.label(16, .bold)).foregroundStyle(Theme.bright)
            Text("\(store.picksContext.replacingOccurrences(of: " · ", with: ", ")), \(store.results.count) stocks")
                .font(Theme.label(13)).foregroundStyle(Theme.text)
        case .vix:
            Text("\(VolIndex.current.name)").font(Theme.label(16, .bold)).foregroundStyle(Theme.bright)
            Text("CBOE volatility index").font(Theme.label(13)).foregroundStyle(Theme.text)
        case .price(let symbol):
            if let m = store.results.first(where: { $0.symbol == symbol }) {
                HStack(spacing: 10) {
                    Text("\(m.instrument.flag) \(m.name)").font(Theme.label(16, .bold)).foregroundStyle(Theme.bright)
                    Text(m.symbol).font(Theme.mono(11)).foregroundStyle(Theme.text)
                    Text(String(format: "%.2f %@", m.price, m.currency)).font(Theme.mono(11, .semibold)).foregroundStyle(Theme.strong)
                    Text(m.windowReturn.pct).font(Theme.mono(11, .semibold)).foregroundStyle(Theme.signed(m.windowReturn))
                    Readout(text: String(format: "%.0f", m.score.total), size: 22, color: Theme.score(m.score.total))
                }
            } else {
                Caption(symbol, color: Theme.strong)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch chart {
        case .shockMap:
            ShockMap(large: true)
        case .vix:
            VStack(alignment: .leading, spacing: 8) {
                VIXChart()
                Text("Drag to select a period · click near a red dot to analyse that spike · hover to read values")
                    .font(Theme.label(11.5)).foregroundStyle(Theme.muted)
            }
        case .price(let symbol):
            if let m = store.results.first(where: { $0.symbol == symbol }), let bars = store.series[symbol]?.bars {
                let end = bars.lastIndex(onOrBefore: m.windowEndDay) ?? bars.count - 1
                let from = bars[max(0, end - priceSpan)].date
                let to = bars[bars.count - 1].date
                VStack(spacing: 10) {
                    PriceChart(bars: bars, windowStart: m.windowStartDay, windowEnd: m.windowEndDay,
                               lookback: priceSpan, lookahead: bars.count)
                    VStack(alignment: .leading, spacing: 4) {
                        Caption("\(VolIndex.current.name) over the same dates")
                        VIXStrip(bars: (store.vix?.bars ?? []).filter { $0.date >= from && $0.date <= to },
                                 spikeDays: store.spikeDays, domain: from...to,
                                 window: TradingDay.date(m.windowStartDay)...TradingDay.date(m.windowEndDay))
                    }
                    .frame(height: 170)
                }
            } else {
                Text("No data for \(symbol).").font(Theme.label(13)).foregroundStyle(Theme.muted)
            }
        }
    }
}

/// Compact, non-interactive VIX chart aligned under a price chart.
struct VIXStrip: View {
    let bars: [Bar]
    let spikeDays: Set<Int>
    let domain: ClosedRange<Date>
    let window: ClosedRange<Date>

    var body: some View {
        Chart {
            RectangleMark(xStart: .value("Start", window.lowerBound), xEnd: .value("End", window.upperBound))
                .foregroundStyle(Theme.red.opacity(0.18))
            ForEach(bars, id: \.day) { bar in
                AreaMark(x: .value("Date", bar.date), y: .value("\(VolIndex.current.name)", bar.close))
                    .foregroundStyle(LinearGradient(colors: [Theme.yellow.opacity(0.22), Theme.yellow.opacity(0)],
                                                    startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Date", bar.date), y: .value("\(VolIndex.current.name)", bar.close))
                    .foregroundStyle(Theme.yellow)
                    .lineStyle(StrokeStyle(lineWidth: 1.1))
            }
            ForEach(bars.filter { spikeDays.contains($0.day) }, id: \.day) { bar in
                PointMark(x: .value("Date", bar.date), y: .value("\(VolIndex.current.name)", bar.close))
                    .symbolSize(14)
                    .foregroundStyle(Theme.red)
            }
        }
        .chartXScale(domain: domain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                AxisGridLine().foregroundStyle(Theme.border)
                AxisValueLabel(format: .dateTime.month(.abbreviated).year(.twoDigits)).font(Theme.mono(9)).foregroundStyle(Theme.muted)
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(Theme.border)
                AxisValueLabel().font(Theme.mono(9)).foregroundStyle(Theme.muted)
            }
        }
        .padding(8)
        .overlay(Rectangle().stroke(Theme.border, lineWidth: 1))
    }
}
