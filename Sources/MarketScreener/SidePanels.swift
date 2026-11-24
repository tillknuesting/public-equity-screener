import AppKit
import SwiftUI

struct EventsPanel: View {
    @Environment(ScreenerStore.self) private var store
    @State private var showRule = false
    @Namespace private var ns

    var body: some View {
        Panel("\(VolIndex.current.name) spikes", marker: Theme.orange) {
            Button("Spike rule") { showRule.toggle() }
                .buttonStyle(TermButtonStyle())
                .popover(isPresented: $showRule, arrowEdge: .bottom) { SpikeRuleEditor() }
        } content: {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if let r = store.selectedRange {
                        EventRow(title: "Custom period",
                                 detail: "\(TradingDay.label(r.from)) → \(TradingDay.label(r.to))",
                                 tag: ("\(store.rangeSessions)d", Theme.cyan),
                                 selected: true, ns: ns) {}
                    }
                    if let s = store.vixStatus {
                        EventRow(title: "Last session",
                                 detail: String(format: "\(VolIndex.current.name) %.2f   %@", s.level, s.change.pct),
                                 tag: s.isSpike ? ("spike", Theme.red) : nil,
                                 selected: store.anchor == .latest, ns: ns) { store.pickAnchor(.latest) }
                    }
                    HStack {
                        Caption("Spike events")
                        Spacer()
                        Text("\(store.events.count)").font(Theme.mono(10)).foregroundStyle(Theme.muted)
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
                    .padding(.bottom, 4)

                    if store.events.isEmpty {
                        Text(store.vix == nil ? "Loading \(VolIndex.current.name)…" : "No spikes match the rule.")
                            .font(Theme.mono(11)).foregroundStyle(Theme.muted)
                            .padding(10)
                    }
                    ForEach(store.events) { e in
                        EventRow(title: TradingDay.label(e.day),
                                 detail: String(format: "\(VolIndex.current.name) %.1f   %@   peak %.1f", e.close, e.change.pct, e.peak),
                                 tag: e.sessionsAgo <= 10 ? ("recent", Theme.orange)
                                     : (store.termPeakByEvent[e.day] ?? 0) > 1 ? ("inverted", Theme.magenta) : nil,
                                 trailing: e.sessionsAgo <= 10 ? nil : ago(e.sessionsAgo),
                                 magnitude: e.change / max(store.events.map(\.change).max() ?? 1, 0.01),
                                 selected: store.anchorDay == e.day, ns: ns) { store.pickAnchor(.event(e.day)) }
                    }
                }
            }
        }
    }

    private func ago(_ sessions: Int) -> String {
        sessions < 22 ? "\(sessions)d" : sessions < 252 ? "\(sessions / 21)mo" : String(format: "%.1fy", Double(sessions) / 252)
    }
}

struct EventRow: View {
    let title: String
    let detail: String
    var tag: (String, Color)?
    var trailing: String?
    /// Relative jump size (0…1): drawn as a thin bar so the big spikes stand out in the list.
    var magnitude: Double?
    let selected: Bool
    var ns: Namespace.ID?
    let action: () -> Void

    var body: some View {
        Button { withAnimation(Motion.ui) { action() } } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(Theme.label(13, .semibold)).foregroundStyle(selected ? Theme.bright : Theme.strong)
                    Spacer(minLength: 4)
                    if let tag { Tag(text: tag.0, color: tag.1) }
                    if let trailing { Text(trailing).font(Theme.label(11.5)).foregroundStyle(Theme.muted) }
                }
                Text(detail).font(Theme.mono(10.5)).foregroundStyle(Theme.text).lineLimit(1)
                if let magnitude {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.border.opacity(0.5))
                            Capsule()
                                .fill(LinearGradient(colors: [Theme.orange.opacity(0.7), Theme.red], startPoint: .leading, endPoint: .trailing))
                                .frame(width: max(geo.size.width * min(max(magnitude, 0), 1), 3))
                        }
                    }
                    .frame(height: 2.5)
                    .padding(.top, 3)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background {
                if selected, let ns {
                    SelectionMark().matchedGeometryEffect(id: "event-selection", in: ns)
                } else if selected {
                    SelectionMark()
                }
            }
            .overlay(alignment: .bottom) { Theme.border.opacity(0.6).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct SpikeRuleEditor: View {
    @Environment(ScreenerStore.self) private var store

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 12) {
            Caption("Spike rule", color: Theme.accent)
            Text("A session counts as a spike when \(VolIndex.current.name) jumps at least this much versus the prior close and ends up above the minimum level.")
                .font(Theme.label(12)).foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            labeled("1-day jump ≥ \(Int(store.spikeSettings.threshold * 100))%") {
                Slider(value: $store.spikeSettings.threshold, in: 0.05...0.50, step: 0.01)
            }
            labeled("\(VolIndex.current.name) level ≥ \(Int(store.spikeSettings.minLevel))") {
                Slider(value: $store.spikeSettings.minLevel, in: 10...35, step: 1)
            }
            Toggle("Count intraday highs", isOn: $store.spikeSettings.useIntradayHigh)
                .toggleStyle(CheckToggleStyle())
        }
        .tint(Theme.accent)
        .padding(14)
        .frame(width: 300)
        .background(Theme.panel)
    }

    private func labeled<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(Theme.label(12, .semibold)).foregroundStyle(Theme.strong)
            content()
        }
    }
}

struct NewsRow: View {
    let item: NewsItem
    var highlightCatalyst = false
    var inWindow = false
    @State private var hover = false

    var body: some View {
        Button {
            if let url = URL(string: item.link) { NSWorkspace.shared.open(url) }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(Self.age(item.date)).font(Theme.mono(10, .bold)).foregroundStyle(Theme.accent)
                    Text(item.source).font(Theme.label(11)).foregroundStyle(Theme.muted).lineLimit(1)
                    Spacer(minLength: 0)
                    if inWindow { Tag(text: "in drop", color: Theme.blue) }
                    if highlightCatalyst && item.isCatalyst { Tag(text: "catalyst", color: Theme.magenta) }
                }
                Text(item.title)
                    .font(Theme.label(12.5))
                    .foregroundStyle(hover ? Theme.cyan : Theme.bright)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hover ? Theme.header.opacity(0.6) : .clear)
            .overlay(alignment: .bottom) { Theme.border.opacity(0.6).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(item.summary ?? item.title)
    }

    static func age(_ date: Date) -> String {
        let minutes = Int(Date().timeIntervalSince(date) / 60)
        switch minutes {
        case ..<60: return "\(max(minutes, 0))m"
        case ..<1440: return "\(minutes / 60)h"
        default: return "\(minutes / 1440)d"
        }
    }
}

/// The highlight behind the selected row; slides between rows via matchedGeometryEffect.
struct SelectionMark: View {
    var body: some View {
        Theme.selection.opacity(0.17)
            .overlay(alignment: .leading) { Theme.selection.frame(width: 2) }
    }
}
