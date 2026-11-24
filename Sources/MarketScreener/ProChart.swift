import AppKit
import SwiftUI

// MARK: - Geometry

struct ChartLayout {
    static let axisWidth: CGFloat = 72
    static let timeHeight: CGFloat = 24
    static let paneHeight: CGFloat = 96

    let size: CGSize
    let panes: [Indicator]

    var plotWidth: CGFloat { max(size.width - Self.axisWidth, 60) }
    var mainRect: CGRect {
        CGRect(x: 0, y: 0, width: plotWidth,
               height: max(size.height - Self.timeHeight - CGFloat(panes.count) * Self.paneHeight, 140))
    }
    func paneRect(_ i: Int) -> CGRect {
        CGRect(x: 0, y: mainRect.maxY + CGFloat(i) * Self.paneHeight, width: plotWidth, height: Self.paneHeight)
    }
    var timeRect: CGRect { CGRect(x: 0, y: size.height - Self.timeHeight, width: plotWidth, height: Self.timeHeight) }

    /// nil = time axis or outside; -1 = price pane; 0… = indicator panes.
    func pane(at y: CGFloat) -> Int? {
        if y < mainRect.maxY { return -1 }
        for i in panes.indices where paneRect(i).contains(CGPoint(x: 1, y: y)) { return i }
        return nil
    }
}

struct YScale {
    let lo: Double
    let hi: Double
    let rect: CGRect
    let log: Bool

    private func f(_ v: Double) -> Double { log ? Foundation.log(max(v, 1e-9)) : v }

    func y(_ v: Double) -> CGFloat {
        let a = f(lo), b = f(hi)
        guard b > a else { return rect.midY }
        return rect.maxY - CGFloat((f(v) - a) / (b - a)) * rect.height
    }

    func value(_ y: CGFloat) -> Double {
        let a = f(lo), b = f(hi)
        let t = Double((rect.maxY - y) / max(rect.height, 1))
        let v = a + t * (b - a)
        return log ? exp(v) : v
    }
}

extension Array where Element == ChartBar {
    func lastIndex(onOrBefore day: Int) -> Int? {
        var lo = 0, hi = count - 1, found: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if self[mid].day <= day { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return found
    }
}

extension ChartState {
    /// The price area inside the main pane: room for the legend on top and volume at the bottom.
    func priceRect(_ main: CGRect) -> CGRect {
        let bottom = indicators.contains(.volume) ? main.height * 0.17 : 16
        return CGRect(x: main.minX, y: main.minY + 44, width: main.width, height: max(main.height - 44 - bottom, 40))
    }

    /// Benchmark rebased to the first visible bar's close, so it can share the price scale.
    func compareLine(_ range: ClosedRange<Int>) -> [Int: Double] {
        guard indicators.contains(.compare), let base = range.first(where: { data.compare[safe: $0] != nil }),
              let b0 = data.compare[base] ?? nil else { return [:] }
        let c0 = data.bars[base].close
        var out: [Int: Double] = [:]
        for i in range { if let v = data.compare[safe: i] ?? nil { out[i] = c0 * v / b0 } }
        return out
    }

    func mainScale(_ main: CGRect) -> YScale? {
        guard let r = visibleRange else { return nil }
        let bars = priceBars
        let lineStyle = style == .line || style == .area
        var lo = Double.infinity, hi = -Double.infinity
        for i in r {
            lo = min(lo, lineStyle ? bars[i].close : bars[i].low)
            hi = max(hi, lineStyle ? bars[i].close : bars[i].high)
        }
        for ind in [Indicator.sma20, .sma50, .sma200, .ema21] where indicators.contains(ind) {
            if let s = data.overlay(ind) { for i in r { if let v = s[i] { lo = min(lo, v); hi = max(hi, v) } } }
        }
        if indicators.contains(.bollinger) {
            for i in r {
                if let u = data.bbUpper[i] { hi = max(hi, u) }
                if let l = data.bbLower[i] { lo = min(lo, l) }
            }
        }
        for v in compareLine(r).values { lo = min(lo, v); hi = max(hi, v) }
        guard lo.isFinite, hi.isFinite else { return nil }
        if hi - lo < 1e-9 { hi += 1; lo -= 1 }
        let useLog = logScale && lo > 0
        if useLog {
            let span = Foundation.log(hi / lo)
            lo = lo * exp(-span * 0.06); hi = hi * exp(span * 0.06)
        } else {
            let pad = (hi - lo) * 0.06
            lo -= pad; hi += pad
        }
        return YScale(lo: lo, hi: hi, rect: priceRect(main), log: useLog)
    }

    func paneScale(_ pane: Indicator, _ rect: CGRect) -> YScale {
        let inner = rect.insetBy(dx: 0, dy: 10).offsetBy(dx: 0, dy: 4)
        guard let r = visibleRange else { return YScale(lo: 0, hi: 1, rect: inner, log: false) }
        switch pane {
        case .rsi:
            return YScale(lo: 0, hi: 100, rect: inner, log: false)
        case .macd:
            var m = 1e-9
            for i in r { for s in [data.macd, data.macdSignal, data.macdHist] { if let v = s[i] { m = max(m, abs(v)) } } }
            return YScale(lo: -m * 1.1, hi: m * 1.1, rect: inner, log: false)
        case .volShock:
            var m = 2.0
            for i in r { if let v = data.volShock[i] { m = max(m, v) } }
            return YScale(lo: 0, hi: m * 1.08, rect: inner, log: false)
        default:
            var lo = Double.infinity, hi = -Double.infinity
            for i in r { if let v = data.vix[safe: i] ?? nil { lo = min(lo, v); hi = max(hi, v) } }
            if !lo.isFinite { lo = 0; hi = 1 }
            let pad = (hi - lo) * 0.08 + 0.5
            return YScale(lo: lo - pad, hi: hi + pad, rect: inner, log: false)
        }
    }

    func anchor(at p: CGPoint, scale: YScale) -> ChartAnchor {
        let i = clampedIndex(atX: p.x)
        return ChartAnchor(day: data.bars[i].day, price: scale.value(p.y))
    }

    func point(_ a: ChartAnchor, _ scale: YScale) -> CGPoint {
        CGPoint(x: x(position(of: a.day)), y: scale.y(a.price))
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

// MARK: - Chart view

struct ProChartView: View {
    let state: ChartState
    @FocusState private var focused: Bool
    @State private var monitor: Any?

    var body: some View {
        GeometryReader { geo in
            let layout = ChartLayout(size: geo.size, panes: state.panes)
            ZStack(alignment: .topLeading) {
                ChartStaticLayer(state: state, layout: layout)
                ChartCrosshairLayer(state: state, layout: layout)
                ChartLegend(state: state, layout: layout)
                ChartInteraction(state: state, layout: layout, focused: $focused)
            }
            .onAppear { state.plotWidth = layout.plotWidth }
            .onChange(of: geo.size) { _, _ in state.plotWidth = layout.plotWidth }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { state.pan(-max(state.count / 20, 1)); return .handled }
        .onKeyPress(.rightArrow) { state.pan(max(state.count / 20, 1)); return .handled }
        .onKeyPress(.upArrow) { state.zoom(0.85); return .handled }
        .onKeyPress(.downArrow) { state.zoom(1 / 0.85); return .handled }
        .onKeyPress(.escape) {
            state.tool = .cursor; state.draft = nil; state.measure = nil; state.selectedDrawing = nil
            return .handled
        }
        .onKeyPress(keys: [.delete, .deleteForward]) { _ in
            guard let id = state.selectedDrawing else { return .ignored }
            state.drawings.removeAll { $0.id == id }
            state.selectedDrawing = nil
            return .handled
        }
        .onAppear { installMonitor() }
        .onDisappear { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    }

    /// Scroll wheel and pinch: SwiftUI has no scroll-wheel gesture on macOS, so listen locally
    /// while the pointer is over the chart.
    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak state] event in
            guard let state, MainActor.assumeIsolated({ state.isHovering }) else { return event }
            MainActor.assumeIsolated {
                let anchor = Double((state.hover?.x ?? state.plotWidth) / max(state.plotWidth, 1))
                switch event.type {
                case .magnify:
                    state.zoom(1 / (1 + Double(event.magnification)), anchor: anchor)
                case .scrollWheel where event.hasPreciseScrollingDeltas:
                    if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
                        state.pan(-Double(event.scrollingDeltaX) / state.barWidth)
                    } else {
                        state.zoom(exp(-Double(event.scrollingDeltaY) * 0.006), anchor: anchor)
                    }
                case .scrollWheel:
                    state.zoom(exp(-Double(event.scrollingDeltaY) * 0.08), anchor: anchor)
                default:
                    break
                }
            }
            return nil
        }
    }
}

// MARK: - Static layer: grid, price, overlays, panes, axes, drawings

private struct ChartStaticLayer: View {
    let state: ChartState
    let layout: ChartLayout

    var body: some View {
        // Read what the drawing depends on so the layer redraws when it changes.
        let _ = (state.start, state.count, state.style, state.logScale, state.indicators, state.timeframe,
                 state.drawings, state.draft, state.measure, state.selectedDrawing, state.data.bars.count, state.symbol)
        Canvas { ctx, _ in
            MainActor.assumeIsolated { ChartRenderer(state: state, layout: layout).draw(&ctx) }
        }
    }
}

@MainActor
private struct ChartRenderer {
    let state: ChartState
    let layout: ChartLayout

    func draw(_ ctx: inout GraphicsContext) {
        guard let range = state.visibleRange, let scale = state.mainScale(layout.mainRect) else { return }
        drawGrid(&ctx, scale)
        if state.indicators.contains(.volume) { drawVolume(&ctx, range) }
        if state.indicators.contains(.bollinger) { drawBollinger(&ctx, range, scale) }
        drawPrice(&ctx, range, scale)
        for ind in [Indicator.sma200, .sma50, .ema21, .sma20] where state.indicators.contains(ind) {
            if let s = state.data.overlay(ind) { drawLine(&ctx, s, range, scale, ind.color, width: 1.3) }
        }
        if state.indicators.contains(.compare) { drawCompare(&ctx, range, scale) }
        if state.indicators.contains(.spikes) { drawSpikes(&ctx, range) }
        drawLastPrice(&ctx, scale)
        drawDrawings(&ctx, scale)
        for (i, pane) in layout.panes.enumerated() { drawPane(&ctx, pane, layout.paneRect(i), range) }
        drawTimeAxis(&ctx, range)
        drawSeparators(&ctx)
    }

    // MARK: Grid and axes

    private func drawGrid(_ ctx: inout GraphicsContext, _ scale: YScale) {
        let main = layout.mainRect
        var grid = Path()
        let ticks = ChartMath.ticks(scale.lo, scale.hi, target: max(Int(main.height / 60), 3))
        for t in ticks {
            let y = scale.y(t)
            guard y > main.minY + 2, y < main.maxY - 2 else { continue }
            grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: main.width, y: y))
            ctx.draw(Text(ChartMath.format(t)).font(Theme.mono(10)).foregroundStyle(Theme.muted),
                     at: CGPoint(x: main.width + 8, y: y), anchor: .leading)
        }
        for x in timeTicks().map(\.x) {
            grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: layout.timeRect.minY))
        }
        ctx.stroke(grid, with: .color(Theme.border.opacity(0.55)), lineWidth: 0.5)
    }

    private func timeTicks() -> [(x: CGFloat, label: String)] {
        guard let r = state.visibleRange else { return [] }
        let bars = state.data.bars
        let span = bars[r.upperBound].date.timeIntervalSince(bars[r.lowerBound].date) / 86_400
        var out: [(CGFloat, String)] = []
        var lastX = -CGFloat.infinity
        for i in r where i > 0 {
            let d = bars[i].day, p = bars[i - 1].day
            let (y, m) = (d / 10000, (d / 100) % 100)
            let (py, pm) = (p / 10000, (p / 100) % 100)
            var label: String?
            if span > 365 * 4 {
                if y != py { label = String(y) }
            } else if span > 300 {
                if y != py { label = String(y) } else if m != pm && [4, 7, 10].contains(m) { label = Self.month(m) }
            } else if span > 50 {
                if y != py { label = String(y) } else if m != pm { label = Self.month(m) }
            } else if m != pm {
                label = Self.month(m)
            } else if (i - r.lowerBound) % 5 == 0 {
                label = String(d % 100)
            }
            guard let label else { continue }
            let x = state.x(Double(i))
            guard x - lastX > 58, x > 0, x < layout.plotWidth else { continue }
            out.append((x, label))
            lastX = x
        }
        return out
    }

    private static func month(_ m: Int) -> String {
        ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][max(0, min(11, m - 1))]
    }

    private func drawTimeAxis(_ ctx: inout GraphicsContext, _ range: ClosedRange<Int>) {
        let rect = layout.timeRect
        for t in timeTicks() {
            ctx.draw(Text(t.label).font(Theme.mono(10)).foregroundStyle(Theme.muted), at: CGPoint(x: t.x, y: rect.midY))
        }
    }

    private func drawSeparators(_ ctx: inout GraphicsContext) {
        var p = Path()
        p.move(to: CGPoint(x: layout.plotWidth, y: 0)); p.addLine(to: CGPoint(x: layout.plotWidth, y: layout.size.height))
        p.move(to: CGPoint(x: 0, y: layout.timeRect.minY)); p.addLine(to: CGPoint(x: layout.size.width, y: layout.timeRect.minY))
        for i in layout.panes.indices {
            let y = layout.paneRect(i).minY
            p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: layout.size.width, y: y))
        }
        ctx.stroke(p, with: .color(Theme.border), lineWidth: 1)
    }

    // MARK: Price

    private func drawPrice(_ ctx: inout GraphicsContext, _ range: ClosedRange<Int>, _ scale: YScale) {
        let bars = state.priceBars
        let w = state.barWidth
        switch state.style {
        case .line, .area:
            var line = Path()
            for i in range {
                let p = CGPoint(x: state.x(Double(i)), y: scale.y(bars[i].close))
                if i == range.lowerBound { line.move(to: p) } else { line.addLine(to: p) }
            }
            if state.style == .area {
                var fill = line
                fill.addLine(to: CGPoint(x: state.x(Double(range.upperBound)), y: scale.rect.maxY))
                fill.addLine(to: CGPoint(x: state.x(Double(range.lowerBound)), y: scale.rect.maxY))
                fill.closeSubpath()
                ctx.fill(fill, with: .linearGradient(Gradient(colors: [Theme.cyan.opacity(0.32), Theme.cyan.opacity(0.02)]),
                                                     startPoint: CGPoint(x: 0, y: scale.rect.minY), endPoint: CGPoint(x: 0, y: scale.rect.maxY)))
            }
            ctx.stroke(line, with: .color(Theme.cyan), style: StrokeStyle(lineWidth: 1.8, lineJoin: .round))
        case .ohlc:
            var up = Path(), down = Path()
            let tick = max(w * 0.35, 1.5)
            for i in range {
                let b = bars[i], x = state.x(Double(i))
                var p = Path()
                p.move(to: CGPoint(x: x, y: scale.y(b.high))); p.addLine(to: CGPoint(x: x, y: scale.y(b.low)))
                p.move(to: CGPoint(x: x - tick, y: scale.y(b.open))); p.addLine(to: CGPoint(x: x, y: scale.y(b.open)))
                p.move(to: CGPoint(x: x, y: scale.y(b.close))); p.addLine(to: CGPoint(x: x + tick, y: scale.y(b.close)))
                if b.close >= b.open { up.addPath(p) } else { down.addPath(p) }
            }
            ctx.stroke(up, with: .color(Theme.green), lineWidth: max(min(w * 0.12, 2), 1))
            ctx.stroke(down, with: .color(Theme.red), lineWidth: max(min(w * 0.12, 2), 1))
        case .candles, .hollow, .heikinAshi:
            var upBody = Path(), downBody = Path(), upWick = Path(), downWick = Path()
            let bodyW = max(w * 0.68, 1)
            for i in range {
                let b = bars[i], x = state.x(Double(i))
                let isUp = b.close >= b.open
                let top = scale.y(max(b.open, b.close)), bottom = scale.y(min(b.open, b.close))
                let body = CGRect(x: x - bodyW / 2, y: top, width: bodyW, height: max(bottom - top, 1))
                var wick = Path()
                wick.move(to: CGPoint(x: x, y: scale.y(b.high))); wick.addLine(to: CGPoint(x: x, y: top))
                wick.move(to: CGPoint(x: x, y: bottom)); wick.addLine(to: CGPoint(x: x, y: scale.y(b.low)))
                if isUp { upBody.addRect(body); upWick.addPath(wick) } else { downBody.addRect(body); downWick.addPath(wick) }
            }
            let wickW = max(min(w * 0.1, 1.5), 1)
            ctx.stroke(upWick, with: .color(Theme.green), lineWidth: wickW)
            ctx.stroke(downWick, with: .color(Theme.red), lineWidth: wickW)
            if state.style == .hollow {
                ctx.fill(upBody, with: .color(Theme.panel))
                ctx.stroke(upBody, with: .color(Theme.green), lineWidth: 1)
            } else {
                ctx.fill(upBody, with: .color(Theme.green))
            }
            ctx.fill(downBody, with: .color(Theme.red))
        }
    }

    private func drawVolume(_ ctx: inout GraphicsContext, _ range: ClosedRange<Int>) {
        let bars = state.data.bars
        let main = layout.mainRect
        let height = main.height * 0.15
        let top = main.maxY - height
        let maxVol = range.map { bars[$0].volume }.max() ?? 1
        guard maxVol > 0 else { return }
        var up = Path(), down = Path()
        let w = max(state.barWidth * 0.68, 1)
        for i in range {
            let h = CGFloat(bars[i].volume / maxVol) * height
            let r = CGRect(x: state.x(Double(i)) - w / 2, y: top + height - h, width: w, height: h)
            if bars[i].close >= bars[i].open { up.addRect(r) } else { down.addRect(r) }
        }
        ctx.fill(up, with: .color(Theme.green.opacity(0.28)))
        ctx.fill(down, with: .color(Theme.red.opacity(0.28)))
    }

    private func drawLine(_ ctx: inout GraphicsContext, _ s: [Double?], _ range: ClosedRange<Int>, _ scale: YScale,
                          _ color: Color, width: CGFloat, dash: [CGFloat] = []) {
        var path = Path()
        var started = false
        for i in range {
            guard let v = s[safe: i] ?? nil else { started = false; continue }
            let p = CGPoint(x: state.x(Double(i)), y: scale.y(v))
            if started { path.addLine(to: p) } else { path.move(to: p); started = true }
        }
        ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineJoin: .round, dash: dash))
    }

    private func drawBollinger(_ ctx: inout GraphicsContext, _ range: ClosedRange<Int>, _ scale: YScale) {
        let d = state.data
        var band = Path()
        let valid = range.filter { d.bbUpper[$0] != nil && d.bbLower[$0] != nil }
        guard let first = valid.first else { return }
        band.move(to: CGPoint(x: state.x(Double(first)), y: scale.y(d.bbUpper[first]!)))
        for i in valid.dropFirst() { band.addLine(to: CGPoint(x: state.x(Double(i)), y: scale.y(d.bbUpper[i]!))) }
        for i in valid.reversed() { band.addLine(to: CGPoint(x: state.x(Double(i)), y: scale.y(d.bbLower[i]!))) }
        band.closeSubpath()
        ctx.fill(band, with: .color(Theme.blue.opacity(0.07)))
        drawLine(&ctx, d.bbUpper, range, scale, Theme.blue.opacity(0.75), width: 1)
        drawLine(&ctx, d.bbLower, range, scale, Theme.blue.opacity(0.75), width: 1)
        drawLine(&ctx, d.bbMid, range, scale, Theme.blue.opacity(0.5), width: 1, dash: [3, 3])
    }

    private func drawCompare(_ ctx: inout GraphicsContext, _ range: ClosedRange<Int>, _ scale: YScale) {
        let line = state.compareLine(range)
        var s = [Double?](repeating: nil, count: state.data.bars.count)
        for (i, v) in line { s[i] = v }
        drawLine(&ctx, s, range, scale, Theme.magenta, width: 1.4)
    }

    private func drawSpikes(_ ctx: inout GraphicsContext, _ range: ClosedRange<Int>) {
        let y = state.priceRect(layout.mainRect).maxY + 6
        var tri = Path()
        var lines = Path()
        for i in range where state.data.spike[safe: i] == true {
            let x = state.x(Double(i))
            tri.move(to: CGPoint(x: x, y: y - 5))
            tri.addLine(to: CGPoint(x: x - 4.5, y: y + 3))
            tri.addLine(to: CGPoint(x: x + 4.5, y: y + 3))
            tri.closeSubpath()
            lines.move(to: CGPoint(x: x, y: layout.mainRect.minY + 40)); lines.addLine(to: CGPoint(x: x, y: y - 6))
        }
        ctx.stroke(lines, with: .color(Theme.red.opacity(0.16)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
        ctx.fill(tri, with: .color(Theme.red))
    }

    private func drawLastPrice(_ ctx: inout GraphicsContext, _ scale: YScale) {
        let bars = state.data.bars
        guard let last = bars.last else { return }
        let prev = bars.count > 1 ? bars[bars.count - 2].close : last.open
        let color = last.close >= prev ? Theme.green : Theme.red
        let y = scale.y(last.close)
        guard y > layout.mainRect.minY, y < layout.mainRect.maxY else { return }
        var line = Path()
        line.move(to: CGPoint(x: 0, y: y)); line.addLine(to: CGPoint(x: layout.plotWidth, y: y))
        ctx.stroke(line, with: .color(color.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
        axisTag(&ctx, ChartMath.format(last.close), y: y, color: color)
    }

    // MARK: Drawings

    private func drawDrawings(_ ctx: inout GraphicsContext, _ scale: YScale) {
        var clipped = ctx
        clipped.clip(to: Path(layout.mainRect))
        for d in state.drawings { drawDrawing(&clipped, d, scale, selected: d.id == state.selectedDrawing, draft: false) }
        if let d = state.draft { drawDrawing(&clipped, d, scale, selected: false, draft: true) }
        if let m = state.measure { drawMeasure(&clipped, m, scale) }
        for d in state.drawings where d.kind == .horizontal {
            axisTag(&ctx, ChartMath.format(d.a.price), y: scale.y(d.a.price), color: Theme.blue)
        }
    }

    private func drawDrawing(_ ctx: inout GraphicsContext, _ d: ChartDrawing, _ scale: YScale, selected: Bool, draft: Bool) {
        let a = state.point(d.a, scale), b = state.point(d.b, scale)
        let color = selected ? Theme.yellow : Theme.blue
        let style = StrokeStyle(lineWidth: selected ? 2 : 1.5, lineCap: .round, dash: draft ? [5, 4] : [])
        switch d.kind {
        case .trend:
            var p = Path(); p.move(to: a); p.addLine(to: b)
            ctx.stroke(p, with: .color(color), style: style)
        case .ray:
            let dx = b.x - a.x, dy = b.y - a.y
            let t = dx == 0 ? 1 : max((layout.plotWidth - a.x) / dx, 1)
            var p = Path(); p.move(to: a); p.addLine(to: CGPoint(x: a.x + dx * t, y: a.y + dy * t))
            ctx.stroke(p, with: .color(color), style: style)
        case .horizontal:
            var p = Path(); p.move(to: CGPoint(x: 0, y: a.y)); p.addLine(to: CGPoint(x: layout.plotWidth, y: a.y))
            ctx.stroke(p, with: .color(color), style: style)
        case .rectangle:
            let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
            ctx.fill(Path(r), with: .color(color.opacity(0.1)))
            ctx.stroke(Path(r), with: .color(color), style: style)
        case .fib:
            let levels: [(Double, Color)] = [(0, Theme.base1), (0.236, Theme.red), (0.382, Theme.orange), (0.5, Theme.yellow),
                                             (0.618, Theme.green), (0.786, Theme.cyan), (1, Theme.base1)]
            let x0 = min(a.x, b.x), x1 = layout.plotWidth
            var previousY: CGFloat?
            for (level, c) in levels {
                let price = d.b.price + (d.a.price - d.b.price) * level
                let y = scale.y(price)
                if let py = previousY {
                    ctx.fill(Path(CGRect(x: x0, y: min(py, y), width: x1 - x0, height: abs(y - py))), with: .color(c.opacity(0.06)))
                }
                var p = Path(); p.move(to: CGPoint(x: x0, y: y)); p.addLine(to: CGPoint(x: x1, y: y))
                ctx.stroke(p, with: .color(c.opacity(0.85)), style: StrokeStyle(lineWidth: 1, dash: draft ? [5, 4] : []))
                ctx.draw(Text(String(format: "%.3g  %@", level, ChartMath.format(price))).font(Theme.mono(9.5)).foregroundStyle(c),
                         at: CGPoint(x: x0 + 4, y: y - 7), anchor: .leading)
                previousY = y
            }
            var diag = Path(); diag.move(to: a); diag.addLine(to: b)
            ctx.stroke(diag, with: .color(Theme.muted), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        if selected || draft {
            for p in d.kind == .horizontal ? [a] : [a, b] {
                let r = CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
                ctx.fill(Path(ellipseIn: r), with: .color(Theme.panel))
                ctx.stroke(Path(ellipseIn: r), with: .color(color), lineWidth: 1.5)
            }
        }
    }

    private func drawMeasure(_ ctx: inout GraphicsContext, _ m: MeasureSpan, _ scale: YScale) {
        let a = state.point(m.a, scale), b = state.point(m.b, scale)
        let change = m.b.price / m.a.price - 1
        let color = change >= 0 ? Theme.green : Theme.red
        let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        ctx.fill(Path(r), with: .color(color.opacity(0.14)))
        var arrow = Path(); arrow.move(to: a); arrow.addLine(to: b)
        ctx.stroke(arrow, with: .color(color), lineWidth: 1.5)
        let bars = abs(Int(state.position(of: m.b.day) - state.position(of: m.a.day)))
        let days = abs(Int(TradingDay.date(m.b.day).timeIntervalSince(TradingDay.date(m.a.day)) / 86_400))
        let label = String(format: "%@  (%@)   %d bars, %d days", change.pct, ChartMath.format(m.b.price - m.a.price), bars, days)
        let text = ctx.resolve(Text(label).font(Theme.mono(11, .semibold)).foregroundStyle(Theme.base3))
        let size = text.measure(in: CGSize(width: 400, height: 30))
        let labelRect = CGRect(x: r.midX - size.width / 2 - 7, y: (change >= 0 ? r.minY : r.maxY) + (change >= 0 ? -size.height - 10 : 4),
                               width: size.width + 14, height: size.height + 6)
        ctx.fill(Path(roundedRect: labelRect, cornerRadius: 3), with: .color(color))
        ctx.draw(text, at: CGPoint(x: labelRect.midX, y: labelRect.midY))
    }

    // MARK: Panes

    private func drawPane(_ ctx: inout GraphicsContext, _ pane: Indicator, _ rect: CGRect, _ range: ClosedRange<Int>) {
        let scale = state.paneScale(pane, rect)
        let d = state.data
        var c = ctx
        c.clip(to: Path(rect))
        switch pane {
        case .rsi:
            let band = CGRect(x: 0, y: scale.y(70), width: rect.width, height: scale.y(30) - scale.y(70))
            c.fill(Path(band), with: .color(Theme.violet.opacity(0.07)))
            for level in [30.0, 50, 70] {
                var p = Path(); p.move(to: CGPoint(x: 0, y: scale.y(level))); p.addLine(to: CGPoint(x: rect.width, y: scale.y(level)))
                c.stroke(p, with: .color(Theme.border), style: StrokeStyle(lineWidth: 0.8, dash: level == 50 ? [2, 3] : [4, 3]))
                ctx.draw(Text(String(format: "%.0f", level)).font(Theme.mono(9.5)).foregroundStyle(Theme.muted),
                         at: CGPoint(x: rect.width + 8, y: scale.y(level)), anchor: .leading)
            }
            drawLine(&c, d.rsi, range, scale, Theme.violet, width: 1.4)
        case .macd:
            var up = Path(), down = Path()
            let w = max(state.barWidth * 0.6, 1)
            let zero = scale.y(0)
            for i in range {
                guard let v = d.macdHist[i] else { continue }
                let y = scale.y(v)
                let r = CGRect(x: state.x(Double(i)) - w / 2, y: min(y, zero), width: w, height: abs(zero - y))
                if v >= 0 { up.addRect(r) } else { down.addRect(r) }
            }
            c.fill(up, with: .color(Theme.green.opacity(0.45)))
            c.fill(down, with: .color(Theme.red.opacity(0.45)))
            drawLine(&c, d.macd, range, scale, Theme.blue, width: 1.3)
            drawLine(&c, d.macdSignal, range, scale, Theme.orange, width: 1.1)
            ctx.draw(Text("0").font(Theme.mono(9.5)).foregroundStyle(Theme.muted), at: CGPoint(x: rect.width + 8, y: zero), anchor: .leading)
        case .volShock:
            let one = scale.y(1), hot = scale.y(1.5)
            c.fill(Path(CGRect(x: 0, y: rect.minY, width: rect.width, height: max(hot - rect.minY, 0))), with: .color(Theme.cyan.opacity(0.07)))
            for (level, dash) in [(1.0, [2.0, 3.0]), (1.5, [4.0, 3.0])] {
                var p = Path(); p.move(to: CGPoint(x: 0, y: scale.y(level))); p.addLine(to: CGPoint(x: rect.width, y: scale.y(level)))
                c.stroke(p, with: .color(Theme.border), style: StrokeStyle(lineWidth: 0.8, dash: dash.map { CGFloat($0) }))
                ctx.draw(Text(String(format: "%.1f×", level)).font(Theme.mono(9.5)).foregroundStyle(Theme.muted),
                         at: CGPoint(x: rect.width + 8, y: scale.y(level)), anchor: .leading)
            }
            _ = one
            drawLine(&c, d.volShock, range, scale, Theme.cyan, width: 1.4)
        default:
            for t in ChartMath.ticks(scale.lo, scale.hi, target: 3) {
                ctx.draw(Text(String(format: "%.0f", t)).font(Theme.mono(9.5)).foregroundStyle(Theme.muted),
                         at: CGPoint(x: rect.width + 8, y: scale.y(t)), anchor: .leading)
            }
            drawLine(&c, d.vix, range, scale, Theme.orange, width: 1.4)
        }
    }

    private func axisTag(_ ctx: inout GraphicsContext, _ text: String, y: CGFloat, color: Color) {
        let r = CGRect(x: layout.plotWidth + 1, y: y - 9, width: ChartLayout.axisWidth - 2, height: 18)
        ctx.fill(Path(roundedRect: r, cornerRadius: 2), with: .color(color))
        ctx.draw(Text(text).font(Theme.mono(10.5, .semibold)).foregroundStyle(Theme.base3), at: CGPoint(x: r.minX + 7, y: y), anchor: .leading)
    }
}

// MARK: - Crosshair

private struct ChartCrosshairLayer: View {
    let state: ChartState
    let layout: ChartLayout

    var body: some View {
        let hover = state.hover
        let _ = (state.start, state.count, state.logScale, state.indicators)
        Canvas { ctx, _ in
            MainActor.assumeIsolated { drawCrosshair(&ctx, hover) }
        }
        .allowsHitTesting(false)
    }

    private func drawCrosshair(_ ctx: inout GraphicsContext, _ hover: CGPoint?) {
            guard let p = hover, p.x < layout.plotWidth, p.y < layout.timeRect.minY, !state.data.bars.isEmpty else { return }
            let i = state.clampedIndex(atX: p.x)
            let x = state.x(Double(i))
            var lines = Path()
            lines.move(to: CGPoint(x: x, y: 0)); lines.addLine(to: CGPoint(x: x, y: layout.timeRect.minY))
            lines.move(to: CGPoint(x: 0, y: p.y)); lines.addLine(to: CGPoint(x: layout.plotWidth, y: p.y))
            ctx.stroke(lines, with: .color(Theme.base1.opacity(0.55)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

            var value: String?
            if let pane = layout.pane(at: p.y) {
                if pane == -1, let scale = state.mainScale(layout.mainRect) {
                    value = ChartMath.format(scale.value(p.y))
                } else if pane >= 0 {
                    let ind = layout.panes[pane]
                    value = String(format: ind == .volShock ? "%.2f×" : "%.1f", state.paneScale(ind, layout.paneRect(pane)).value(p.y))
                }
            }
            if let value {
                let r = CGRect(x: layout.plotWidth + 1, y: p.y - 9, width: ChartLayout.axisWidth - 2, height: 18)
                ctx.fill(Path(roundedRect: r, cornerRadius: 2), with: .color(Theme.base02))
                ctx.stroke(Path(roundedRect: r, cornerRadius: 2), with: .color(Theme.base01), lineWidth: 1)
                ctx.draw(Text(value).font(Theme.mono(10.5, .semibold)).foregroundStyle(Theme.base2), at: CGPoint(x: r.minX + 7, y: p.y), anchor: .leading)
            }
            let label = ctx.resolve(Text(TradingDay.date(state.data.bars[i].day).formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year(.twoDigits)))
                .font(Theme.mono(10.5, .semibold)).foregroundStyle(Theme.base2))
            let size = label.measure(in: CGSize(width: 200, height: 20))
            let tr = CGRect(x: min(max(x - size.width / 2 - 6, 0), layout.plotWidth - size.width - 12), y: layout.timeRect.minY + 2,
                            width: size.width + 12, height: ChartLayout.timeHeight - 4)
            ctx.fill(Path(roundedRect: tr, cornerRadius: 2), with: .color(Theme.base02))
            ctx.stroke(Path(roundedRect: tr, cornerRadius: 2), with: .color(Theme.base01), lineWidth: 1)
            ctx.draw(label, at: CGPoint(x: tr.midX, y: tr.midY))
    }
}

// MARK: - Legend

private struct ChartLegend: View {
    @Environment(ScreenerStore.self) private var store
    let state: ChartState
    let layout: ChartLayout

    var body: some View {
        let bars = state.data.bars
        if !bars.isEmpty {
            let i = state.hover.map { state.clampedIndex(atX: $0.x) } ?? bars.count - 1
            let b = bars[i]
            let prev = i > 0 ? bars[i - 1].close : b.open
            let change = b.close / prev - 1
            let instrument = store.universe.first { $0.symbol == state.symbol }
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(state.symbol ?? "").font(Theme.mono(13, .bold)).foregroundStyle(Theme.bright)
                        if let instrument {
                            Text("\(instrument.flag) \(instrument.name)").font(Theme.label(13)).foregroundStyle(Theme.strong)
                        }
                        Text(state.timeframe.rawValue).font(Theme.mono(11)).foregroundStyle(Theme.muted)
                        HStack(spacing: 6) {
                            ohlc("O", b.open); ohlc("H", b.high); ohlc("L", b.low); ohlc("C", b.close)
                            Text("\(change.pct)").font(Theme.mono(11, .semibold)).foregroundStyle(Theme.signed(change))
                        }
                    }
                    HStack(spacing: 12) {
                        ForEach([Indicator.sma20, .sma50, .sma200, .ema21], id: \.self) { ind in
                            if state.indicators.contains(ind), let v = state.data.overlay(ind)?[i] {
                                Text("\(ind.title) \(ChartMath.format(v))").font(Theme.mono(10.5)).foregroundStyle(ind.color)
                            }
                        }
                        if state.indicators.contains(.bollinger), let u = state.data.bbUpper[i], let l = state.data.bbLower[i] {
                            Text("BB \(ChartMath.format(l)) – \(ChartMath.format(u))").font(Theme.mono(10.5)).foregroundStyle(Theme.blue)
                        }
                        if state.indicators.contains(.volume) {
                            Text("Vol \(b.volume.compact)").font(Theme.mono(10.5)).foregroundStyle(Theme.muted)
                        }
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)

                ForEach(Array(layout.panes.enumerated()), id: \.element) { k, pane in
                    paneLegend(pane, i).offset(x: 10, y: layout.paneRect(k).minY + 4)
                }
            }
            .allowsHitTesting(false)
        }
    }

    private func ohlc(_ label: String, _ v: Double) -> some View {
        HStack(spacing: 2) {
            Text(label).font(Theme.mono(10.5)).foregroundStyle(Theme.muted)
            Text(ChartMath.format(v)).font(Theme.mono(11)).foregroundStyle(Theme.bright)
        }
    }

    @ViewBuilder private func paneLegend(_ pane: Indicator, _ i: Int) -> some View {
        let d = state.data
        HStack(spacing: 8) {
            Text(pane.title).font(Theme.label(11.5, .semibold)).foregroundStyle(Theme.text)
            switch pane {
            case .rsi: value(d.rsi[safe: i] ?? nil, "%.1f", pane.color)
            case .macd:
                value(d.macd[safe: i] ?? nil, "%.3g", Theme.blue)
                value(d.macdSignal[safe: i] ?? nil, "%.3g", Theme.orange)
                value(d.macdHist[safe: i] ?? nil, "%.3g", (d.macdHist[safe: i] ?? nil).map { $0 >= 0 ? Theme.green : Theme.red } ?? Theme.muted)
            case .volShock: value(d.volShock[safe: i] ?? nil, "%.2f×", pane.color)
            default: value(d.vix[safe: i] ?? nil, "%.2f", pane.color)
            }
        }
    }

    @ViewBuilder private func value(_ v: Double?, _ format: String, _ color: Color) -> some View {
        if let v { Text(String(format: format, v)).font(Theme.mono(10.5, .semibold)).foregroundStyle(color) }
    }
}

// MARK: - Interaction

private struct ChartInteraction: View {
    let state: ChartState
    let layout: ChartLayout
    var focused: FocusState<Bool>.Binding
    @State private var mode: Mode?
    @State private var origin = 0.0

    private enum Mode { case pan, draw, measure }

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let p):
                    state.hover = p
                    state.isHovering = true
                case .ended:
                    state.hover = nil
                    state.isHovering = false
                }
            }
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .local)
                    .onChanged(dragChanged)
                    .onEnded { _ in dragEnded() }
            )
            .gesture(
                SpatialTapGesture(count: 2).onEnded { _ in
                    withAnimation(Motion.ui) { state.showLast(state.timeframe.defaultBars) }
                }
                .exclusively(before: SpatialTapGesture().onEnded { tap($0.location) })
            )
    }

    private func dragChanged(_ v: DragGesture.Value) {
        focused.wrappedValue = true
        guard let scale = state.mainScale(layout.mainRect) else { return }
        if mode == nil {
            let shift = NSEvent.modifierFlags.contains(.shift)
            let inMain = layout.pane(at: v.startLocation.y) == -1
            if inMain && (state.tool == .measure || shift) { mode = .measure }
            else if inMain && state.tool.drawingKind != nil { mode = .draw }
            else { mode = .pan; origin = state.start }
        }
        state.hover = v.location
        switch mode {
        case .pan:
            state.start = origin - Double(v.translation.width) / state.barWidth
            state.clamp()
        case .draw:
            guard let kind = state.tool.drawingKind else { return }
            let a = state.anchor(at: v.startLocation, scale: scale)
            state.draft = ChartDrawing(kind: kind, a: a, b: kind == .horizontal ? a : state.anchor(at: v.location, scale: scale))
        case .measure:
            state.measure = MeasureSpan(a: state.anchor(at: v.startLocation, scale: scale), b: state.anchor(at: v.location, scale: scale))
        case nil:
            break
        }
    }

    private func dragEnded() {
        if mode == .draw, let d = state.draft {
            state.drawings.append(d)
            state.selectedDrawing = d.id
            state.draft = nil
            state.tool = .cursor
        }
        if mode == .measure, state.tool == .measure { state.tool = .cursor }
        mode = nil
    }

    private func tap(_ p: CGPoint) {
        focused.wrappedValue = true
        guard let scale = state.mainScale(layout.mainRect), layout.pane(at: p.y) == -1 else { return }
        if state.tool == .horizontal {
            let a = state.anchor(at: p, scale: scale)
            let d = ChartDrawing(kind: .horizontal, a: a, b: a)
            state.drawings.append(d)
            state.selectedDrawing = d.id
            state.tool = .cursor
            return
        }
        if state.measure != nil { state.measure = nil; return }
        state.selectedDrawing = hitTest(p, scale)
    }

    /// The drawing within 6 pt of `p`, if any.
    private func hitTest(_ p: CGPoint, _ scale: YScale) -> UUID? {
        func dist(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            let dx = b.x - a.x, dy = b.y - a.y
            let len2 = dx * dx + dy * dy
            let t = len2 == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
            return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
        }
        for d in state.drawings.reversed() {
            let a = state.point(d.a, scale), b = state.point(d.b, scale)
            let segments: [(CGPoint, CGPoint)]
            switch d.kind {
            case .trend: segments = [(a, b)]
            case .ray:
                let t = b.x == a.x ? 1 : max((layout.plotWidth - a.x) / (b.x - a.x), 1)
                segments = [(a, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))]
            case .horizontal: segments = [(CGPoint(x: 0, y: a.y), CGPoint(x: layout.plotWidth, y: a.y))]
            case .rectangle:
                let c1 = CGPoint(x: a.x, y: b.y), c2 = CGPoint(x: b.x, y: a.y)
                segments = [(a, c1), (c1, b), (b, c2), (c2, a)]
            case .fib:
                segments = [0, 0.236, 0.382, 0.5, 0.618, 0.786, 1].map { level in
                    let y = scale.y(d.b.price + (d.a.price - d.b.price) * level)
                    return (CGPoint(x: min(a.x, b.x), y: y), CGPoint(x: layout.plotWidth, y: y))
                }
            }
            if segments.contains(where: { dist(p, $0.0, $0.1) < 6 }) { return d.id }
        }
        return nil
    }
}
