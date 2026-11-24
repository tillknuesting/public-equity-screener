import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(ScreenerStore.self) private var store
    @AppStorage("mainMode") private var mode = "screener"

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 6) {
            TopBar()
            if mode == "desk" {
                TradeDesk()
                    .transition(.opacity)
            } else if mode == "chart" {
                ChartWorkspace()
                    .transition(.opacity)
            } else if mode == "share" {
                ShareStudio()
                    .transition(.opacity)
            } else {
            HStack(alignment: .top, spacing: 6) {
                EventsPanel()
                    .frame(width: 270)

                VStack(spacing: 6) {
                    RegimePanel()
                    TopPicksStrip()
                    ScreenerPanel()
                }
                .frame(minWidth: 660)

                DetailPanel()
                    .frame(width: 390)
            }
            .transition(.opacity)
            }
            FooterBar()
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
        .background(Theme.canvas.ignoresSafeArea())
        .sheet(item: $store.expandedChart) { ChartSheet(chart: $0) }
        .sheet(isPresented: $store.showBacktest) { BacktestSheet() }
        .sheet(isPresented: $store.showFactor) { FactorSheet() }
        .sheet(isPresented: $store.showRobustness) { RobustnessSheet() }
    }
}

// MARK: - Top bar

struct TopBar: View {
    @Environment(ScreenerStore.self) private var store
    @AppStorage("mainMode") private var mode = "screener"

    var body: some View {
        HStack(spacing: 14) {
            Color.clear.frame(width: 64)   // traffic lights
            Text("Public Equity Screener")
                .font(Theme.label(16, .bold))
                .foregroundStyle(Theme.bright)
                .fixedSize()
            HStack(spacing: 0) {
                Button("Screener") { withAnimation(Motion.ui) { mode = "screener" } }
                    .buttonStyle(TermButtonStyle(selected: mode == "screener"))
                    .keyboardShortcut("1")
                Button("Factor screen") { withAnimation(Motion.ui) { mode = "desk" } }
                    .buttonStyle(TermButtonStyle(selected: mode == "desk"))
                    .keyboardShortcut("2")
                Button("Chart") { withAnimation(Motion.ui) { mode = "chart" } }
                    .buttonStyle(TermButtonStyle(selected: mode == "chart"))
                    .keyboardShortcut("3")
                Button("Share") { withAnimation(Motion.ui) { mode = "share" } }
                    .buttonStyle(TermButtonStyle(selected: mode == "share"))
                    .keyboardShortcut("4")
                    .help("Make a chart card for Threads or X")
            }
            .fixedSize()
            HStack(spacing: 6) {
                Text("›").font(Theme.mono(13, .bold)).foregroundStyle(Theme.cyan)
                Text(statusLine)
                    .font(Theme.label(12.5))
                    .foregroundStyle(Theme.strong)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .contentTransition(.opacity)
                    .animation(Motion.ui, value: statusLine)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                ForEach(UniverseKind.allCases, id: \.self) { kind in
                    Button {
                        Task { await store.switchUniverse(kind) }
                    } label: {
                        if kind == store.universeKind { Label(kind.title, systemImage: "checkmark") } else { Text(kind.title) }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "globe.europe.africa").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.cyan)
                    Text(store.universeKind.shortTitle).font(Theme.label(12.5, .semibold)).foregroundStyle(Theme.bright)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.muted)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Theme.panel, in: Rectangle())
                .overlay(Rectangle().stroke(Theme.border, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Universe: MSCI World top 100, FTSE Global All Cap top 500, FTSE 100, DAX 40, STOXX Europe 600, or sector ETFs")
            Menu {
                Picker("Volatility index", selection: Bindable(store).volIndex) {
                    ForEach(VolIndex.allCases, id: \.self) { v in Text("\(v.name) · \(v.market) options").tag(v) }
                }
                .pickerStyle(.inline)
            } label: {
                TickerChip(label: store.volIndex.name, series: store.vix, invertColors: true, menu: true)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Volatility index for spikes, gauges and the stress regime: VIX (US) or VSTOXX (euro area)")
            TickerChip(label: store.universeKind.benchmarkName, series: store.benchmark)
            Button("Factor") { store.runFactor() }
                .buttonStyle(TermButtonStyle())
                .fixedSize()
                .help("Risk-budget reversal factor: how stocks hit by forced selling did afterwards, every week since 2011")
                .keyboardShortcut("k")
            Button("Backtest") { store.runBacktest() }
                .buttonStyle(TermButtonStyle())
                .fixedSize()
                .help("Replay the screen at every past \(VolIndex.current.name) spike and see what happened next")
                .keyboardShortcut("b")
            Button("Robustness") { store.runRobustness() }
                .buttonStyle(TermButtonStyle())
                .fixedSize()
                .help("Rerun the stress-gated backtest across neighbouring rule settings: is the result tuned or robust?")
                .keyboardShortcut("g")
            if store.isLoading {
                LoadingMeter(stage: store.loadingStage ?? "", done: store.loadedCount, total: store.totalCount)
            } else {
                Button("Refresh") { Task { await store.refresh() } }
                    .buttonStyle(TermButtonStyle(prominent: true))
                    .keyboardShortcut("r")
            }
            Menu {
                Button("Edit \(store.universeKind.title) List…") { NSWorkspace.shared.open(Universe.fileURL(for: store.universeKind)) }
                Button("Reload Universe") { Task { await store.reloadUniverse() } }
            } label: {
                Text("List")
            }
            .menuStyle(.button)
            .buttonStyle(TermButtonStyle())
            .fixedSize()
        }
        .padding(.horizontal, 4)
        .frame(height: 44)
        .background(Color.clear.contentShape(Rectangle()).gesture(WindowDragGesture()))
    }

    private var statusLine: String {
        if store.isLoading {
            return "Fetching \(store.loadingStage?.lowercased() ?? "data") \(store.loadedCount)/\(store.totalCount)…"
        }
        if let r = store.selectedRange {
            let hit = store.results.filter { $0.isMomentumLeader && $0.zScore <= -1.5 }.count
            return "Custom period \(TradingDay.label(r.from)) → \(TradingDay.label(r.to)): \(hit) momentum leaders sold off ≥ 1.5σ"
        }
        if let e = store.selectedEvent {
            let hit = store.results.filter { $0.isMomentumLeader && $0.zScore <= -1.5 }.count
            if e.sessionsAgo <= 10 {
                let ago = e.sessionsAgo == 0 ? "today" : e.sessionsAgo == 1 ? "1 session ago" : "\(e.sessionsAgo) sessions ago"
                return "\(VolIndex.current.name) spiked \(e.change.pct) \(ago), and \(hit) momentum leaders sold off ≥ 1.5σ"
            }
            return "Replaying the \(TradingDay.label(e.day)) spike: \(hit) momentum leaders sold off ≥ 1.5σ"
        }
        if let s = store.vixStatus {
            return s.isSpike ? "\(VolIndex.current.name) is spiking now (\(s.change.pct))" : "No \(VolIndex.current.name) spike in the last session. \(VolIndex.current.name) \(String(format: "%.1f", s.level))"
        }
        return "Press Refresh to load the market"
    }
}

struct TickerChip: View {
    let label: String
    let series: PriceSeries?
    var invertColors = false
    var menu = false

    var body: some View {
        let bars = series?.bars ?? []
        let change = bars.count > 1 ? bars[bars.count - 1].close / bars[bars.count - 2].close - 1 : nil
        HStack(spacing: 6) {
            Caption(label)
            if menu {
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.muted)
            }
            Text(bars.last.map { String(format: "%.2f", $0.close) } ?? "—")
                .font(Theme.mono(12, .bold)).foregroundStyle(Theme.bright)
            if let change {
                Text(change.pct).font(Theme.mono(11, .semibold))
                    .foregroundStyle(Theme.signed(invertColors ? -change : change))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Theme.panel, in: Rectangle())
        .overlay(Rectangle().stroke(Theme.border, lineWidth: 1))
        .fixedSize()
    }
}

struct LoadingMeter: View {
    let stage: String
    let done: Int
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Caption("\(stage) \(done)/\(total)", color: Theme.accent)
            Meter(fraction: total > 0 ? Double(done) / Double(total) : 0, color: Theme.accent)
                .frame(width: 120, height: 4)
        }
    }
}

struct FooterBar: View {
    @Environment(ScreenerStore.self) private var store

    var body: some View {
        HStack(spacing: 12) {
            if let updated = store.lastUpdated {
                Text("Updated \(updated.formatted(date: .abbreviated, time: .shortened))")
            }
            if !store.failures.isEmpty {
                Text("\(store.failures.count) failed")
                    .foregroundStyle(Theme.orange)
                    .help(store.failures.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n"))
            }
            Spacer()
            Text("Yahoo Finance data, delayed. Fundamentals are the latest figures, not point-in-time. Research tool, not investment advice.")
        }
        .font(Theme.label(11))
        .foregroundStyle(Theme.muted)
        .padding(.horizontal, 4)
    }
}
