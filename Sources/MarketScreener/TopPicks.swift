import AppKit
import SwiftUI

enum PickSummary {
    /// The case for a pick as colour-coded tokens: drop, volume, prior momentum, cash flow, news.
    static func tokens(_ m: StockMetrics) -> [(text: String, color: Color)] {
        var out: [(String, Color)] = [("\(m.windowReturn.pct) \(String(format: "%.1fσ", m.zScore))", Theme.red)]
        if let v = m.volumeRatio, v >= 1.3 { out.append((String(format: "%.1f× vol", v), Theme.cyan)) }
        if let mom = m.momentum12_1 { out.append(("mom \(mom.pct)", Theme.yellow)) }
        if let y = m.fundamentals.fcfYield, !m.instrument.isFinancial, !m.instrument.isFund {
            out.append((String(format: "FCF %.1f%%", y * 100), Theme.green))
        }
        if m.news.isQuiet { out.append(("no news", Theme.muted)) }
        if let e = m.earnings.upcomingLabel { out.append((e, Theme.blue)) }
        return out
    }

    /// Plain-text version for the terminal.
    static func reasons(_ m: StockMetrics) -> [String] { tokens(m).map(\.text) }
}

/// Reason tokens laid out with space, not separators; colour carries the meaning.
/// Drops whole tokens from the end rather than cutting one in half when space is short.
struct TokenLine: View {
    let tokens: [(text: String, color: Color)]
    var size: CGFloat = 10

    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach((1...max(tokens.count, 1)).reversed(), id: \.self) { n in
                HStack(spacing: 9) {
                    ForEach(Array(tokens.prefix(n).enumerated()), id: \.offset) { _, t in
                        Text(t.text).font(Theme.mono(size, .medium)).foregroundStyle(t.color).fixedSize()
                    }
                }
            }
        }
    }
}

/// The automatic shortlist above the screener table.
struct TopPicksStrip: View {
    @Environment(ScreenerStore.self) private var store
    @Namespace private var ns

    var body: some View {
        let picks = store.topPicks
        Panel("Top matches · \(store.picksContext)", marker: Theme.green) {
            Text("Drop ≥ 1σ, momentum leader, no company news, positive FCF")
                .font(Theme.label(11.5)).foregroundStyle(Theme.muted)
        } content: {
            if picks.isEmpty {
                Text(store.results.isEmpty ? "Waiting for data…" : "No stock passes every check for this period. Try a wider reaction window or another spike.")
                    .font(Theme.label(12.5)).foregroundStyle(Theme.muted)
                    .padding(10)
            } else {
                HStack(spacing: 6) {
                    ForEach(Array(picks.enumerated()), id: \.element.id) { rank, m in
                        PickCard(rank: rank + 1, m: m, selected: store.selection == m.id, ns: ns,
                                 closes: store.series[m.id].map { Array($0.closes.suffix(63)) } ?? [])
                            .id(m.id)
                            .onTapGesture { withAnimation(Motion.ui) { store.selection = m.id } }
                    }
                    ForEach(picks.count..<5, id: \.self) { _ in Color.clear.frame(maxWidth: .infinity) }
                }
                .padding(6)
            }
        }
        .frame(height: 106)
    }
}

struct PickCard: View {
    let rank: Int
    let m: StockMetrics
    let selected: Bool
    let ns: Namespace.ID
    var closes: [Double] = []
    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(rank)").font(Theme.mono(11, .semibold)).foregroundStyle(Theme.muted)
                Text(m.symbol).font(Theme.mono(13, .bold)).foregroundStyle(selected ? Theme.blue : Theme.bright)
                Spacer(minLength: 2)
                Readout(text: String(format: "%.0f", m.score.total), size: 24, color: Theme.score(m.score.total))
            }
            HStack(spacing: 6) {
                Text("\(m.instrument.flag) \(m.name)").font(Theme.label(12.5)).foregroundStyle(Theme.strong).lineLimit(1)
                Spacer(minLength: 2)
                CardSparkline(closes: closes).frame(width: 54, height: 14)
            }
            TokenLine(tokens: PickSummary.tokens(m), size: 9.5)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .clipped()
                .padding(.top, 3)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            ZStack {
                Theme.header.opacity(0.45)
                if selected { SelectionMark().matchedGeometryEffect(id: "pick-selection", in: ns) }
            }
        }
        .overlay(Rectangle().stroke(selected ? Theme.selection.opacity(0.7) : Theme.border, lineWidth: 1))
        .contentShape(Rectangle())
        // Cards arrive one after another whenever the shortlist changes.
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 10)
        .onAppear { withAnimation(Motion.stagger(rank - 1)) { appeared = true } }
    }
}

/// The menu bar quick list: always one click away, refreshed automatically.
struct PicksMenu: View {
    @Environment(ScreenerStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Top matches").font(Theme.label(14, .bold)).foregroundStyle(Theme.bright)
                    Text(store.picksContext.replacingOccurrences(of: " · ", with: ", "))
                        .font(Theme.label(12)).foregroundStyle(Theme.text)
                }
                Spacer()
                if let s = store.vixStatus {
                    VStack(alignment: .trailing, spacing: 0) {
                        Readout(text: String(format: "%.2f", s.level), size: 20)
                        Text("\(VolIndex.current.name) \(s.change.pct)").font(Theme.mono(10, .semibold)).foregroundStyle(Theme.signed(-s.change))
                    }
                }
            }
            .padding(12)
            .background(Theme.header)
            .overlay(alignment: .top) { Theme.green.frame(height: 2) }
            Theme.border.frame(height: 1)

            let picks = store.topPicks
            if picks.isEmpty {
                Text(store.isLoading ? "Loading…" : "No stock passes every check right now.")
                    .font(Theme.label(12.5)).foregroundStyle(Theme.muted)
                    .padding(12)
            }
            ForEach(Array(picks.enumerated()), id: \.element.id) { rank, m in
                PicksMenuRow(rank: rank + 1, m: m) { open(m) }
                Theme.border.opacity(0.6).frame(height: 1)
            }

            HStack(spacing: 6) {
                Group {
                    if store.isLoading {
                        Text("Fetching \(store.loadingStage?.lowercased() ?? "data") \(store.loadedCount)/\(store.totalCount)")
                    } else if let updated = store.lastUpdated {
                        Text("Updated \(updated.formatted(date: .omitted, time: .shortened))")
                    }
                }
                .font(Theme.label(11.5))
                .foregroundStyle(Theme.muted)
                Spacer()
                Button("Refresh") { Task { await store.refresh() } }.disabled(store.isLoading)
                Button("Open screener") { openMain() }
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(TermButtonStyle(compact: true))
            .padding(10)
        }
        .frame(width: 440)
        .background(Theme.panel)
        .animation(Motion.ui, value: picks(store).map(\.id))
        .task { store.startAutoRefresh() }
    }

    private func picks(_ store: ScreenerStore) -> [StockMetrics] { store.topPicks }

    private func open(_ m: StockMetrics) {
        store.selection = m.id
        openMain()
    }

    private func openMain() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct PicksMenuRow: View {
    let rank: Int
    let m: StockMetrics
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                Text("\(rank)").font(Theme.mono(11, .semibold)).foregroundStyle(Theme.muted).frame(width: 12)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(m.symbol).font(Theme.mono(12.5, .bold)).foregroundStyle(Theme.bright)
                        Text("\(m.instrument.flag) \(m.name)").font(Theme.label(12.5)).foregroundStyle(Theme.strong).lineLimit(1)
                    }
                    TokenLine(tokens: PickSummary.tokens(m), size: 10)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                        .clipped()
                }
                Spacer(minLength: 4)
                Readout(text: String(format: "%.0f", m.score.total), size: 24, color: Theme.score(m.score.total))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(hover ? Theme.header.opacity(0.7) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Three months of closes, red or green by the net move, with the last point marked.
struct CardSparkline: View {
    let closes: [Double]

    var body: some View {
        Canvas { ctx, size in
            guard closes.count > 2, let lo = closes.min(), let hi = closes.max(), hi > lo else { return }
            let color = closes.last! >= closes.first! ? Theme.green : Theme.red
            func p(_ i: Int) -> CGPoint {
                CGPoint(x: CGFloat(i) / CGFloat(closes.count - 1) * (size.width - 3) + 1.5,
                        y: size.height - 1.5 - CGFloat((closes[i] - lo) / (hi - lo)) * (size.height - 3))
            }
            var line = Path()
            line.move(to: p(0))
            for i in 1..<closes.count { line.addLine(to: p(i)) }
            ctx.stroke(line, with: .color(color.opacity(0.85)), lineWidth: 1)
            let end = p(closes.count - 1)
            ctx.fill(Path(ellipseIn: CGRect(x: end.x - 1.6, y: end.y - 1.6, width: 3.2, height: 3.2)), with: .color(color))
        }
    }
}
