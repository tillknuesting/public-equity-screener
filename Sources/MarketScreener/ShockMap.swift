import Charts
import SwiftUI

/// Every stock on one picture of the thesis: momentum before the spike (across) against how
/// hard it was sold in the window (down). The bottom-right corner is the thesis zone.
struct ShockMap: View {
    @Environment(ScreenerStore.self) private var store
    var large = false
    @State private var hover: String?
    @State private var revealed = Motion.reduce

    static let zoneX = 100.0 * 2 / 3
    static let zoneY = -1.0
    static let yDomain = -5.0...4.0

    struct Point: Identifiable {
        let id: String
        let m: StockMetrics
        let x: Double
        let y: Double
        let diameter: CGFloat
        let color: Color
        let hasNews: Bool
        let inZone: Bool
    }

    var body: some View {
        let points = makePoints()
        let pickIDs = Set(store.topPicks.map(\.id))
        VStack(alignment: .leading, spacing: 8) {
            chart(points, labelled: points.filter { pickIDs.contains($0.id) || $0.id == store.selection })
            legend
        }
        .onAppear {
            guard !revealed else { return }
            // The shock lands: every stock falls from the zero line to its sell-off depth.
            withAnimation(.spring(duration: 1.1, bounce: 0.22).delay(0.1)) { revealed = true }
        }
    }

    private func chart(_ points: [Point], labelled: [Point]) -> some View {
        Chart {
            RectangleMark(xStart: .value("Momentum", Self.zoneX), xEnd: .value("Momentum", 100),
                          yStart: .value("Drop", Self.yDomain.lowerBound), yEnd: .value("Drop", Self.zoneY))
                .foregroundStyle(LinearGradient(colors: [Theme.green.opacity(0.04), Theme.green.opacity(0.2)],
                                                startPoint: .topLeading, endPoint: .bottomTrailing))
                .annotation(position: .overlay, alignment: .bottomTrailing) {
                    Text("Thesis zone").font(Theme.label(large ? 14 : 12, .semibold))
                        .foregroundStyle(Theme.green).padding(8)
                }
            RuleMark(y: .value("Flat", 0)).foregroundStyle(Theme.muted.opacity(0.6))
            RuleMark(x: .value("Momentum", Self.zoneX))
                .foregroundStyle(Theme.green.opacity(0.55)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            RuleMark(y: .value("Drop", Self.zoneY))
                .foregroundStyle(Theme.green.opacity(0.55)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))

            ForEach(points) { p in
                PointMark(x: .value("Momentum", p.x), y: .value("Drop", revealed ? p.y : 0))
                    .symbol {
                        MapDot(point: p, selected: store.selection == p.id, hovered: hover == p.id)
                    }
            }

            ForEach(labelled) { p in
                PointMark(x: .value("Momentum", p.x), y: .value("Drop", revealed ? p.y : 0))
                    .symbolSize(0)
                    .annotation(position: .trailing, alignment: .leading, spacing: p.diameter / 2 + 3,
                                overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        Text(p.m.symbol)
                            .font(Theme.mono(large ? 11.5 : 10, .bold))
                            .foregroundStyle(store.selection == p.id ? Theme.blue : Theme.bright)
                            .shadow(color: Theme.panel, radius: 2)
                    }
            }

            if let id = hover, let p = points.first(where: { $0.id == id }) {
                PointMark(x: .value("Momentum", p.x), y: .value("Drop", p.y))
                    .symbolSize(0)
                    .annotation(position: .top, spacing: p.diameter / 2 + 6,
                                overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        tooltip(p)
                    }
            }
        }
        .chartXScale(domain: 0...100)
        .chartYScale(domain: Self.yDomain)
        .chartXAxis {
            AxisMarks(values: [0, 25, 50, 75, 100]) { v in
                AxisGridLine().foregroundStyle(Theme.border)
                AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d))") } }
                    .font(Theme.mono(9.5)).foregroundStyle(Theme.muted)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [-5, -4, -3, -2, -1, 0, 1, 2, 3, 4]) { v in
                AxisGridLine().foregroundStyle(Theme.border)
                AxisValueLabel { if let d = v.as(Double.self) { Text(String(format: "%+.0fσ", d)) } }
                    .font(Theme.mono(9.5)).foregroundStyle(Theme.muted)
            }
        }
        .chartXAxisLabel(position: .bottom, alignment: .center) {
            Text("Momentum before the spike, percentile within the universe →").font(Theme.label(11.5)).foregroundStyle(Theme.text)
        }
        .chartYAxisLabel(position: .leading, alignment: .center) {
            Text("← Sold harder").font(Theme.label(11.5)).foregroundStyle(Theme.text)
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                let plot = proxy.plotFrame.map { geo[$0] } ?? .zero
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        if case .active(let location) = phase {
                            hover = nearest(to: location, in: points, proxy: proxy, plot: plot)
                        } else {
                            hover = nil
                        }
                    }
                    .onTapGesture { location in
                        if let id = nearest(to: location, in: points, proxy: proxy, plot: plot) {
                            withAnimation(Motion.ui) { store.selection = id }
                        }
                    }
            }
        }
        .animation(Motion.smooth, value: points.map(\.y))
    }

    private var legend: some View {
        HStack(spacing: 18) {
            legendItem("Colour: score") { Circle().fill(Theme.green).frame(width: 9, height: 9) }
            legendItem("Size: market cap") {
                HStack(spacing: 2) {
                    Circle().fill(Theme.muted).frame(width: 5, height: 5)
                    Circle().fill(Theme.muted).frame(width: 11, height: 11)
                }
            }
            legendItem("Filled: no company news (flow)") { Circle().fill(Theme.yellow).frame(width: 9, height: 9) }
            legendItem("Ring: news explains the drop") { Circle().strokeBorder(Theme.yellow, lineWidth: 1.5).frame(width: 9, height: 9) }
            Spacer()
            Text("Shows every stock; table filters don't apply").font(Theme.label(11)).foregroundStyle(Theme.muted)
        }
    }

    private func legendItem<V: View>(_ text: String, @ViewBuilder mark: () -> V) -> some View {
        HStack(spacing: 6) {
            mark()
            Text(text).font(Theme.label(11.5)).foregroundStyle(Theme.text)
        }
    }

    private func tooltip(_ p: Point) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(p.m.symbol).font(Theme.mono(11, .bold)).foregroundStyle(Theme.bright)
                Text("\(p.m.instrument.flag) \(p.m.name)").font(Theme.label(12)).foregroundStyle(Theme.strong).lineLimit(1)
                Spacer(minLength: 6)
                Readout(text: String(format: "%.0f", p.m.score.total), size: 18, color: Theme.score(p.m.score.total))
            }
            TokenLine(tokens: PickSummary.tokens(p.m), size: 10)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Theme.header)
        .overlay(Rectangle().stroke(Theme.border, lineWidth: 1))
        .fixedSize()
    }

    // MARK: Data

    private func makePoints() -> [Point] {
        let rows = store.results.filter { $0.momentum12_1 != nil }
        let maxCap = rows.compactMap(\.fundamentals.marketCapUSD).max() ?? 1
        let base: CGFloat = large ? 7 : 5, span: CGFloat = large ? 26 : 18
        return rows.map { m in
            let x = m.momentumRank * 100
            let y = min(max(m.zScore, Self.yDomain.lowerBound + 0.1), Self.yDomain.upperBound - 0.1)
            let diameter = m.fundamentals.marketCapUSD.map { base + span * CGFloat(($0 / maxCap).squareRoot()) } ?? base + span * 0.3
            let hasNews = if case .catalysts = m.news { true } else { false }
            return Point(id: m.id, m: m, x: x, y: y, diameter: diameter,
                         color: Theme.score(m.score.total), hasNews: hasNews,
                         inZone: x >= Self.zoneX && m.zScore <= Self.zoneY)
        }
        // Small dots last so they stay clickable on top of large ones.
        .sorted { $0.diameter > $1.diameter }
    }

    private func nearest(to location: CGPoint, in points: [Point], proxy: ChartProxy, plot: CGRect) -> String? {
        var best: (String, CGFloat)?
        for p in points {
            guard let pos = proxy.position(for: (x: p.x, y: p.y)) else { continue }
            let d = hypot(pos.x + plot.minX - location.x, pos.y + plot.minY - location.y)
            if d <= max(p.diameter / 2 + 4, 8), d < (best?.1 ?? .infinity) { best = (p.id, d) }
        }
        return best?.0
    }
}

private struct MapDot: View {
    let point: ShockMap.Point
    let selected: Bool
    let hovered: Bool

    var body: some View {
        let d = point.diameter
        ZStack {
            if point.hasNews {
                Circle().strokeBorder(point.color, lineWidth: 1.6)
            } else {
                Circle().fill(point.color)
            }
            if selected || hovered {
                Circle()
                    .strokeBorder(selected ? Theme.blue : Theme.bright, lineWidth: 2)
                    .frame(width: d + 8, height: d + 8)
            }
        }
        .frame(width: d, height: d)
        .opacity(point.inZone || selected || hovered ? 1 : 0.32)
        .shadow(color: point.inZone ? point.color.opacity(0.9) : .clear, radius: point.inZone ? 9 : 0)
        .scaleEffect(hovered && !Motion.reduce ? 1.25 : 1)
        .animation(Motion.reduce ? nil : .snappy(duration: 0.18), value: hovered)
    }
}
