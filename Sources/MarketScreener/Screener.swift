import Foundation

// Thesis: when volatility jumps, institutions de-risk mechanically (VaR limits, vol targeting,
// redemptions) and sell what they own most, often their momentum winners, regardless of
// fundamentals. The screen looks for strong, cash-generative stocks that dropped hard into a
// VIX spike without company-specific news to explain it.

struct ScoreBreakdown: Hashable {
    static let maxDrop = 30.0, maxMomentum = 25.0, maxQuality = 20.0, maxFlow = 10.0, maxVolume = 5.0, maxOversold = 10.0

    var drop = 0.0       // how unusual the drop is vs. the stock's own volatility
    var momentum = 0.0   // 12-1 month momentum before the drop, ranked within the universe
    var quality = 0.0    // FCF yield, FCF margin, revenue growth (P/E for financials), ranked
    var flow = 0.0       // no company-specific catalyst headlines during the drop
    var volume = 0.0     // volume surge during the drop: a footprint of forced selling
    var oversold = 0.0   // RSI(14)

    var total: Double { drop + momentum + quality + flow + volume + oversold }
}

struct FundamentalMetrics: Hashable {
    var fcfYield: Double?
    var fcfMargin: Double?
    var revenueGrowth: Double?
    var operatingMargin: Double?
    var pe: Double?
    var forwardPE: Double?
    var marketCapUSD: Double?
    var fcfUSD: Double?

    var earningsYield: Double? { pe.flatMap { $0 > 0 ? 1 / $0 : nil } }
}

enum NewsSignal: Hashable {
    case unknown                        // not loaded, or a historical anchor (feed only covers recent days)
    case quiet(headlines: Int)          // headlines in the window, none of them catalysts
    case catalysts(Int, headlines: Int)

    var isQuiet: Bool {
        if case .quiet = self { return true }
        return false
    }

    var sortValue: Double? {
        switch self {
        case .unknown: nil
        case .quiet: 0
        case .catalysts(let n, _): Double(n)
        }
    }
}

/// Earnings around the window: a report inside it may explain the drop better than forced selling.
struct EarningsTiming: Hashable {
    var inWindow: EarningsDate?   // first reaction inside the window
    var next: EarningsDate?       // the next report after the window's last close
    var daysToNext: Int?          // calendar days from the window's last close

    var isLoaded: Bool { inWindow != nil || next != nil || known }
    var known = false             // Yahoo returned dates for this stock

    /// "reports in 3d", "reports today" etc., only for reports within two weeks.
    var upcomingLabel: String? {
        guard let d = daysToNext, d <= 14, let next else { return nil }
        let when = d <= 0 ? "today" : d == 1 ? "tomorrow" : "in \(d)d"
        return "earnings \(when)" + (next.estimate ? " (est.)" : "")
    }

    init() {}

    init(_ dates: [EarningsDate]?, from startDay: Int, to endDay: Int) {
        guard let dates, !dates.isEmpty else { return }
        known = true
        inWindow = dates.last { $0.reactionDays.contains { $0 > startDay && $0 <= endDay } }
        // "Upcoming" only means something when the window ends at the latest close.
        guard TradingDay.days(from: endDay, to: TradingDay.day(from: Date())) <= 4 else { return }
        next = dates.first { $0.day >= endDay && $0 != inWindow }
        daysToNext = next.map { TradingDay.days(from: endDay, to: $0.day) }
    }
}

struct StockMetrics: Identifiable, Hashable {
    let instrument: Instrument
    let currency: String
    let windowStartDay: Int   // the reference close before the window
    let windowEndDay: Int
    let price: Double
    let windowReturn: Double
    let dayReturn: Double
    let dailyVol: Double      // stdev of daily log returns, 60 sessions before the window
    let zScore: Double
    let rsi: Double
    let momentum12_1: Double? // return from 12 months to 1 month before the window
    let return3m: Double?     // return over the 3 months before the window
    let volumeRatio: Double?  // average volume in the window vs. the 20 sessions before it
    let vsSMA50: Double
    let vsSMA200: Double
    let fromHigh52w: Double
    let beta: Double
    let benchmarkReturn: Double
    let excessReturn: Double
    let forwardReturn: Double?    // from the end of the reaction window to the latest close
    let sincePreSpike: Double?    // latest close vs. the pre-spike close (≥ 0 means fully recovered)
    let benchmarkForward: Double?
    let fundamentals: FundamentalMetrics
    let news: NewsSignal
    var earnings = EarningsTiming()
    var momentumRank = 0.5
    var qualityRank = 0.5
    var score = ScoreBreakdown()

    var id: String { instrument.symbol }
    var symbol: String { instrument.symbol }
    var name: String { instrument.name }
    var isMomentumLeader: Bool { momentumRank >= 2.0 / 3.0 }
}

enum Screener {
    /// What span of time each stock's move is measured over.
    enum Period: Equatable, Sendable {
        case trailing(sessions: Int)                 // the last N sessions
        case reaction(spikeDay: Int, sessions: Int)  // N sessions from the last close before a spike
        case range(from: Int, to: Int)               // from the close before `from` to the close on `to`

        var isTrailing: Bool {
            if case .trailing = self { return true }
            return false
        }
    }

    struct Inputs: Sendable {
        var universe: [Instrument]
        var series: [String: PriceSeries]
        var benchmark: PriceSeries?
        var fundamentals: [String: Fundamentals]
        var fx: [String: Double]
        var news: [String: [NewsItem]]
        var period: Period
        var earnings: [String: [EarningsDate]] = [:]
    }

    /// Index of the reference close (start) and the last close (end) of `period` in `bars`.
    /// Asia-Pacific closes before the US session, so for a spike its spike-day close is still pre-shock.
    static func bounds(_ period: Period, bars: [Bar], session: Instrument.Session = .americas) -> (start: Int, end: Int)? {
        guard !bars.isEmpty else { return nil }
        switch period {
        case .trailing(let n):
            return (bars.count - 1 - n, bars.count - 1)
        case .reaction(let spikeDay, let n):
            guard let i = bars.lastIndex(onOrBefore: spikeDay) else { return nil }
            let start = bars[i].day == spikeDay && session != .asiaPacific ? i - 1 : i
            return (start, min(start + n, bars.count - 1))
        case .range(let from, let to):
            guard let i = bars.lastIndex(onOrBefore: from), let end = bars.lastIndex(onOrBefore: to) else { return nil }
            return (bars[i].day == from ? i - 1 : i, end)
        }
    }

    static func run(_ input: Inputs) -> [StockMetrics] {
        var benchByDay: [Int: Double] = [:]
        for b in input.benchmark?.bars ?? [] { benchByDay[b.day] = b.close }

        var rows = input.universe.compactMap { inst -> StockMetrics? in
            guard let series = input.series[inst.symbol] else { return nil }
            return analyze(inst, series: series, input: input, benchByDay: benchByDay)
        }

        // Cross-sectional ranks so the score adapts to the market regime.
        let momentumRank = ranker(rows.compactMap(\.momentum12_1))
        let nonFin = rows.filter { !$0.instrument.isFinancial }
        let fcfYieldRank = ranker(nonFin.compactMap(\.fundamentals.fcfYield))
        let fcfMarginRank = ranker(nonFin.compactMap(\.fundamentals.fcfMargin))
        let growthRank = ranker(rows.compactMap(\.fundamentals.revenueGrowth))
        let earningsYieldRank = ranker(rows.compactMap(\.fundamentals.earningsYield))

        for i in rows.indices {
            let f = rows[i].fundamentals
            rows[i].momentumRank = rows[i].momentum12_1.map(momentumRank) ?? 0.5
            let parts: [(Double?, Double)] = rows[i].instrument.isFinancial
                ? [(f.earningsYield.map(earningsYieldRank), 0.5), (f.revenueGrowth.map(growthRank), 0.5)]
                : [(f.fcfYield.map(fcfYieldRank), 0.4), (f.fcfMargin.map(fcfMarginRank), 0.3), (f.revenueGrowth.map(growthRank), 0.3)]
            let known = parts.compactMap { p in p.0.map { ($0, p.1) } }
            let weight = known.reduce(0) { $0 + $1.1 }
            rows[i].qualityRank = weight > 0 ? known.reduce(0) { $0 + $1.0 * $1.1 } / weight : 0.5
            rows[i].score = score(rows[i])
        }
        return rows
    }

    private static func score(_ m: StockMetrics) -> ScoreBreakdown {
        var s = ScoreBreakdown()
        s.drop = Stats.clamp01(-m.zScore / 3) * ScoreBreakdown.maxDrop
        s.momentum = m.momentumRank * ScoreBreakdown.maxMomentum
        s.quality = m.qualityRank * ScoreBreakdown.maxQuality
        // An earnings report inside the window is a catalyst, whatever the headlines say.
        let headlines = switch m.news {
        case .quiet: ScoreBreakdown.maxFlow
        case .catalysts: 0.0
        case .unknown: ScoreBreakdown.maxFlow / 2
        }
        s.flow = m.earnings.inWindow != nil ? 0 : headlines
        s.volume = (m.volumeRatio.map { Stats.clamp01(($0 - 1) / 1.5) } ?? 0.5) * ScoreBreakdown.maxVolume
        s.oversold = Stats.clamp01((55 - m.rsi) / 30) * ScoreBreakdown.maxOversold
        return s
    }

    /// Returns a function mapping a value to its percentile (0...1) within `values`.
    private static func ranker(_ values: [Double]) -> (Double) -> Double {
        let sorted = values.sorted()
        guard sorted.count > 1 else { return { _ in 0.5 } }
        return { v in
            var lo = 0, hi = sorted.count
            while lo < hi { let mid = (lo + hi) / 2; if sorted[mid] < v { lo = mid + 1 } else { hi = mid } }
            return Double(lo) / Double(sorted.count - 1)
        }
    }

    private static func analyze(_ inst: Instrument, series: PriceSeries, input: Inputs,
                                benchByDay: [Int: Double]) -> StockMetrics? {
        let bars = series.bars
        let c = series.closes
        guard let (start, end) = bounds(input.period, bars: bars, session: inst.session),
              start >= 61, end >= 199, end > start else { return nil }
        let historical = !input.period.isTrailing

        let price = c[end]
        let windowReturn = price / c[start] - 1
        var rets: [Double] = []
        for i in (start - 59)...start { rets.append(log(c[i] / c[i - 1])) }
        let vol = max(Stats.stdev(rets), 0.004)
        let z = log(price / c[start]) / (vol * Double(end - start).squareRoot())

        let volumes = series.volumes
        let baseVolume = Stats.mean(volumes[(start - 19)...start])
        let windowVolume = Stats.mean(volumes[(start + 1)...end])
        let volumeRatio = baseVolume > 0 && windowVolume > 0 ? windowVolume / baseVolume : nil

        let sma50 = Stats.sma(c, period: 50, end: end) ?? price
        let sma200 = Stats.sma(c, period: 200, end: end) ?? price
        let high52 = c[max(0, end - 251)...end].max() ?? price

        var benchReturn = 0.0
        var benchForward: Double?
        let beta = input.benchmark == nil ? 1 : Self.beta(bars: bars, benchByDay: benchByDay, endIndex: start)
        if let b = input.benchmark?.bars,
           let bs = b.lastIndex(onOrBefore: bars[start].day),
           let be = b.lastIndex(onOrBefore: bars[end].day) {
            benchReturn = b[be].close / b[bs].close - 1
            if historical, be < b.count - 1 { benchForward = b[b.count - 1].close / b[be].close - 1 }
        }

        var metrics = StockMetrics(
            instrument: inst, currency: series.currency,
            windowStartDay: bars[start].day, windowEndDay: bars[end].day,
            price: price, windowReturn: windowReturn, dayReturn: price / c[end - 1] - 1,
            dailyVol: vol, zScore: z, rsi: Stats.rsi(c, end: end) ?? 50,
            momentum12_1: start >= 252 ? c[start - 21] / c[start - 252] - 1 : nil,
            return3m: c[start] / c[start - 61] - 1,
            volumeRatio: volumeRatio,
            vsSMA50: price / sma50 - 1, vsSMA200: price / sma200 - 1,
            fromHigh52w: price / high52 - 1,
            beta: beta, benchmarkReturn: benchReturn, excessReturn: windowReturn - beta * benchReturn,
            forwardReturn: historical && end < bars.count - 1 ? c[c.count - 1] / price - 1 : nil,
            sincePreSpike: historical ? c[c.count - 1] / c[start] - 1 : nil,
            benchmarkForward: benchForward,
            fundamentals: fundamentalMetrics(input.fundamentals[inst.symbol], series: series, fx: input.fx),
            news: newsSignal(input.news[inst.symbol], from: bars[start].day, to: bars[end].day))
        metrics.earnings = EarningsTiming(input.earnings[inst.symbol], from: bars[start].day, to: bars[end].day)
        return metrics
    }

    /// Catalyst headlines published during the drop. The RSS feed only reaches back a
    /// week or two, so older windows are `.unknown` rather than falsely "quiet".
    private static func newsSignal(_ items: [NewsItem]?, from startDay: Int, to endDay: Int) -> NewsSignal {
        guard let items else { return .unknown }
        let from = TradingDay.date(startDay)   // midday of the reference session
        let to = TradingDay.date(endDay).addingTimeInterval(86_400)
        guard Date().timeIntervalSince(from) < 14 * 86_400 else { return .unknown }
        let inWindow = items.filter { $0.date >= from && $0.date <= to }
        let catalysts = inWindow.filter(\.isCatalyst).count
        return catalysts == 0 ? .quiet(headlines: inWindow.count) : .catalysts(catalysts, headlines: inWindow.count)
    }

    /// Fundamentals are the latest reported figures (not point-in-time), so for historical
    /// anchors they reflect today's knowledge.
    static func fundamentalMetrics(_ f: Fundamentals?, series: PriceSeries, fx: [String: Double]) -> FundamentalMetrics {
        guard let f else { return FundamentalMetrics() }
        let fallback = Currency.normalize(series.currency)
        let reportCcy = Currency.normalize(f.reportCurrency) ?? fallback
        let capCcy = Currency.normalize(f.marketCapCurrency) ?? fallback

        func usd(_ value: Double?, _ ccy: String?) -> Double? {
            guard let value, let ccy else { return nil }
            return ccy == "USD" ? value : fx[ccy].map { value * $0 }
        }

        // Roll the last reported market cap forward with the share price since then.
        var cap = f.marketCap
        if let m = cap, let d = f.marketCapDay, let i = series.bars.lastIndex(onOrBefore: d), let last = series.bars.last {
            cap = m * last.close / series.bars[i].close
        }

        var out = FundamentalMetrics()
        out.marketCapUSD = usd(cap, capCcy)
        out.fcfUSD = usd(f.fcf, reportCcy)
        if let fcf = f.fcf, let cap, cap > 0 {
            if reportCcy == capCcy {
                out.fcfYield = fcf / cap
            } else if let fcfUSD = out.fcfUSD, let capUSD = out.marketCapUSD {
                out.fcfYield = fcfUSD / capUSD
            }
        }
        if let rev = f.revenue, rev > 0 {
            out.fcfMargin = f.fcf.map { $0 / rev }
            out.operatingMargin = f.operatingIncome.map { $0 / rev }
        }
        out.revenueGrowth = f.revenueGrowth.flatMap { $0.isFinite ? $0 : nil }
        out.pe = f.pe
        out.forwardPE = f.forwardPE
        return out
    }

    /// Beta on non-overlapping 5-session returns over ~1 year. Weekly returns soften the
    /// time-zone mismatch between e.g. Tokyo closes and the US-listed benchmark.
    static func beta(bars: [Bar], benchByDay: [Int: Double], endIndex: Int, lookback: Int = 250, step: Int = 5) -> Double {
        var common: [(Double, Double)] = []
        for i in max(0, endIndex - lookback)...endIndex {
            if let bc = benchByDay[bars[i].day] { common.append((bars[i].close, bc)) }
        }
        var xs: [Double] = [], ys: [Double] = []
        var j = step
        while j < common.count {
            ys.append(log(common[j].0 / common[j - step].0))
            xs.append(log(common[j].1 / common[j - step].1))
            j += step
        }
        guard xs.count >= 20 else { return 1 }
        let mx = Stats.mean(xs), my = Stats.mean(ys)
        var cov = 0.0, varX = 0.0
        for k in xs.indices {
            cov += (xs[k] - mx) * (ys[k] - my)
            varX += (xs[k] - mx) * (xs[k] - mx)
        }
        guard varX > 0 else { return 1 }
        return min(max(cov / varX, 0), 3)
    }
}
