import SwiftUI

private struct Column {
    let title: String
    let key: SortKey
    let width: CGFloat?   // nil = flexible
    var alignment: Alignment = .trailing
    var help: String
}

private let columns: [Column] = [
    .init(title: "Ticker", key: .ticker, width: 64, alignment: .leading, help: "Yahoo Finance ticker"),
    .init(title: "Name", key: .name, width: nil, alignment: .leading, help: "Company"),
    .init(title: "3M trend", key: .trend, width: 66, alignment: .center,
          help: "Last 3 months of closes; the red band is the reaction window. Sorts by the 3-month return before the window"),
    .init(title: "Move", key: .move, width: 56, help: "Move over the window or selected period"),
    .init(title: "Z", key: .z, width: 44, help: "Drop in units of the stock's own 60-day daily volatility"),
    .init(title: "Vol×", key: .volume, width: 40, help: "Volume during the drop vs. the 20 sessions before: heavy volume suggests forced selling"),
    .init(title: "Mom 12-1", key: .momentum, width: 62, help: "Return from 12 to 1 month before the window. Yellow = top third of the universe"),
    .init(title: "RSI", key: .rsi, width: 30, help: "RSI(14) at the end of the window"),
    .init(title: "FCF yld", key: .fcfYield, width: 54, help: "Trailing free cash flow / market cap (n/m for financials)"),
    .init(title: "Rev g", key: .growth, width: 56, help: "Revenue growth, year over year"),
    .init(title: "News", key: .news, width: 56, help: "FLOW = no catalyst headlines during the drop (likely forced selling)"),
    .init(title: "Earn", key: .earnings, width: 40, alignment: .center,
          help: "E = earnings report inside the window; E 5d = next report in 5 days"),
    .init(title: "vs pre", key: .recovery, width: 54, help: "Latest close vs. the close before the window or period"),
    .init(title: "Score", key: .score, width: 82, help: "Drop 30 · momentum 25 · quality 20 · no news 10 · volume 5 · oversold 10"),
]

struct ScreenerPanel: View {
    @Environment(ScreenerStore.self) private var store
    @FocusState private var focused: Bool
    @Namespace private var ns
    @AppStorage("screenerMode") private var mode = "table"

    var body: some View {
        let rows = store.visibleResults
        Panel("Screener · \(store.universeKind.title)") {
            HStack(spacing: 10) {
                if mode == "table" {
                    Text("\(rows.count) of \(store.results.count) shown")
                        .font(Theme.label(11.5)).foregroundStyle(Theme.muted)
                        .contentTransition(.numericText())
                        .animation(Motion.ui, value: rows.count)
                } else {
                    Button("Expand") { store.expandedChart = .shockMap }
                        .buttonStyle(TermButtonStyle(compact: true))
                }
                HStack(spacing: 0) {
                    Button("Table") { withAnimation(Motion.ui) { mode = "table" } }
                        .buttonStyle(TermButtonStyle(selected: mode == "table", compact: true))
                    Button("Map") { withAnimation(Motion.ui) { mode = "map" } }
                        .buttonStyle(TermButtonStyle(selected: mode == "map", compact: true))
                }
            }
        } content: {
            if mode == "map" {
                VStack(spacing: 0) {
                    FilterBar(showFilters: false)
                    Theme.border.frame(height: 1)
                    ShockMap()
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                }
                .transition(.opacity)
            } else {
                table(rows)
                    .transition(.opacity)
            }
        }
    }

    private func table(_ rows: [StockMetrics]) -> some View {
            VStack(spacing: 0) {
                FilterBar()
                Theme.border.frame(height: 1)
                HeaderRow()
                Theme.border.frame(height: 1)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, m in
                                ResultRow(m: m, index: index, selected: store.selection == m.id, ns: ns,
                                          bars: store.series[m.id]?.bars ?? [])
                                    .id(m.id)
                                    .onTapGesture {
                                        withAnimation(Motion.ui) { store.selection = m.id }
                                        focused = true
                                    }
                            }
                        }
                        .animation(Motion.ui, value: rows.map(\.id))
                    }
                    .onChange(of: store.selection) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
                .focusable()
                .focused($focused)
                .focusEffectDisabled()
                .onKeyPress(.downArrow) { withAnimation(Motion.ui) { store.moveSelection(by: 1) }; return .handled }
                .onKeyPress(.upArrow) { withAnimation(Motion.ui) { store.moveSelection(by: -1) }; return .handled }
                .overlay { emptyState(rows) }
            }
    }

    @ViewBuilder private func emptyState(_ rows: [StockMetrics]) -> some View {
        if store.results.isEmpty {
            Text(store.isLoading ? "Loading prices…" : "No data yet. Press Refresh.")
                .font(Theme.label(13)).foregroundStyle(Theme.muted)
        } else if rows.isEmpty {
            Text("Nothing matches. Loosen the filters or widen the reaction window.")
                .font(Theme.label(13)).foregroundStyle(Theme.muted)
        }
    }
}

private struct FilterBar: View {
    @Environment(ScreenerStore.self) private var store
    var showFilters = true

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                if let r = store.selectedRange {
                    Caption("Period").padding(.trailing, 3)
                    Text("\(TradingDay.label(r.from)) → \(TradingDay.label(r.to))")
                        .font(Theme.mono(11, .semibold)).foregroundStyle(Theme.cyan)
                    Text("\(store.rangeSessions) sessions").font(Theme.label(11.5)).foregroundStyle(Theme.muted)
                    Button("Clear") { withAnimation(Motion.ui) { store.resetToLatestSpike() } }
                        .buttonStyle(TermButtonStyle(compact: true))
                        .help("Back to the most recent \(VolIndex.current.name) spike")
                } else {
                    Caption(store.selectedEvent != nil ? "Reaction window" : "Window")
                        .padding(.trailing, 3)
                    ForEach([1, 2, 3, 5, 10], id: \.self) { n in
                        Button("\(n)D") { withAnimation(Motion.ui) { store.window = n } }
                            .buttonStyle(TermButtonStyle(selected: store.window == n))
                    }
                }
                Spacer(minLength: 12)
                if showFilters {
                Toggle("Declines", isOn: $store.onlyDeclines).toggleStyle(CheckToggleStyle())
                }
                if showFilters && store.onlyDeclines {
                    Slider(value: $store.minDecline, in: 0...0.10, step: 0.005)
                        .frame(width: 90)
                        .tint(Theme.accent)
                    Text(String(format: "≤ -%.1f%%", store.minDecline * 100))
                        .font(Theme.mono(10, .semibold)).foregroundStyle(Theme.strong)
                        .frame(width: 56, alignment: .leading)
                }
            }
            if showFilters {
            HStack(spacing: 16) {
                Toggle("Momentum leaders", isOn: $store.momentumLeaders).toggleStyle(CheckToggleStyle())
                    .help("Top third of the universe by 12-1 month momentum before the spike")
                Toggle("FCF > 0", isOn: $store.positiveFCF).toggleStyle(CheckToggleStyle())
                    .help("Positive trailing free cash flow (financials pass)")
                Toggle("No-news drops", isOn: $store.noNewsOnly).toggleStyle(CheckToggleStyle())
                    .help("No company catalyst headlines during the drop: more likely forced selling")
                Spacer()
            }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

private struct HeaderRow: View {
    @Environment(ScreenerStore.self) private var store

    var body: some View {
        HStack(spacing: 6) {
            ForEach(columns, id: \.title) { col in
                let active = store.sortKey == col.key
                Button { withAnimation(Motion.ui) { store.toggleSort(col.key) } } label: {
                    Caption(col.title + (active ? (store.sortAscending ? " ▲" : " ▼") : ""),
                            color: active ? Theme.accent : Theme.muted)
                        .frame(maxWidth: col.width == nil ? .infinity : col.width, alignment: col.alignment)
                        .frame(width: col.width)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(col.help)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Theme.header)
    }
}

private struct ResultRow: View {
    let m: StockMetrics
    let index: Int
    let selected: Bool
    let ns: Namespace.ID
    let bars: [Bar]
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            cell(.ticker) { Text(m.symbol).font(Theme.mono(11.5, .bold)).foregroundStyle(selected ? Theme.blue : Theme.bright) }
            cell(.name) {
                Text("\(m.instrument.flag) \(m.name)").font(Theme.label(13)).foregroundStyle(Theme.strong).lineLimit(1)
            }
            cell(.trend) {
                RowSparkline(bars: bars, windowStart: m.windowStartDay, windowEnd: m.windowEndDay)
                    .frame(width: 62, height: 16)
            }
            cell(.move) { pct(m.windowReturn) }
            cell(.z) {
                Text(String(format: "%.1fσ", m.zScore)).font(Theme.mono(11.5))
                    .foregroundStyle(m.zScore <= -2 ? Theme.red : m.zScore <= -1 ? Theme.orange : Theme.text)
            }
            cell(.volume) {
                if let v = m.volumeRatio {
                    Text(String(format: "%.1f×", v)).font(Theme.mono(11.5))
                        .foregroundStyle(v >= 1.5 ? Theme.cyan : Theme.text)
                } else { dash }
            }
            cell(.momentum) {
                if let mom = m.momentum12_1 {
                    Text(mom.pct).font(Theme.mono(11.5, m.isMomentumLeader ? .bold : .regular))
                        .foregroundStyle(m.isMomentumLeader ? Theme.yellow : Theme.text)
                } else { dash }
            }
            cell(.rsi) {
                Text(String(format: "%.0f", m.rsi)).font(Theme.mono(11.5))
                    .foregroundStyle(m.rsi < 30 ? Theme.orange : Theme.text)
            }
            cell(.fcfYield) {
                if m.instrument.isFund { Text("n/a").font(Theme.mono(11)).foregroundStyle(Theme.muted) }
                else if m.instrument.isFinancial { Text("n/m").font(Theme.mono(11)).foregroundStyle(Theme.muted) }
                else if let y = m.fundamentals.fcfYield {
                    Text(String(format: "%.1f%%", y * 100)).font(Theme.mono(11.5))
                        .foregroundStyle(y > 0.04 ? Theme.green : y > 0 ? Theme.strong : Theme.red)
                } else { dash }
            }
            cell(.growth) {
                if m.instrument.isFund { Text("n/a").font(Theme.mono(11)).foregroundStyle(Theme.muted) }
                else if let g = m.fundamentals.revenueGrowth { pct(g) } else { dash }
            }
            cell(.news) { newsTag }
            cell(.earnings) {
                // A real container, so rows without a flag still keep the column's width.
                ZStack { Color.clear; EarningsMark(timing: m.earnings).minimumScaleFactor(0.8) }
            }
            cell(.recovery) { if let r = m.sincePreSpike { pct(r) } else { dash } }
            cell(.score) {
                HStack(spacing: 6) {
                    Meter(fraction: m.score.total / 100, color: Theme.score(m.score.total)).frame(height: 5)
                    Text(String(format: "%.0f", m.score.total)).font(Theme.mono(12, .bold))
                        .foregroundStyle(Theme.score(m.score.total)).frame(width: 24, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 25)
        .background {
            ZStack {
                (index.isMultiple(of: 2) ? Theme.panel : Theme.rowAlt)
                if hover && !selected { Theme.header.opacity(0.7) }
                if selected { SelectionMark().matchedGeometryEffect(id: "row-selection", in: ns) }
            }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }

    @ViewBuilder private var newsTag: some View {
        switch m.news {
        case .quiet: Tag(text: "flow", color: Theme.green)
        case .catalysts(let n, _): Tag(text: "news \(n)", color: Theme.magenta)
        case .unknown: dash
        }
    }

    private var dash: some View { Text("—").font(Theme.mono(11)).foregroundStyle(Theme.muted) }

    private func pct(_ v: Double) -> some View {
        Text(v.pct).font(Theme.mono(11.5)).foregroundStyle(Theme.signed(v))
    }

    private func cell<C: View>(_ key: SortKey, @ViewBuilder _ content: () -> C) -> some View {
        let col = columns.first { $0.key == key }!
        return content()
            .frame(maxWidth: col.width == nil ? .infinity : col.width, alignment: col.alignment)
            .frame(width: col.width)
    }
}

/// A compact earnings flag: "E" in orange when a report falls inside the window (the drop may be
/// the report, not forced selling), "E 3d" in blue when one is due within two weeks.
struct EarningsMark: View {
    let timing: EarningsTiming

    var body: some View {
        if let e = timing.inWindow {
            mark("E", color: Theme.orange)
                .help("Earnings on \(TradingDay.label(e.day)) (\(e.timingNote)), inside the window: the move may be the report rather than forced selling")
        } else if let d = timing.daysToNext, d <= 14, let next = timing.next {
            mark("E \(max(d, 0))d", color: Theme.blue)
                .help("Next earnings \(TradingDay.label(next.day)) (\(next.estimate ? "estimated date" : next.timingNote)), \(max(d, 0)) days after the window")
        }
    }

    private func mark(_ text: String, color: Color) -> some View {
        Text(text)
            .font(Theme.mono(9.5, .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 3).padding(.vertical, 0.5)
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(color.opacity(0.7), lineWidth: 1))
            .lineLimit(1)
    }
}

/// The last ~3 months of closes, with the reaction window shaded, coloured by the 3-month move.
private struct RowSparkline: View {
    let bars: [Bar]
    let windowStart: Int
    let windowEnd: Int

    var body: some View {
        Canvas { ctx, size in
            // Show 63 sessions ending at the window's end, or at the latest close if that comes sooner.
            guard let endIndex = bars.lastIndex(where: { $0.day <= max(windowEnd, windowStart) }) ?? bars.indices.last,
                  endIndex > 5 else { return }
            let tail = min(10, bars.count - 1 - endIndex)   // a little of what came after the window
            let slice = bars[max(0, endIndex - 63 + tail)...(endIndex + tail)]
            let closes = slice.map(\.close)
            guard let lo = closes.min(), let hi = closes.max(), hi > lo else { return }
            let n = closes.count
            func x(_ i: Int) -> CGFloat { CGFloat(i) / CGFloat(max(n - 1, 1)) * (size.width - 3) + 1.5 }
            func y(_ v: Double) -> CGFloat { size.height - 2 - CGFloat((v - lo) / (hi - lo)) * (size.height - 4) }

            // Reaction window band.
            let days = slice.map(\.day)
            if let a = days.firstIndex(where: { $0 >= windowStart }), let b = days.lastIndex(where: { $0 <= windowEnd }), b >= a {
                let rect = CGRect(x: x(a), y: 0, width: max(x(b) - x(a), 2), height: size.height)
                ctx.fill(Path(rect), with: .color(Theme.red.opacity(0.18)))
            }

            var line = Path()
            for (i, v) in closes.enumerated() {
                let p = CGPoint(x: x(i), y: y(v))
                if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
            }
            let up = closes.last! >= closes.first!
            let color = up ? Theme.green : Theme.red
            var area = line
            area.addLine(to: CGPoint(x: x(n - 1), y: size.height))
            area.addLine(to: CGPoint(x: x(0), y: size.height))
            area.closeSubpath()
            ctx.fill(area, with: .linearGradient(Gradient(colors: [color.opacity(0.22), color.opacity(0)]),
                                                 startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            ctx.stroke(line, with: .color(color.opacity(0.9)), lineWidth: 1.1)
            let last = CGPoint(x: x(n - 1), y: y(closes.last!))
            ctx.fill(Path(ellipseIn: CGRect(x: last.x - 1.8, y: last.y - 1.8, width: 3.6, height: 3.6)), with: .color(color))
        }
    }
}
