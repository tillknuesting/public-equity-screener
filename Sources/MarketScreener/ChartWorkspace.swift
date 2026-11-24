import SwiftUI

/// TradingView-style workspace: watchlist, chart toolbar, drawing tools and the chart.
struct ChartWorkspace: View {
    @Environment(ScreenerStore.self) private var store
    @State private var chart = ChartState()

    var body: some View {
        HStack(spacing: 6) {
            Watchlist(current: chart.symbol)
                .frame(width: 290)
            VStack(spacing: 0) {
                ChartToolbar(state: chart)
                Theme.border.frame(height: 1)
                HStack(spacing: 0) {
                    ToolPalette(state: chart)
                    Theme.border.frame(width: 1)
                    ProChartView(state: chart)
                        .background(Theme.panel)
                }
            }
            .background(Theme.panel)
            .overlay(Rectangle().stroke(Theme.border, lineWidth: 1))
        }
        .onAppear { load() }
        .onChange(of: store.chartSymbol) { _, _ in load() }
        .onChange(of: store.lastUpdated) { _, _ in load() }
        .onChange(of: store.universeKind) { _, _ in load() }
    }

    private func load() {
        let symbol = store.chartSymbol ?? store.selection ?? store.topPicks.first?.id ?? store.universe.first?.symbol
        guard let symbol, let series = store.series[symbol] else { return }
        chart.load(symbol: symbol, series: series, vix: store.vix, benchmark: store.benchmark, spikes: store.spikeDays)
    }
}

// MARK: - Toolbar

private struct ChartToolbar: View {
    @Environment(ScreenerStore.self) private var store
    @Bindable var state: ChartState

    var body: some View {
        HStack(spacing: 12) {
            if let symbol = state.symbol, let last = state.data.bars.last {
                let prev = state.data.bars.count > 1 ? state.data.bars[state.data.bars.count - 2].close : last.open
                let change = last.close / prev - 1
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(symbol).font(Theme.mono(15, .bold)).foregroundStyle(Theme.bright)
                    Readout(text: ChartMath.format(last.close), size: 22)
                    Text(change.pct).font(Theme.mono(12, .semibold)).foregroundStyle(Theme.signed(change))
                        .contentTransition(.numericText())
                }
                .animation(Motion.ui, value: symbol)
            }
            Spacer(minLength: 8)

            segmented(Timeframe.allCases.map(\.rawValue), selected: state.timeframe.rawValue) { v in
                withAnimation(Motion.ui) { state.timeframe = Timeframe(rawValue: v) ?? .day }
            }
            HStack(spacing: 0) {
                ForEach([("1M", 1.0), ("3M", 3), ("6M", 6), ("1Y", 12), ("3Y", 36), ("5Y", 60), ("All", 0)], id: \.0) { label, months in
                    Button(label) { withAnimation(Motion.smooth) { state.setRange(months: months == 0 ? nil : months) } }
                        .buttonStyle(TermButtonStyle(compact: true))
                }
            }
            Menu {
                Picker("Style", selection: $state.style) {
                    ForEach(ChartStyle.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label(state.style.rawValue, systemImage: "chart.bar.xaxis")
            }
            .menuStyle(.button).buttonStyle(TermButtonStyle(compact: true)).fixedSize()

            Menu {
                Section("On the price") {
                    ForEach(Indicator.allCases.filter { !$0.isPane }) { toggle($0) }
                }
                Section("Panes") {
                    ForEach(Indicator.allCases.filter(\.isPane)) { toggle($0) }
                }
            } label: {
                Label("Indicators", systemImage: "function")
            }
            .menuStyle(.button).buttonStyle(TermButtonStyle(compact: true)).fixedSize()

            Button("Log") { withAnimation(Motion.ui) { state.logScale.toggle() } }
                .buttonStyle(TermButtonStyle(selected: state.logScale, compact: true))
                .help("Logarithmic price scale")
            Button("Fit") { withAnimation(Motion.ui) { state.showLast(state.timeframe.defaultBars) } }
                .buttonStyle(TermButtonStyle(compact: true))
                .help("Reset the view (or double-click the chart)")
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(Theme.header)
        .overlay(alignment: .top) { Theme.blue.frame(height: 2) }
    }

    private func toggle(_ ind: Indicator) -> some View {
        Toggle(ind.title, isOn: Binding(
            get: { state.indicators.contains(ind) },
            set: { on in withAnimation(Motion.ui) { if on { state.indicators.insert(ind) } else { state.indicators.remove(ind) } } }))
    }

    private func segmented(_ values: [String], selected: String, action: @escaping (String) -> Void) -> some View {
        HStack(spacing: 0) {
            ForEach(values, id: \.self) { v in
                Button(v) { action(v) }.buttonStyle(TermButtonStyle(selected: v == selected, compact: true))
            }
        }
    }
}

// MARK: - Drawing tools

private struct ToolPalette: View {
    @Bindable var state: ChartState
    @State private var hovered: DrawingTool?

    var body: some View {
        VStack(spacing: 4) {
            ForEach(DrawingTool.allCases) { tool in
                Button {
                    withAnimation(Motion.ui) { state.tool = state.tool == tool && tool != .cursor ? .cursor : tool }
                } label: {
                    Image(systemName: tool.symbol)
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 30, height: 30)
                        .foregroundStyle(state.tool == tool ? Theme.base3 : hovered == tool ? Theme.bright : Theme.text)
                        .background(state.tool == tool ? Theme.blue : hovered == tool ? Theme.header : .clear, in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 ? tool : nil }
                .help(tool.title)
            }
            Theme.border.frame(width: 22, height: 1).padding(.vertical, 4)
            Button {
                withAnimation(Motion.ui) {
                    if let id = state.selectedDrawing { state.drawings.removeAll { $0.id == id }; state.selectedDrawing = nil }
                    else { state.drawings.removeAll() }
                    state.measure = nil
                }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 30, height: 30)
                    .foregroundStyle(state.drawings.isEmpty ? Theme.muted : Theme.red)
            }
            .buttonStyle(.plain)
            .help(state.selectedDrawing == nil ? "Remove all drawings on this chart" : "Remove the selected drawing (or press Delete)")
            Spacer()
            Text("\(state.drawings.count)").font(Theme.mono(10)).foregroundStyle(Theme.muted)
                .help("Drawings saved on this chart")
        }
        .padding(.vertical, 8)
        .frame(width: 42)
        .background(Theme.header.opacity(0.6))
    }
}

// MARK: - Watchlist

private struct Watchlist: View {
    @Environment(ScreenerStore.self) private var store
    let current: String?
    @State private var query = ""
    @AppStorage("watchlistFilter") private var filter = "All"
    @Namespace private var ns

    private struct Row: Identifiable {
        let instrument: Instrument
        let last: Double
        let change: Double
        let tag: String?
        var id: String { instrument.symbol }
    }

    private var rows: [Row] {
        let deskIDs = store.strategy?.positions.map(\.id) ?? []
        let pickIDs = store.topPicks.map(\.id)
        let symbols: [String] = switch filter {
        case "Factor": deskIDs
        case "Matches": pickIDs
        default: store.universe.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }.map(\.symbol)
        }
        let bySymbol = Dictionary(uniqueKeysWithValues: store.universe.map { ($0.symbol, $0) })
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return symbols.compactMap { s -> Row? in
            guard let inst = bySymbol[s], let c = store.series[s]?.closes, c.count > 1 else { return nil }
            if !q.isEmpty && !s.lowercased().contains(q) && !inst.name.lowercased().contains(q) { return nil }
            let tag = deskIDs.contains(s) ? "factor" : pickIDs.contains(s) ? "match" : nil
            return Row(instrument: inst, last: c[c.count - 1], change: c[c.count - 1] / c[c.count - 2] - 1, tag: tag)
        }
    }

    var body: some View {
        let rows = rows
        Panel("Watchlist · \(rows.count)", marker: Theme.blue) {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.muted)
                    TextField("Search ticker or name", text: $query)
                        .textFieldStyle(.plain)
                        .font(Theme.label(13))
                        .foregroundStyle(Theme.bright)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.muted) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(Theme.header)
                .overlay(Rectangle().stroke(Theme.border, lineWidth: 1))
                .padding(8)

                HStack(spacing: 0) {
                    ForEach(["Factor", "Matches", "All"], id: \.self) { f in
                        Button(f) { withAnimation(Motion.ui) { filter = f } }
                            .buttonStyle(TermButtonStyle(selected: filter == f, compact: true))
                    }
                    Spacer()
                }
                .padding(.horizontal, 8).padding(.bottom, 6)
                Theme.border.frame(height: 1)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(rows) { row in
                                WatchRow(row: (row.instrument, row.last, row.change, row.tag), selected: row.id == current, ns: ns)
                                    .id(row.id)
                                    .onTapGesture { withAnimation(Motion.ui) { store.openChart(row.id) } }
                            }
                        }
                        .animation(Motion.ui, value: rows.map(\.id))
                    }
                    .onChange(of: current) { _, id in if let id { withAnimation(Motion.ui) { proxy.scrollTo(id) } } }
                }
                .focusable()
                .focusEffectDisabled()
                .onKeyPress(.downArrow) { move(rows, 1); return .handled }
                .onKeyPress(.upArrow) { move(rows, -1); return .handled }
                .overlay {
                    if rows.isEmpty {
                        Text(filter == "Factor" ? "Open the Factor screen once to fill this list." : "Nothing to show.")
                            .font(Theme.label(12.5)).foregroundStyle(Theme.muted).padding()
                    }
                }
            }
        }
    }

    private func move(_ rows: [Row], _ delta: Int) {
        guard !rows.isEmpty else { return }
        let i = rows.firstIndex { $0.id == current } ?? (delta > 0 ? -1 : rows.count)
        withAnimation(Motion.ui) { store.openChart(rows[min(max(i + delta, 0), rows.count - 1)].id) }
    }
}

private struct WatchRow: View {
    let row: (instrument: Instrument, last: Double, change: Double, tag: String?)
    let selected: Bool
    let ns: Namespace.ID
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(row.instrument.symbol).font(Theme.mono(12, .bold)).foregroundStyle(selected ? Theme.blue : Theme.bright)
                    if let tag = row.tag { Tag(text: tag, color: tag == "factor" ? Theme.green : Theme.yellow) }
                }
                Text("\(row.instrument.flag) \(row.instrument.name)").font(Theme.label(11.5)).foregroundStyle(Theme.text).lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 1) {
                Text(ChartMath.format(row.last)).font(Theme.mono(11.5, .semibold)).foregroundStyle(Theme.bright)
                Text(row.change.pct).font(Theme.mono(10.5, .semibold)).foregroundStyle(Theme.signed(row.change))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            ZStack {
                if hover && !selected { Theme.header.opacity(0.7) }
                if selected { SelectionMark().matchedGeometryEffect(id: "watch-selection", in: ns) }
            }
        }
        .overlay(alignment: .bottom) { Theme.border.opacity(0.5).frame(height: 1) }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}
