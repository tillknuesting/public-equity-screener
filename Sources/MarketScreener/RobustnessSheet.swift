import SwiftUI

/// Heatmaps of the stress-gated backtest across neighbouring rule settings. A setting that only
/// works at exactly the chosen values was probably fitted to the past; a neighbourhood that
/// looks alike is more believable.
struct RobustnessSheet: View {
    @Environment(ScreenerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("robustnessMetric") private var metricName = Metric.vsIndex.rawValue
    @AppStorage("robustnessCost") private var costIndex = 0

    enum Metric: String, CaseIterable {
        case vsIndex = "vs index"
        case tIndex = "t vs index"
        case vsControl = "vs control"
        case tControl = "t vs control"
        case cost = "Cost / yr"

        var help: String {
            switch self {
            case .vsIndex: "Annual return minus the index's, after costs"
            case .tIndex: "t-stat of the weekly excess over the index; 2 is the usual bar"
            case .vsControl: "Annual return minus a control that holds every momentum leader under the same gate, tilt and review timing: what the ranking itself adds"
            case .tControl: "t-stat of the weekly difference to the control"
            case .cost: "Trading cost and transaction taxes per year"
            }
        }

        var isTStat: Bool { self == .tIndex || self == .tControl }

        func value(_ s: RobustnessReport.Score) -> Double {
            switch self {
            case .vsIndex: s.excess
            case .tIndex: s.tExcess
            case .vsControl: s.vsControl
            case .tControl: s.tControl
            case .cost: s.cost
            }
        }

        func format(_ v: Double) -> String {
            isTStat ? String(format: "%+.1f", v) : self == .cost ? String(format: "%.1f%%", v * 100) : String(format: "%+.1f%%", v * 100)
        }
    }

    private var metric: Metric { Metric(rawValue: metricName) ?? .vsIndex }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Robustness grid").font(Theme.label(16, .bold)).foregroundStyle(Theme.bright)
                if let r = store.robustness {
                    Text("\(r.universe), stress-gated tilt vs \(r.benchmarkName), \(r.volIndex) stress signal, \(String(format: "%.0f", r.years)) years of weekly data")
                        .font(Theme.label(13)).foregroundStyle(Theme.text)
                }
                Spacer()
                Button("Rerun") { store.runRobustness() }
                    .buttonStyle(TermButtonStyle(compact: true))
                    .disabled(store.isComputingRobustness)
                Button("Close") { dismiss() }
                    .buttonStyle(TermButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(Theme.header)
            .overlay(alignment: .top) { Theme.blue.frame(height: 2) }
            Theme.border.frame(height: 1)

            if let r = store.robustness, !store.isComputingRobustness {
                ScrollView { report(r).padding(14) }
            } else {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(store.benchmark == nil ? "Waiting for prices…" : "Rerunning the backtest for about 100 rule variants…")
                        .font(Theme.label(13)).foregroundStyle(Theme.text)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 1320, idealWidth: 1500, minHeight: 780, idealHeight: 900)
        .background(Theme.panel)
    }

    private func report(_ r: RobustnessReport) -> some View {
        let k = min(costIndex, r.costLevels.count - 1)
        let values = r.grids.flatMap { $0.cells.map { metric.value($0.scores[k]) } }
        let scale = Self.scale(values, metric: metric)
        return VStack(alignment: .leading, spacing: 14) {
            Text("We picked the low-turnover rule (3× exit buffer, review every 4 weeks, 4-week minimum hold, 4-week sticky gate, 50% tilt) after seeing results, which risks fitting the past. Each cell reruns the full weekly backtest with one pair of settings changed. If the outlined cell stands out from its neighbours, it is probably luck; if the neighbourhood looks alike, the effect is more believable. Research only: today's lists flatter every cell equally.")
                .font(Theme.label(12.5)).foregroundStyle(Theme.text)
                .frame(maxWidth: 1080, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 16) {
                HStack(spacing: 0) {
                    ForEach(Metric.allCases, id: \.self) { m in
                        Button(m.rawValue) { withAnimation(Motion.ui) { metricName = m.rawValue } }
                            .buttonStyle(TermButtonStyle(selected: metric == m, compact: true))
                            .help(m.help)
                    }
                }
                HStack(spacing: 6) {
                    Caption("Base cost per side")
                    HStack(spacing: 0) {
                        ForEach(r.costLevels.indices, id: \.self) { i in
                            Button("\(Int(r.costLevels[i])) bp") { withAnimation(Motion.ui) { costIndex = i } }
                                .buttonStyle(TermButtonStyle(selected: k == i, compact: true))
                        }
                    }
                    .help("Commission and spread per side; transaction taxes (UK stamp duty and others) always apply on top")
                }
                Spacer()
                ScaleLegend(metric: metric, scale: scale)
            }

            HStack(alignment: .top, spacing: 8) {
                ForEach(Array(r.grids.enumerated()), id: \.element.id) { i, grid in
                    HeatmapPanel(grid: grid, metric: metric, cost: k, scale: scale, offset: i * 6)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            Text("Cells share most of their weeks, so they are not independent tests; read the shape of each map rather than the best cell. The control holds every momentum leader under the same gate and timing, so “vs control” isolates what the ranking adds beyond being in stocks during stress.")
                .font(Theme.label(11.5)).foregroundStyle(Theme.muted)
                .frame(maxWidth: 1080, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One colour scale for all three maps, so the same colour means the same number.
    static func scale(_ values: [Double], metric: Metric) -> Double {
        let top = values.map(abs).max() ?? 0
        if metric.isTStat { return max(2.5, top) }
        return max(0.01, top)
    }
}

// MARK: - Heatmap

private struct HeatmapPanel: View {
    let grid: RobustnessReport.Grid
    let metric: RobustnessSheet.Metric
    let cost: Int
    let scale: Double
    let offset: Int
    @State private var hovered: RobustnessReport.Cell?
    @State private var shown = false

    var body: some View {
        let focus = hovered ?? grid.cell(grid.chosenRow, grid.chosenColumn)
        Panel(grid.title, marker: Theme.blue) {
            VStack(alignment: .leading, spacing: 10) {
                Text(grid.note)
                    .font(Theme.label(11.5)).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 30, alignment: .topLeading)

                Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                    GridRow {
                        Text(grid.rowTitle).font(Theme.label(10.5, .semibold)).foregroundStyle(Theme.muted)
                            .gridColumnAlignment(.leading)
                        ForEach(grid.columns.indices, id: \.self) { c in
                            Text(grid.columns[c])
                                .font(Theme.mono(10, c == grid.chosenColumn ? .bold : .regular))
                                .foregroundStyle(c == grid.chosenColumn ? Theme.bright : Theme.text)
                                .lineLimit(1).minimumScaleFactor(0.8)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    ForEach(grid.rows.indices, id: \.self) { r in
                        GridRow {
                            Text(grid.rows[r])
                                .font(Theme.mono(10, r == grid.chosenRow ? .bold : .regular))
                                .foregroundStyle(r == grid.chosenRow ? Theme.bright : Theme.text)
                                .lineLimit(1)
                                .frame(width: 84, alignment: .leading)
                            ForEach(grid.columns.indices, id: \.self) { c in
                                if let cell = grid.cell(r, c) {
                                    HeatCell(cell: cell, metric: metric, cost: cost, scale: scale,
                                             chosen: r == grid.chosenRow && c == grid.chosenColumn,
                                             focused: hovered?.id == cell.id)
                                        .onHover { inside in
                                            withAnimation(Motion.ui) { hovered = inside ? cell : (hovered?.id == cell.id ? nil : hovered) }
                                        }
                                        .opacity(shown ? 1 : 0)
                                        .scaleEffect(shown ? 1 : 0.85)
                                        .animation(Motion.stagger(offset + r + c), value: shown)
                                }
                            }
                        }
                    }
                    GridRow {
                        Color.clear.frame(height: 1)
                        Text(grid.columnTitle).font(Theme.label(10.5, .semibold)).foregroundStyle(Theme.muted)
                            .gridCellColumns(grid.columns.count)
                    }
                }

                if let focus { detail(focus) }
                summary
            }
            .padding(12)
        }
        .onAppear { shown = true }
    }

    /// Every number for the hovered cell (or the chosen one).
    private func detail(_ cell: RobustnessReport.Cell) -> some View {
        let s = cell.scores[cost]
        let chosen = cell.row == grid.chosenRow && cell.column == grid.chosenColumn
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("\(grid.rowTitle) \(grid.rows[cell.row]) · \(grid.columnTitle.lowercased()) \(grid.columns[cell.column])")
                    .font(Theme.label(12, .semibold)).foregroundStyle(Theme.bright)
                    .lineLimit(1).minimumScaleFactor(0.85)
                if chosen { Tag(text: "chosen", color: Theme.bright) }
            }
            HStack(spacing: 14) {
                stat("vs index", String(format: "%+.1f%%", s.excess * 100), t: s.tExcess)
                stat("vs control", String(format: "%+.1f%%", s.vsControl * 100), t: s.tControl)
                stat("cost / yr", String(format: "%.1f%%", s.cost * 100), t: nil)
                stat("tilt on", String(format: "%.0f%%", cell.activeShare * 100), t: nil)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.rowAlt)
        .overlay(Rectangle().stroke(Theme.border, lineWidth: 1))
        .contentTransition(.numericText())
    }

    private func stat(_ label: String, _ value: String, t: Double?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Caption(label)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(Theme.mono(12.5, .semibold)).foregroundStyle(Theme.bright)
                if let t {
                    Text(String(format: "t %.1f", t)).font(Theme.mono(10.5, abs(t) >= 2 ? .bold : .regular))
                        .foregroundStyle(abs(t) >= 2 ? Theme.strong : Theme.muted)
                }
            }
        }
    }

    /// How the chosen cell compares with the cells around it.
    private var summary: some View {
        let near = grid.neighbourhood().filter { !($0.row == grid.chosenRow && $0.column == grid.chosenColumn) }
        let chosen = grid.cell(grid.chosenRow, grid.chosenColumn).map { metric.value($0.scores[cost]) } ?? 0
        let nearValues = near.map { metric.value($0.scores[cost]) }
        let all = grid.cells.map { metric.value($0.scores[cost]) }
        let positive = metric == .cost ? nil : all.filter { $0 > 0 }.count
        let strong = metric.isTStat ? all.filter { $0 >= 2 }.count : nil
        let sorted = all.sorted()
        let percentile = Double(sorted.firstIndex { $0 >= chosen } ?? sorted.count) / Double(max(sorted.count - 1, 1))
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 14) {
                summaryStat("chosen", metric.format(chosen))
                summaryStat("neighbours avg", metric.format(Stats.mean(nearValues)))
                summaryStat("grid median", metric.format(sorted[sorted.count / 2]))
                if let positive { summaryStat("above zero", "\(positive)/\(all.count)") }
                if let strong { summaryStat("t ≥ 2", "\(strong)/\(all.count)") }
            }
            Text(metric == .cost ? "Lower is cheaper; costs do not depend on the signal."
                 : "The chosen cell ranks at the \(Int((percentile * 100).rounded()))th percentile of this map.")
                .font(Theme.label(11)).foregroundStyle(Theme.muted)
        }
    }

    private func summaryStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Caption(label)
            Text(value).font(Theme.mono(12, .semibold)).foregroundStyle(Theme.strong)
        }
    }
}

private struct HeatCell: View {
    let cell: RobustnessReport.Cell
    let metric: RobustnessSheet.Metric
    let cost: Int
    let scale: Double
    let chosen: Bool
    let focused: Bool

    /// Diverging blue (better) ↔ grey ↔ orange (worse); costs use a single orange ramp.
    private var fill: Color {
        let v = metric.value(cell.scores[cost])
        let strength = min(abs(v) / scale, 1)
        if metric == .cost { return Theme.orange.opacity(0.1 + 0.7 * strength) }
        let pole = v >= 0 ? Theme.blue : Theme.orange
        return pole.opacity(0.08 + 0.72 * strength)
    }

    var body: some View {
        let s = cell.scores[cost]
        let v = metric.value(s)
        let secondary: String? = switch metric {
        case .vsIndex: String(format: "t %.1f", s.tExcess)
        case .vsControl: String(format: "t %.1f", s.tControl)
        case .tIndex: String(format: "%+.1f%%", s.excess * 100)
        case .tControl: String(format: "%+.1f%%", s.vsControl * 100)
        case .cost: nil
        }
        VStack(spacing: 0) {
            Text(metric.format(v))
                .font(Theme.mono(12.5, chosen ? .bold : .semibold))
                .foregroundStyle(Theme.bright)
                .contentTransition(.numericText(value: v))
            if let secondary {
                Text(secondary).font(Theme.mono(9.5)).foregroundStyle(Theme.strong)
            }
        }
        .lineLimit(1).minimumScaleFactor(0.7)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background { ZStack { Theme.header; fill } }
        .overlay {
            ZStack {
                if chosen { Rectangle().strokeBorder(Theme.bright, lineWidth: 2) }
                if focused && !chosen { Rectangle().strokeBorder(Theme.strong, lineWidth: 1) }
            }
        }
        .zIndex(focused || chosen ? 1 : 0)
        .help("\(metric.format(v)) \(metric.rawValue)")
    }
}

/// The colour bar: what full orange, grey and full blue mean right now.
private struct ScaleLegend: View {
    let metric: RobustnessSheet.Metric
    let scale: Double

    var body: some View {
        HStack(spacing: 6) {
            if metric == .cost {
                Text("0%").font(Theme.mono(10)).foregroundStyle(Theme.text)
                LinearGradient(colors: [Theme.orange.opacity(0.1), Theme.orange.opacity(0.8)], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 140, height: 10)
                Text(metric.format(scale)).font(Theme.mono(10)).foregroundStyle(Theme.text)
            } else {
                Text(metric.format(-scale)).font(Theme.mono(10)).foregroundStyle(Theme.text)
                LinearGradient(colors: [Theme.orange.opacity(0.8), Theme.orange.opacity(0.08), Theme.blue.opacity(0.08), Theme.blue.opacity(0.8)],
                               startPoint: .leading, endPoint: .trailing)
                    .background(Theme.header)
                    .frame(width: 160, height: 10)
                Text(metric.format(scale)).font(Theme.mono(10)).foregroundStyle(Theme.text)
                Text("worse ← → better").font(Theme.label(10.5)).foregroundStyle(Theme.muted)
            }
        }
    }
}
