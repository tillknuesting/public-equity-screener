import Foundation
import Observation
import SwiftUI

// MARK: - Settings

enum Timeframe: String, CaseIterable, Identifiable {
    case day = "1D", week = "1W", month = "1M"
    var id: String { rawValue }

    var barsPerMonth: Double {
        switch self {
        case .day: 21
        case .week: 4.35
        case .month: 1
        }
    }

    var defaultBars: Int {
        switch self {
        case .day: 160
        case .week: 156
        case .month: 132
        }
    }
}

enum ChartStyle: String, CaseIterable, Identifiable {
    case candles = "Candles", hollow = "Hollow candles", heikinAshi = "Heikin Ashi", ohlc = "Bars", line = "Line", area = "Area"
    var id: String { rawValue }
}

enum Indicator: String, CaseIterable, Identifiable {
    case sma20, sma50, sma200, ema21, bollinger, volume, spikes, compare, rsi, macd, volShock, vix
    var id: String { rawValue }

    var title: String {
        switch self {
        case .sma20: "SMA 20"
        case .sma50: "SMA 50"
        case .sma200: "SMA 200"
        case .ema21: "EMA 21"
        case .bollinger: "Bollinger Bands (20, 2)"
        case .volume: "Volume"
        case .spikes: "\(VolIndex.current.name) spike markers"
        case .compare: "Compare with index"
        case .rsi: "RSI (14)"
        case .macd: "MACD (12, 26, 9)"
        case .volShock: "Vol shock (10 ÷ 60)"
        case .vix: "\(VolIndex.current.name)"
        }
    }

    /// Indicators drawn in their own pane under the price.
    var isPane: Bool { [.rsi, .macd, .volShock, .vix].contains(self) }

    var color: Color {
        switch self {
        case .sma20: Theme.yellow
        case .sma50: Theme.orange
        case .sma200: Theme.violet
        case .ema21: Theme.cyan
        case .bollinger: Theme.blue
        case .compare: Theme.magenta
        case .rsi: Theme.violet
        case .macd: Theme.blue
        case .volShock: Theme.cyan
        case .vix: Theme.orange
        case .volume, .spikes: Theme.muted
        }
    }
}

enum DrawingTool: String, CaseIterable, Identifiable {
    case cursor, trend, ray, horizontal, fib, rectangle, measure
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .cursor: "cursorarrow"
        case .trend: "line.diagonal"
        case .ray: "arrow.up.right"
        case .horizontal: "minus"
        case .fib: "line.3.horizontal.decrease"
        case .rectangle: "rectangle"
        case .measure: "ruler"
        }
    }

    var title: String {
        switch self {
        case .cursor: "Cursor (drag to pan)"
        case .trend: "Trend line"
        case .ray: "Ray"
        case .horizontal: "Horizontal line"
        case .fib: "Fibonacci retracement"
        case .rectangle: "Rectangle"
        case .measure: "Measure (or hold ⇧ and drag)"
        }
    }

    var drawingKind: ChartDrawing.Kind? {
        switch self {
        case .trend: .trend
        case .ray: .ray
        case .horizontal: .horizontal
        case .fib: .fib
        case .rectangle: .rectangle
        case .cursor, .measure: nil
        }
    }
}

// MARK: - Data

struct ChartBar {
    let day: Int        // last trading day in the bar
    let firstDay: Int   // first trading day in the bar
    let open, high, low, close, volume: Double
    var date: Date { TradingDay.date(day) }
}

struct ChartAnchor: Codable, Equatable {
    var day: Int
    var price: Double
}

struct ChartDrawing: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case trend, ray, horizontal, fib, rectangle }
    var id = UUID()
    var kind: Kind
    var a: ChartAnchor
    var b: ChartAnchor
}

struct MeasureSpan: Equatable {
    var a: ChartAnchor
    var b: ChartAnchor
}

/// Everything derived from the bars, aligned index for index.
struct ChartData {
    var bars: [ChartBar] = []
    var heikinAshi: [ChartBar] = []
    var sma20: [Double?] = [], sma50: [Double?] = [], sma200: [Double?] = [], ema21: [Double?] = []
    var bbMid: [Double?] = [], bbUpper: [Double?] = [], bbLower: [Double?] = []
    var rsi: [Double?] = []
    var macd: [Double?] = [], macdSignal: [Double?] = [], macdHist: [Double?] = []
    var volShock: [Double?] = []
    var vix: [Double?] = []
    var compare: [Double?] = []      // benchmark close on the same bar
    var spike: [Bool] = []

    func overlay(_ i: Indicator) -> [Double?]? {
        switch i {
        case .sma20: sma20
        case .sma50: sma50
        case .sma200: sma200
        case .ema21: ema21
        default: nil
        }
    }
}

enum ChartMath {
    static func aggregate(_ bars: [Bar], _ tf: Timeframe) -> [ChartBar] {
        guard tf != .day else {
            return bars.map { ChartBar(day: $0.day, firstDay: $0.day, open: $0.open, high: $0.high, low: $0.low, close: $0.close, volume: $0.volume) }
        }
        let cal = Calendar(identifier: .iso8601)
        func key(_ b: Bar) -> Int {
            if tf == .month { return b.day / 100 }
            let c = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: b.date)
            return (c.yearForWeekOfYear ?? 0) * 100 + (c.weekOfYear ?? 0)
        }
        var out: [ChartBar] = []
        var group: [Bar] = []
        var current = Int.min
        func flush() {
            guard let first = group.first, let last = group.last else { return }
            out.append(ChartBar(day: last.day, firstDay: first.day, open: first.open,
                                high: group.map(\.high).max() ?? last.high, low: group.map(\.low).min() ?? last.low,
                                close: last.close, volume: group.reduce(0) { $0 + $1.volume }))
        }
        for b in bars {
            let k = key(b)
            if k != current { flush(); group = []; current = k }
            group.append(b)
        }
        flush()
        return out
    }

    static func sma(_ x: [Double], _ n: Int) -> [Double?] {
        var out = [Double?](repeating: nil, count: x.count)
        var sum = 0.0
        for i in x.indices {
            sum += x[i]
            if i >= n { sum -= x[i - n] }
            if i >= n - 1 { out[i] = sum / Double(n) }
        }
        return out
    }

    static func ema(_ x: [Double?], _ n: Int) -> [Double?] {
        var out = [Double?](repeating: nil, count: x.count)
        let k = 2 / Double(n + 1)
        var prev: Double?
        var seed: [Double] = []
        for i in x.indices {
            guard let v = x[i] else { continue }
            if let p = prev {
                prev = v * k + p * (1 - k)
            } else {
                seed.append(v)
                if seed.count == n { prev = seed.reduce(0, +) / Double(n) }
            }
            out[i] = prev
        }
        return out
    }

    static func bollinger(_ x: [Double], _ n: Int, _ k: Double) -> (mid: [Double?], upper: [Double?], lower: [Double?]) {
        let mid = sma(x, n)
        var upper = [Double?](repeating: nil, count: x.count), lower = upper
        for i in x.indices where i >= n - 1 {
            guard let m = mid[i] else { continue }
            let window = x[(i - n + 1)...i]
            let sd = (window.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(n)).squareRoot()
            upper[i] = m + k * sd
            lower[i] = m - k * sd
        }
        return (mid, upper, lower)
    }

    static func rsi(_ x: [Double], _ n: Int = 14) -> [Double?] {
        var out = [Double?](repeating: nil, count: x.count)
        guard x.count > n else { return out }
        var gain = 0.0, loss = 0.0
        for i in 1...n {
            let d = x[i] - x[i - 1]
            gain += max(d, 0); loss += max(-d, 0)
        }
        gain /= Double(n); loss /= Double(n)
        out[n] = loss == 0 ? 100 : 100 - 100 / (1 + gain / loss)
        for i in stride(from: n + 1, to: x.count, by: 1) {
            let d = x[i] - x[i - 1]
            gain = (gain * Double(n - 1) + max(d, 0)) / Double(n)
            loss = (loss * Double(n - 1) + max(-d, 0)) / Double(n)
            out[i] = loss == 0 ? 100 : 100 - 100 / (1 + gain / loss)
        }
        return out
    }

    static func macd(_ x: [Double]) -> (line: [Double?], signal: [Double?], hist: [Double?]) {
        let fast = ema(x.map { Optional($0) }, 12), slow = ema(x.map { Optional($0) }, 26)
        let line = zip(fast, slow).map { f, s -> Double? in
            guard let f, let s else { return nil }
            return f - s
        }
        let signal = ema(line, 9)
        let hist = zip(line, signal).map { l, s -> Double? in
            guard let l, let s else { return nil }
            return l - s
        }
        return (line, signal, hist)
    }

    /// Recent realised volatility ÷ the longer volatility before it: the factor's risk-budget shock.
    static func volShock(_ x: [Double], short: Int = 10, long: Int = 60) -> [Double?] {
        var out = [Double?](repeating: nil, count: x.count)
        guard x.count > short + long + 1 else { return out }
        let r = [0] + (1..<x.count).map { log(x[$0] / x[$0 - 1]) }
        func sd(_ a: Int, _ b: Int) -> Double { Stats.stdev(Array(r[(a + 1)...b])) }
        for i in (short + long + 1)..<x.count {
            let longVol = max(sd(i - short - long, i - short), 1e-6)
            out[i] = sd(i - short, i) / longVol
        }
        return out
    }

    static func heikinAshi(_ bars: [ChartBar]) -> [ChartBar] {
        var out: [ChartBar] = []
        out.reserveCapacity(bars.count)
        for (i, b) in bars.enumerated() {
            let close = (b.open + b.high + b.low + b.close) / 4
            let open = i == 0 ? (b.open + b.close) / 2 : (out[i - 1].open + out[i - 1].close) / 2
            out.append(ChartBar(day: b.day, firstDay: b.firstDay, open: open, high: max(b.high, open, close),
                                low: min(b.low, open, close), close: close, volume: b.volume))
        }
        return out
    }

    /// "Nice" tick values covering lo…hi.
    static func ticks(_ lo: Double, _ hi: Double, target: Int) -> [Double] {
        guard hi > lo, target > 0 else { return [] }
        let raw = (hi - lo) / Double(target)
        let mag = pow(10, floor(log10(raw)))
        let step = [1, 2, 2.5, 5, 10].map { $0 * mag }.first { $0 >= raw } ?? 10 * mag
        var v = ceil(lo / step) * step
        var out: [Double] = []
        while v <= hi + step * 1e-9 { out.append(v); v += step }
        return out
    }

    static func format(_ p: Double) -> String {
        let a = abs(p)
        return a >= 10_000 ? String(format: "%.0f", p) : a >= 100 ? String(format: "%.2f", p) : a >= 1 ? String(format: "%.2f", p) : String(format: "%.4f", p)
    }
}

enum DrawingStore {
    private static var url: URL { Universe.directory.appendingPathComponent("chart-drawings.json") }
    /// Snapshot mode shows demo drawings without touching the saved ones.
    nonisolated(unsafe) static var persist = true
    nonisolated(unsafe) static var demo: [String: [ChartDrawing]] = [:]

    static func load(_ symbol: String) -> [ChartDrawing] {
        demo[symbol] ?? all()[symbol] ?? []
    }

    static func save(_ symbol: String, _ drawings: [ChartDrawing]) {
        guard persist else { return }
        var everything = all()
        everything[symbol] = drawings.isEmpty ? nil : drawings
        if let data = try? JSONEncoder().encode(everything) { try? data.write(to: url, options: .atomic) }
    }

    private static func all() -> [String: [ChartDrawing]] {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: [ChartDrawing]].self, from: $0) } ?? [:]
    }
}

// MARK: - State

@MainActor
@Observable
final class ChartState {
    private(set) var symbol: String?
    var timeframe: Timeframe = .day { didSet { if timeframe != oldValue { rebuild(); showLast(timeframe.defaultBars) } } }
    var style: ChartStyle = .candles
    var logScale = false
    var indicators: Set<Indicator> = [.sma50, .sma200, .volume, .spikes, .rsi, .volShock]
    var tool: DrawingTool = .cursor
    var drawings: [ChartDrawing] = [] { didSet { if let symbol, drawings != oldValue { DrawingStore.save(symbol, drawings) } } }
    var selectedDrawing: UUID?
    var draft: ChartDrawing?
    var measure: MeasureSpan?

    /// Visible window: first bar (fractional) and number of bars across the plot.
    var start = 0.0
    var count = 160.0
    static let rightPad = 8.0

    var hover: CGPoint?
    var isHovering = false
    var plotWidth: CGFloat = 800

    private(set) var data = ChartData()
    private var source: (series: PriceSeries, vix: PriceSeries?, benchmark: PriceSeries?, spikes: Set<Int>)?

    var panes: [Indicator] { Indicator.allCases.filter { $0.isPane && indicators.contains($0) } }
    var barWidth: Double { Double(plotWidth) / count }
    var priceBars: [ChartBar] { style == .heikinAshi ? data.heikinAshi : data.bars }

    func load(symbol: String, series: PriceSeries, vix: PriceSeries?, benchmark: PriceSeries?, spikes: Set<Int>) {
        let changed = symbol != self.symbol
        self.symbol = symbol
        source = (series, vix, benchmark, spikes)
        if changed {
            drawings = DrawingStore.load(symbol)
            selectedDrawing = nil
            draft = nil
            measure = nil
        }
        rebuild()
        if changed { showLast(timeframe.defaultBars) }
    }

    private func rebuild() {
        guard let source else { data = ChartData(); return }
        var d = ChartData()
        let bars = ChartMath.aggregate(source.series.bars, timeframe)
        d.bars = bars
        d.heikinAshi = ChartMath.heikinAshi(bars)
        let closes = bars.map(\.close)
        d.sma20 = ChartMath.sma(closes, 20)
        d.sma50 = ChartMath.sma(closes, 50)
        d.sma200 = ChartMath.sma(closes, 200)
        d.ema21 = ChartMath.ema(closes.map { Optional($0) }, 21)
        (d.bbMid, d.bbUpper, d.bbLower) = ChartMath.bollinger(closes, 20, 2)
        d.rsi = ChartMath.rsi(closes)
        (d.macd, d.macdSignal, d.macdHist) = ChartMath.macd(closes)
        d.volShock = ChartMath.volShock(closes)
        if let vix = source.vix {
            let v = ChartMath.aggregate(vix.bars, timeframe)
            d.vix = bars.map { b in v.lastIndex(onOrBefore: b.day).map { v[$0].close } }
        }
        if let bench = source.benchmark {
            d.compare = bars.map { b in bench.bars.lastIndex(onOrBefore: b.day).map { bench.closes[$0] } }
        }
        d.spike = bars.map { b in source.spikes.contains { $0 >= b.firstDay && $0 <= b.day } }
        data = d
    }

    // MARK: Viewport

    func showLast(_ n: Int) {
        let total = Double(data.bars.count)
        count = min(max(Double(n), 20), total + Self.rightPad)
        start = total + Self.rightPad - count
    }

    func setRange(months: Double?) {
        guard let months else { showLast(data.bars.count + Int(Self.rightPad)); return }
        showLast(Int(months * timeframe.barsPerMonth))
    }

    /// Zoom by `factor` (< 1 zooms in) keeping the bar under `anchor` (0…1 across the plot) fixed.
    func zoom(_ factor: Double, anchor: Double = 1) {
        let total = Double(data.bars.count)
        let newCount = min(max(count * factor, 15), total + 40)
        let pivot = start + anchor * count
        start = pivot - anchor * newCount
        count = newCount
        clamp()
    }

    func pan(_ bars: Double) {
        start += bars
        clamp()
    }

    func clamp() {
        let total = Double(data.bars.count)
        start = min(max(start, -count + 10), total + Self.rightPad - 10)
    }

    var visibleRange: ClosedRange<Int>? {
        guard !data.bars.isEmpty else { return nil }
        let lo = max(0, Int(floor(start))), hi = min(data.bars.count - 1, Int(ceil(start + count)))
        return lo <= hi ? lo...hi : nil
    }

    func x(_ index: Double) -> CGFloat { CGFloat((index - start + 0.5) * barWidth) }
    func index(atX x: CGFloat) -> Int { Int(floor(Double(x) / barWidth + start)) }

    func clampedIndex(atX x: CGFloat) -> Int { min(max(index(atX: x), 0), max(data.bars.count - 1, 0)) }

    /// Fractional bar position of a stored anchor's day.
    func position(of day: Int) -> Double {
        guard let i = data.bars.lastIndex(onOrBefore: day) else { return 0 }
        return Double(i)
    }
}
