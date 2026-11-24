import Charts
import SwiftUI

// Social-media cards: fixed sizes, a fixed palette (independent of the app's light/dark mode),
// and nothing but data. Rendered at 2× by `ShareRenderer`.

enum ShareTemplate: String, CaseIterable, Identifiable {
    case stock = "Stock chart"
    case compare = "Stock vs index"
    case vol = "Volatility"
    case matches = "Top matches"
    var id: String { rawValue }

    var needsSymbol: Bool { self == .stock || self == .compare }
}

enum ShareFormat: String, CaseIterable, Identifiable {
    case landscape = "16:9"
    case portrait = "4:5"
    case square = "1:1"
    var id: String { rawValue }

    /// Design size in points; exported at 2× (1600×900, 1080×1350, 1080×1080).
    var size: CGSize {
        switch self {
        case .landscape: CGSize(width: 800, height: 450)
        case .portrait: CGSize(width: 540, height: 675)
        case .square: CGSize(width: 540, height: 540)
        }
    }

    var hint: String {
        switch self {
        case .landscape: "X and link previews, 1600 × 900"
        case .portrait: "Threads and Instagram feed, 1080 × 1350"
        case .square: "Square posts, 1080 × 1080"
        }
    }
}

enum ShareRange: String, CaseIterable, Identifiable {
    case m1 = "1M", m3 = "3M", m6 = "6M", y1 = "1Y", y2 = "2Y", y5 = "5Y"
    var id: String { rawValue }

    var sessions: Int {
        switch self {
        case .m1: 21
        case .m3: 63
        case .m6: 126
        case .y1: 252
        case .y2: 504
        case .y5: 1260
        }
    }

    var label: String {
        switch self {
        case .m1: "1 month"
        case .m3: "3 months"
        case .m6: "6 months"
        case .y1: "1 year"
        case .y2: "2 years"
        case .y5: "5 years"
        }
    }
}

/// A card look: colours, type and shape. Bundled themes only; none copies a real brand.
enum ShareTheme: String, CaseIterable, Identifiable {
    case solarizedDark = "Solarized dark"
    case solarizedLight = "Solarized light"
    case terminal = "Terminal amber"
    case midnight = "Midnight"
    case neon = "Neon"
    case paper = "Newsprint"
    case mono = "Mono"
    var id: String { rawValue }

    var palette: SharePalette {
        switch self {
        case .solarizedDark: .dark
        case .solarizedLight: .light
        case .terminal: .terminal
        case .midnight: .midnight
        case .neon: .neon
        case .paper: .paper
        case .mono: .mono
        }
    }
}

struct SharePalette {
    let top: Color, bottom: Color
    let text: Color, strong: Color, muted: Color, grid: Color
    let line: Color, accent: Color, up: Color, down: Color, compare: Color, tile: Color
    var isDark = true
    var glow = 0.16          // strength of the soft light behind the headline
    var radius: CGFloat = 8  // tiles and pills; 0 = square terminal look
    var monospaced = false   // every label in a monospaced face
    var serifTitles = false  // newspaper-style headlines
    var upperTitles = false  // terminal-style capitals

    func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: monospaced ? size * 0.92 : size, weight: weight, design: monospaced ? .monospaced : .default)
    }

    func title(_ size: CGFloat) -> Font {
        serifTitles ? .system(size: size, weight: .bold, design: .serif) : font(size, .bold)
    }

    static let dark = SharePalette(
        top: Color(hex: 0x00313D), bottom: Color(hex: 0x00151B),
        text: Color(hex: 0xEEE8D5), strong: Color(hex: 0xA9B7B7), muted: Color(hex: 0x6A8790), grid: Color(hex: 0x0E4655),
        line: Color(hex: 0x2AA198), accent: Color(hex: 0xB58900), up: Color(hex: 0x9DB200), down: Color(hex: 0xE5484D),
        compare: Color(hex: 0x6C71C4), tile: Color.white.opacity(0.05))

    static let light = SharePalette(
        top: Color(hex: 0xFDF6E3), bottom: Color(hex: 0xEFE7CF),
        text: Color(hex: 0x073642), strong: Color(hex: 0x4F656D), muted: Color(hex: 0x8E9EA0), grid: Color(hex: 0xDCD3B8),
        line: Color(hex: 0x1E8E86), accent: Color(hex: 0xB58900), up: Color(hex: 0x6F8300), down: Color(hex: 0xD02B2B),
        compare: Color(hex: 0x5B5FB8), tile: Color.black.opacity(0.04), isDark: false, glow: 0.08)

    /// Black screen, amber type, square tiles: the classic market-terminal look.
    static let terminal = SharePalette(
        top: Color(hex: 0x050505), bottom: Color(hex: 0x000000),
        text: Color(hex: 0xFFA028), strong: Color(hex: 0xE6E6E6), muted: Color(hex: 0x9A7B4F), grid: Color(hex: 0x262626),
        line: Color(hex: 0xFFD23F), accent: Color(hex: 0xFF7A00), up: Color(hex: 0x2BD45C), down: Color(hex: 0xFF3B30),
        compare: Color(hex: 0x4FC3F7), tile: Color(hex: 0x141414), glow: 0, radius: 0, monospaced: true, upperTitles: true)

    static let midnight = SharePalette(
        top: Color(hex: 0x111833), bottom: Color(hex: 0x05070F),
        text: Color(hex: 0xF2F4FF), strong: Color(hex: 0xB8C0E0), muted: Color(hex: 0x6B7395), grid: Color(hex: 0x1F2747),
        line: Color(hex: 0x5EEAD4), accent: Color(hex: 0xFBBF24), up: Color(hex: 0x34D399), down: Color(hex: 0xF87171),
        compare: Color(hex: 0xA78BFA), tile: Color.white.opacity(0.05), glow: 0.22, radius: 12)

    static let neon = SharePalette(
        top: Color(hex: 0x241046), bottom: Color(hex: 0x0B0517),
        text: Color(hex: 0xFDF4FF), strong: Color(hex: 0xD8B4FE), muted: Color(hex: 0x8F72B8), grid: Color(hex: 0x2E1A4A),
        line: Color(hex: 0x22D3EE), accent: Color(hex: 0xF0ABFC), up: Color(hex: 0x4ADE80), down: Color(hex: 0xFB7185),
        compare: Color(hex: 0xF472B6), tile: Color.white.opacity(0.06), glow: 0.3, radius: 14)

    /// Salmon newsprint with serif headlines.
    static let paper = SharePalette(
        top: Color(hex: 0xFFF1E5), bottom: Color(hex: 0xF6E2D1),
        text: Color(hex: 0x1A1A1A), strong: Color(hex: 0x4D4845), muted: Color(hex: 0x8A7F76), grid: Color(hex: 0xE8D6C6),
        line: Color(hex: 0x0F5499), accent: Color(hex: 0x990F3D), up: Color(hex: 0x0A7B50), down: Color(hex: 0xC2203C),
        compare: Color(hex: 0xE3963E), tile: Color.black.opacity(0.04), isDark: false, glow: 0, radius: 2, serifTitles: true)

    static let mono = SharePalette(
        top: Color(hex: 0xFFFFFF), bottom: Color(hex: 0xF3F3F3),
        text: Color(hex: 0x111111), strong: Color(hex: 0x444444), muted: Color(hex: 0x9A9A9A), grid: Color(hex: 0xE5E5E5),
        line: Color(hex: 0x111111), accent: Color(hex: 0x2563EB), up: Color(hex: 0x16A34A), down: Color(hex: 0xDC2626),
        compare: Color(hex: 0xA3A3A3), tile: Color.black.opacity(0.035), isDark: false, glow: 0, radius: 6)
}

struct ShareSettings {
    var template: ShareTemplate = .stock
    var format: ShareFormat = .landscape
    var range: ShareRange = .y1
    var theme: ShareTheme = .solarizedDark
    var symbol = ""
    var title = ""
    var subtitle = ""
    var caption = ""
    var averages = true
    var spikes = true
    var branding = true
}

// MARK: - Card

struct ShareCard: View {
    let store: ScreenerStore
    let settings: ShareSettings

    private var p: SharePalette { settings.theme.palette }
    private var size: CGSize { settings.format.size }
    private var compact: Bool { settings.format != .landscape }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 14 : 12) {
            switch settings.template {
            case .stock: StockCardBody(store: store, settings: settings, p: p)
            case .compare: CompareCardBody(store: store, settings: settings, p: p)
            case .vol: VolCardBody(store: store, settings: settings, p: p)
            case .matches: MatchesCardBody(store: store, settings: settings, p: p)
            }
            if !settings.caption.isEmpty {
                Text(settings.caption)
                    .font(p.font(compact ? 15 : 14, .medium))
                    .foregroundStyle(p.strong)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(3)
            }
            if settings.branding { footer }
        }
        .padding(compact ? 30 : 32)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background {
            ZStack {
                LinearGradient(colors: [p.top, p.bottom], startPoint: .top, endPoint: .bottom)
                // A soft glow behind the headline keeps the dark card from looking flat.
                RadialGradient(colors: [p.line.opacity(p.glow), .clear],
                               center: .topTrailing, startRadius: 10, endRadius: size.width * 0.8)
            }
        }
        .environment(\.colorScheme, p.isDark ? .dark : .light)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("Public Equity Screener").font(p.font(12.5, .semibold)).foregroundStyle(p.text)
            Spacer(minLength: 8)
            Text("Yahoo Finance data, delayed · \(Date().formatted(.dateTime.day().month(.abbreviated).year())) · Not investment advice")
                .font(p.font(10.5)).foregroundStyle(p.muted)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(.top, 2)
    }
}

// MARK: - Shared pieces

private struct CardHeader: View {
    let title: String
    let subtitle: String
    let value: String?
    let change: Double?
    let changeLabel: String
    let p: SharePalette
    let compact: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(p.upperTitles ? title.uppercased() : title)
                    .font(p.title(compact ? 30 : 32))
                    .foregroundStyle(p.text)
                    .lineLimit(2).minimumScaleFactor(0.6)
                Text(subtitle)
                    .font(p.font(14, .medium))
                    .foregroundStyle(p.muted)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                if let value {
                    Text(value).font(p.font(compact ? 30 : 34, .semibold).width(.compressed).monospacedDigit())
                        .foregroundStyle(p.text)
                }
                if let change { ChangePill(change: change, label: changeLabel, p: p) }
            }
            .fixedSize()
        }
    }
}

private struct ChangePill: View {
    let change: Double
    let label: String
    let p: SharePalette

    var body: some View {
        let color = change >= 0 ? p.up : p.down
        HStack(spacing: 5) {
            Image(systemName: change >= 0 ? "arrow.up.right" : "arrow.down.right").font(p.font(11, .bold))
            Text(change.pct).font(p.font(15, .bold).monospacedDigit())
            Text(label).font(p.font(12, .medium)).opacity(0.8)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: p.radius == 0 ? 0 : 99))
    }
}

private struct StatTile: View {
    let label: String
    let value: String
    var color: Color?
    let p: SharePalette

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(p.font(9.5, .semibold)).tracking(0.6).foregroundStyle(p.muted)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(value).font(p.font(19, .semibold).width(.compressed).monospacedDigit())
                .foregroundStyle(color ?? p.text).lineLimit(1).minimumScaleFactor(0.6)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.tile, in: RoundedRectangle(cornerRadius: p.radius))
    }
}

private func dateFormat(_ range: ShareRange) -> Date.FormatStyle {
    range.sessions > 600 ? .dateTime.year() : range.sessions > 300 ? .dateTime.month(.abbreviated).year(.twoDigits) : .dateTime.month(.abbreviated)
}

private func axisLabel(_ v: Double) -> String {
    abs(v) >= 1000 ? String(format: "%.0f", v) : abs(v) >= 100 ? String(format: "%.0f", v) : String(format: "%.1f", v)
}

/// Bars of `symbol` over the range, plus everything before it (for moving averages).
@MainActor private func window(_ store: ScreenerStore, _ symbol: String, _ range: ShareRange) -> (all: [Bar], shown: ArraySlice<Bar>)? {
    guard let bars = store.series[symbol]?.bars, bars.count > 5 else { return nil }
    return (bars, bars.suffix(range.sessions + 1))   // +1: the change is measured from the close before
}

private func change(_ bars: [Bar], back sessions: Int) -> Double? {
    guard bars.count > sessions else { return nil }
    return bars[bars.count - 1].close / bars[bars.count - 1 - sessions].close - 1
}

private struct MissingData: View {
    let text: String
    let p: SharePalette
    var body: some View {
        Text(text).font(p.font(16, .medium)).foregroundStyle(p.muted)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Stock chart

private struct StockCardBody: View {
    let store: ScreenerStore
    let settings: ShareSettings
    let p: SharePalette

    var body: some View {
        let symbol = settings.symbol
        let inst = store.universe.first { $0.symbol == symbol }
        let compact = settings.format != .landscape
        if let (all, shown) = window(store, symbol, settings.range), let first = shown.first, let last = shown.last {
            let rangeChange = last.close / first.close - 1
            let currency = store.series[symbol]?.currency ?? ""
            CardHeader(title: settings.title.isEmpty ? (inst.map { "\($0.flag) \($0.name)" } ?? symbol) : settings.title,
                       subtitle: settings.subtitle.isEmpty ? "\(symbol) · \(inst?.sector ?? "") · \(settings.range.label)" : settings.subtitle,
                       value: String(format: last.close >= 1000 ? "%.0f" : "%.2f", last.close) + " " + currency,
                       change: rangeChange, changeLabel: settings.range.rawValue, p: p, compact: compact)
            let high = all.suffix(252).map(\.close).max() ?? last.close
            let tiles: [(String, String, Color?)] = [
                ("1 day", change(all, back: 1)?.pct ?? "—", change(all, back: 1).map { $0 >= 0 ? p.up : p.down }),
                ("1 month", change(all, back: 21)?.pct ?? "—", change(all, back: 21).map { $0 >= 0 ? p.up : p.down }),
                ("1 year", change(all, back: 252)?.pct ?? "—", change(all, back: 252).map { $0 >= 0 ? p.up : p.down }),
                ("From 52w high", (last.close / high - 1).pct, nil),
            ]
            if compact {
                Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                    GridRow { tile(tiles[0]); tile(tiles[1]) }
                    GridRow { tile(tiles[2]); tile(tiles[3]) }
                }
            } else {
                HStack(spacing: 8) { ForEach(tiles.indices, id: \.self) { tile(tiles[$0]) } }
            }
            SharePriceChart(all: all, shown: shown, range: settings.range, averages: settings.averages,
                       spikes: settings.spikes ? Set(store.events.map(\.day)) : [], p: p)
        } else {
            MissingData(text: symbol.isEmpty ? "Pick a stock" : "No prices for \(symbol)", p: p)
        }
    }

    private func tile(_ t: (String, String, Color?)) -> some View { StatTile(label: t.0, value: t.1, color: t.2, p: p) }
}

private struct SharePriceChart: View {
    let all: [Bar]
    let shown: ArraySlice<Bar>
    let range: ShareRange
    let averages: Bool
    let spikes: Set<Int>
    let p: SharePalette

    private struct Point: Identifiable { let date: Date; let value: Double; var id: Date { date } }

    var body: some View {
        let closes = all.map(\.close)
        let offset = all.count - shown.count
        let points = shown.map { Point(date: $0.date, value: $0.close) }
        func sma(_ n: Int) -> [Point] {
            shown.indices.compactMap { i in
                guard i + 1 >= n else { return nil }
                let v = closes[(i + 1 - n)...i].reduce(0, +) / Double(n)
                return Point(date: all[i].date, value: v)
            }
        }
        let sma50 = averages ? sma(50) : [], sma200 = averages ? sma(200) : []
        let values = points.map(\.value) + sma50.map(\.value) + sma200.map(\.value)
        let lo = values.min() ?? 0, hi = values.max() ?? 1
        let pad = (hi - lo) * 0.08
        let spikeBars = shown.filter { spikes.contains($0.day) }
        _ = offset

        return Chart {
            ForEach(points) { pt in
                AreaMark(x: .value("Date", pt.date), yStart: .value("Low", lo - pad), yEnd: .value("Close", pt.value))
                    .foregroundStyle(LinearGradient(colors: [p.line.opacity(0.32), p.line.opacity(0.0)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
            }
            ForEach(spikeBars, id: \.day) { b in
                RuleMark(x: .value("Spike", b.date))
                    .foregroundStyle(p.down.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            ForEach(sma200) { pt in
                LineMark(x: .value("Date", pt.date), y: .value("200D", pt.value), series: .value("Series", "200D"))
                    .foregroundStyle(p.compare.opacity(0.9)).lineStyle(StrokeStyle(lineWidth: 1.4))
            }
            ForEach(sma50) { pt in
                LineMark(x: .value("Date", pt.date), y: .value("50D", pt.value), series: .value("Series", "50D"))
                    .foregroundStyle(p.accent.opacity(0.9)).lineStyle(StrokeStyle(lineWidth: 1.4))
            }
            ForEach(points) { pt in
                LineMark(x: .value("Date", pt.date), y: .value("Close", pt.value), series: .value("Series", "Price"))
                    .foregroundStyle(p.line).lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            if let last = points.last {
                PointMark(x: .value("Date", last.date), y: .value("Close", last.value))
                    .symbolSize(70).foregroundStyle(p.line)
            }
        }
        .chartYScale(domain: (lo - pad)...(hi + pad))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                AxisValueLabel(format: dateFormat(range)).foregroundStyle(p.muted).font(p.font(11))
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { v in
                AxisGridLine().foregroundStyle(p.grid)
                AxisValueLabel { if let d = v.as(Double.self) { Text(axisLabel(d)) } }
                    .foregroundStyle(p.muted).font(p.font(11).monospacedDigit())
            }
        }
        .overlay(alignment: .topLeading) {
            if averages || !spikeBars.isEmpty {
                HStack(spacing: 12) {
                    legend("Price", p.line)
                    if averages { legend("50-day", p.accent); legend("200-day", p.compare) }
                    if !spikeBars.isEmpty { legend("\(VolIndex.current.name) spike", p.down) }
                }
                .padding(.leading, 2)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func legend(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Capsule().fill(color).frame(width: 12, height: 3)
            Text(text).font(p.font(10.5, .medium)).foregroundStyle(p.muted)
        }
    }
}

// MARK: - Stock vs index

private struct CompareCardBody: View {
    let store: ScreenerStore
    let settings: ShareSettings
    let p: SharePalette

    private struct Point: Identifiable { let date: Date; let value: Double; let series: String; var id: String { series + "\(date)" } }

    var body: some View {
        let symbol = settings.symbol
        let inst = store.universe.first { $0.symbol == symbol }
        let benchName = store.universeKind.benchmarkName
        let compact = settings.format != .landscape
        if let (_, shown) = window(store, symbol, settings.range), let bench = store.benchmark?.bars, let first = shown.first {
            let byDay = Dictionary(bench.map { ($0.day, $0.close) }, uniquingKeysWith: { a, _ in a })
            let base = shown.first { byDay[$0.day] != nil }
            let benchBase = base.flatMap { byDay[$0.day] } ?? 1
            let stock = shown.map { Point(date: $0.date, value: $0.close / first.close * 100, series: inst?.name ?? symbol) }
            let index = shown.compactMap { b in byDay[b.day].map { Point(date: b.date, value: $0 / benchBase * 100, series: benchName) } }
            let stockChange = (stock.last?.value ?? 100) / 100 - 1
            let indexChange = (index.last?.value ?? 100) / 100 - 1
            CardHeader(title: settings.title.isEmpty ? "\(inst.map { "\($0.flag) \($0.name)" } ?? symbol) vs \(benchName)" : settings.title,
                       subtitle: settings.subtitle.isEmpty ? "Both rebased to 100 · \(settings.range.label)" : settings.subtitle,
                       value: nil, change: stockChange - indexChange, changeLabel: "vs index", p: p, compact: compact)
            HStack(spacing: 8) {
                StatTile(label: inst?.name ?? symbol, value: stockChange.pct, color: stockChange >= 0 ? p.up : p.down, p: p)
                StatTile(label: benchName, value: indexChange.pct, color: indexChange >= 0 ? p.up : p.down, p: p)
                StatTile(label: "Difference", value: (stockChange - indexChange).pct, p: p)
            }
            let values = (stock + index).map(\.value)
            let lo = values.min() ?? 90, hi = values.max() ?? 110, pad = (hi - lo) * 0.08
            Chart {
                RuleMark(y: .value("Base", 100)).foregroundStyle(p.muted.opacity(0.5)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
                ForEach(index) { pt in
                    LineMark(x: .value("Date", pt.date), y: .value("Value", pt.value), series: .value("Series", pt.series))
                        .foregroundStyle(p.compare).lineStyle(StrokeStyle(lineWidth: 1.8))
                }
                ForEach(stock) { pt in
                    LineMark(x: .value("Date", pt.date), y: .value("Value", pt.value), series: .value("Series", pt.series))
                        .foregroundStyle(p.line).lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round))
                        .interpolationMethod(.monotone)
                }
            }
            .chartYScale(domain: (lo - pad)...(hi + pad))
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                    AxisValueLabel(format: dateFormat(settings.range)).foregroundStyle(p.muted).font(p.font(11))
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { v in
                    AxisGridLine().foregroundStyle(p.grid)
                    AxisValueLabel { if let d = v.as(Double.self) { Text(String(format: "%.0f", d)) } }
                        .foregroundStyle(p.muted).font(p.font(11).monospacedDigit())
                }
            }
            .overlay(alignment: .topLeading) {
                HStack(spacing: 12) {
                    legendItem(inst?.name ?? symbol, p.line)
                    legendItem(benchName, p.compare)
                }
            }
            .frame(maxHeight: .infinity)
        } else {
            MissingData(text: symbol.isEmpty ? "Pick a stock" : "No prices for \(symbol)", p: p)
        }
    }

    private func legendItem(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Capsule().fill(color).frame(width: 12, height: 3)
            Text(text).font(p.font(10.5, .medium)).foregroundStyle(p.muted)
        }
    }
}

// MARK: - Volatility

private struct VolCardBody: View {
    let store: ScreenerStore
    let settings: ShareSettings
    let p: SharePalette

    var body: some View {
        let vol = VolIndex.current
        let compact = settings.format != .landscape
        if let bars = store.vix?.bars, let last = bars.last, bars.count > 30 {
            let shown = bars.suffix(settings.range.sessions + 1)
            let yearCloses = bars.suffix(252).map(\.close).sorted()
            let median = yearCloses[yearCloses.count / 2]
            let peak = shown.max { $0.close < $1.close }
            let eventDays = Set(store.events.map(\.day))
            let spikesShown = shown.filter { eventDays.contains($0.day) }
            let calm = last.close < median
            CardHeader(title: settings.title.isEmpty ? "\(vol.name): \(calm ? "calm" : last.close > median * 1.5 ? "stressed" : "elevated")" : settings.title,
                       subtitle: settings.subtitle.isEmpty ? "\(vol.market) implied volatility · \(settings.range.label)" : settings.subtitle,
                       value: String(format: "%.2f", last.close), change: change(bars, back: 1), changeLabel: "1D", p: p, compact: compact)
            HStack(spacing: 8) {
                StatTile(label: "1-year median", value: String(format: "%.1f", median), p: p)
                StatTile(label: "Peak, \(settings.range.rawValue)", value: peak.map { String(format: "%.1f", $0.close) } ?? "—", color: p.down, p: p)
                StatTile(label: "Spike events, \(settings.range.rawValue)", value: "\(spikesShown.count)", p: p)
                if !compact, let term = store.termByDay[last.day] {
                    StatTile(label: "÷ \(vol.threeMonthName)", value: String(format: "%.2f", term), color: term > 1 ? p.down : nil, p: p)
                }
            }
            let lo = shown.map(\.close).min() ?? 0, hi = shown.map(\.close).max() ?? 1
            Chart {
                RuleMark(y: .value("Median", median))
                    .foregroundStyle(p.muted.opacity(0.6)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
                ForEach(shown, id: \.day) { b in
                    AreaMark(x: .value("Date", b.date), yStart: .value("Low", lo * 0.9), yEnd: .value("Level", b.close))
                        .foregroundStyle(LinearGradient(colors: [p.accent.opacity(0.35), p.accent.opacity(0)], startPoint: .top, endPoint: .bottom))
                }
                ForEach(shown, id: \.day) { b in
                    LineMark(x: .value("Date", b.date), y: .value("Level", b.close))
                        .foregroundStyle(p.accent).lineStyle(StrokeStyle(lineWidth: 1.8, lineJoin: .round))
                }
                if settings.spikes {
                    ForEach(spikesShown, id: \.day) { b in
                        PointMark(x: .value("Date", b.date), y: .value("Level", b.close))
                            .symbolSize(compact ? 34 : 40).foregroundStyle(p.down)
                    }
                }
            }
            .chartYScale(domain: (lo * 0.9)...(hi * 1.12))
            .overlay(alignment: .topLeading) {
                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Capsule().fill(p.accent).frame(width: 12, height: 3)
                        Text(vol.name).font(p.font(10.5, .medium)).foregroundStyle(p.muted)
                    }
                    HStack(spacing: 4) {
                        Rectangle().stroke(p.muted, style: StrokeStyle(lineWidth: 1, dash: [3, 2])).frame(width: 12, height: 0.5)
                        Text("1-year median").font(p.font(10.5, .medium)).foregroundStyle(p.muted)
                    }
                    if settings.spikes {
                        HStack(spacing: 4) {
                            Circle().fill(p.down).frame(width: 6, height: 6)
                            Text("spike event").font(p.font(10.5, .medium)).foregroundStyle(p.muted)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                    AxisValueLabel(format: dateFormat(settings.range)).foregroundStyle(p.muted).font(p.font(11))
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { v in
                    AxisGridLine().foregroundStyle(p.grid)
                    AxisValueLabel { if let d = v.as(Double.self) { Text(String(format: "%.0f", d)) } }
                        .foregroundStyle(p.muted).font(p.font(11).monospacedDigit())
                }
            }
            .frame(maxHeight: .infinity)
        } else {
            MissingData(text: "No \(vol.name) data yet", p: p)
        }
    }
}

// MARK: - Top matches

private struct MatchesCardBody: View {
    let store: ScreenerStore
    let settings: ShareSettings
    let p: SharePalette

    var body: some View {
        let compact = settings.format != .landscape
        let matches = Array(store.topPicks.prefix(compact ? 6 : 5))
        CardHeader(title: settings.title.isEmpty ? "Sold into the spike, strong before it" : settings.title,
                   subtitle: settings.subtitle.isEmpty ? "Top screen matches · \(store.picksContext)" : settings.subtitle,
                   value: nil, change: nil, changeLabel: "", p: p, compact: compact)
        if matches.isEmpty {
            MissingData(text: "No stock passes every screen right now", p: p)
        } else {
            VStack(spacing: compact ? 8 : 7) {
                HStack(spacing: 10) {
                    Text("").frame(width: 18)
                    head("Company", align: .leading).frame(maxWidth: .infinity, alignment: .leading)
                    head("3 months").frame(width: compact ? 70 : 96)
                    head("Drop").frame(width: 56)
                    head("Z-score").frame(width: 56)
                    if !compact { head("Momentum").frame(width: 70) }
                    head("Score").frame(width: compact ? 70 : 96)
                }
                ForEach(Array(matches.enumerated()), id: \.element.id) { i, m in
                    row(i + 1, m, compact: compact)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            Text("Screen: drop ≥ 1σ, momentum leader, no company news or earnings, positive free cash flow.")
                .font(p.font(11)).foregroundStyle(p.muted).lineLimit(2)
        }
    }

    private func head(_ text: String, align: Alignment = .trailing) -> some View {
        Text(text.uppercased()).font(p.font(9.5, .semibold)).tracking(0.6).foregroundStyle(p.muted)
            .frame(maxWidth: .infinity, alignment: align)
    }

    private func row(_ rank: Int, _ m: StockMetrics, compact: Bool) -> some View {
        let closes = store.series[m.id].map { Array($0.closes.suffix(63)) } ?? []
        return HStack(spacing: 10) {
            Text("\(rank)").font(p.font(13, .bold).monospacedDigit()).foregroundStyle(p.muted).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(m.instrument.flag) \(m.name)").font(p.font(compact ? 15 : 15.5, .semibold)).foregroundStyle(p.text).lineLimit(1)
                Text(m.symbol).font(p.font(11, .medium).monospaced()).foregroundStyle(p.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            MiniLine(closes: closes, p: p).frame(width: compact ? 70 : 96, height: 26)
            Text(m.windowReturn.pct).font(p.font(14, .semibold).monospacedDigit())
                .foregroundStyle(m.windowReturn >= 0 ? p.up : p.down).frame(width: 56, alignment: .trailing)
            Text(String(format: "%.1f", m.zScore)).font(p.font(14, .medium).monospacedDigit())
                .foregroundStyle(p.strong).frame(width: 56, alignment: .trailing)
            if !compact {
                Text(m.momentum12_1?.pct ?? "—").font(p.font(14, .medium).monospacedDigit())
                    .foregroundStyle(p.accent).frame(width: 70, alignment: .trailing)
            }
            HStack(spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(p.grid)
                        Capsule().fill(LinearGradient(colors: [p.line, p.up], startPoint: .leading, endPoint: .trailing))
                            .frame(width: geo.size.width * min(m.score.total / 100, 1))
                    }
                }
                .frame(height: 5)
                Text(String(format: "%.0f", m.score.total)).font(p.font(15, .bold).monospacedDigit())
                    .foregroundStyle(p.text).frame(width: 24, alignment: .trailing)
            }
            .frame(width: compact ? 70 : 96)
        }
        .padding(.horizontal, 10).padding(.vertical, settings.format == .portrait ? 11 : compact ? 7 : 6)
        .background(p.tile, in: RoundedRectangle(cornerRadius: p.radius))
    }
}

private struct MiniLine: View {
    let closes: [Double]
    let p: SharePalette

    var body: some View {
        Canvas { ctx, size in
            guard closes.count > 2, let lo = closes.min(), let hi = closes.max(), hi > lo else { return }
            let color = closes.last! >= closes.first! ? p.up : p.down
            func pt(_ i: Int) -> CGPoint {
                CGPoint(x: CGFloat(i) / CGFloat(closes.count - 1) * (size.width - 4) + 2,
                        y: size.height - 2 - CGFloat((closes[i] - lo) / (hi - lo)) * (size.height - 4))
            }
            var line = Path()
            line.move(to: pt(0))
            for i in 1..<closes.count { line.addLine(to: pt(i)) }
            ctx.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            let end = pt(closes.count - 1)
            ctx.fill(Path(ellipseIn: CGRect(x: end.x - 2.2, y: end.y - 2.2, width: 4.4, height: 4.4)), with: .color(color))
        }
    }
}

// MARK: - Rendering

@MainActor
enum ShareRenderer {
    /// The card as PNG data at 2× its design size.
    static func png(store: ScreenerStore, settings: ShareSettings) -> Data? {
        let renderer = ImageRenderer(content: ShareCard(store: store, settings: settings))
        renderer.scale = 2
        guard let image = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    static func fileName(_ s: ShareSettings) -> String {
        let subject = s.template.needsSymbol ? s.symbol : s.template == .vol ? VolIndex.current.name : "top-matches"
        let day = TradingDay.day(from: Date())
        return "\(subject)-\(s.template.needsSymbol || s.template == .vol ? s.range.rawValue + "-" : "")\(s.format == .landscape ? "16x9" : s.format == .portrait ? "4x5" : "1x1")-\(day).png"
    }
}
