import Foundation

// Thesis as a continuous factor: institutions size positions by risk (VaR limits, volatility
// targeting, risk parity). When a stock's realised volatility jumps, its risk weight rises and
// holders trim regardless of value. Whoever absorbs that selling is paid when the price recovers.
//
// Signal per stock at each rebalance:
//   drop      z = log return over the lookback ÷ (pre-window daily vol × √lookback)
//   shock     = recent realised vol ÷ the longer vol before the window
//   factor    = −z × shock   (fell hard *while* its risk jumped → highest score)

struct FactorSpec: Sendable {
    let name: String
    let note: String
    let lookback: Int
    let hold: Int          // sessions held; rebalance every `hold` sessions
    let shortVol: Int
    let longVol: Int
    let momentumOnly: Bool // only the top half by 12-1 momentum (crowded holdings)
    let stressGated: Bool  // trade only when VIX is elevated or credit spreads widened
    let useShock: Bool     // false = plain reversal baseline

    var periodsPerYear: Double { 252 / Double(hold) }
}

struct FactorReport: Sendable {
    struct Period: Sendable {
        let day: Int
        let longShort: Double     // top quintile − bottom quintile, gross
        let longExcess: Double    // top quintile − all candidates (long-only view)
        let turnover: Double      // average share of names traded per leg
        let active: Bool
        let stressed: Bool        // VIX above its trailing 1-year median
        let shock: Bool           // VIX up ≥ 20% over the prior week
        let creditWidening: Bool  // implied HY spread up ≥ 15 bp over the prior week
        let quality: Bool         // BBB − AAA quality spread widening unusually fast
    }

    struct Summary: Sendable {
        let annReturn: Double
        let annVol: Double
        let sharpe: Double
        let t: Double
        let hitRate: Double
        let periods: Int
    }

    struct Variant: Identifiable, Sendable {
        let spec: FactorSpec
        let periods: [Period]
        let gross: Summary
        let net5: Summary         // after 5 bp per side
        let net10: Summary        // after 10 bp per side
        let longOnly: Summary     // top quintile vs. all candidates, 5 bp per side on the long leg
        let calm: Summary
        let stressed: Summary
        let shock: Summary
        let creditWidening: Summary
        let riskBudget: Summary   // VIX or HY stress while the quality spread is calm
        let creditCrisis: Summary // quality spread widening
        let turnover: Double
        var id: String { spec.name }
    }

    struct Holding: Identifiable, Sendable {
        let instrument: Instrument
        let signal: Double
        let move: Double
        let z: Double
        let volShock: Double
        let momentumRank: Double
        var id: String { instrument.symbol }
    }

    let universe: String
    let variants: [Variant]
    /// Today's top-ranked momentum leaders on the weekly signal: the current long list.
    let holdings: [Holding]
    /// Whether the stress gate is open right now (VIX elevated or credit widening), and why.
    let gateOpen: Bool
    let vixNow: Double?
    let vixMedian: Double?
    let creditWeek: Double?   // implied HY spread change over the last 5 sessions, bp
}

enum RiskBudgetFactor {
    static let specs: [FactorSpec] = [
        .init(name: "Weekly", note: "5-day drop × 10/60-day vol shock, all stocks",
              lookback: 5, hold: 5, shortVol: 10, longVol: 60, momentumOnly: false, stressGated: false, useShock: true),
        .init(name: "Weekly, momentum leaders", note: "Same, within the top half by 12-1 momentum",
              lookback: 5, hold: 5, shortVol: 10, longVol: 60, momentumOnly: true, stressGated: false, useShock: true),
        .init(name: "Weekly, only under stress", note: "Momentum leaders, traded only while \(VolIndex.current.name) is above its 1-year median or credit spreads widen; flat otherwise",
              lookback: 5, hold: 5, shortVol: 10, longVol: 60, momentumOnly: true, stressGated: true, useShock: true),
        .init(name: "Monthly", note: "1-month drop × 21/120-day vol shock, rebalanced monthly",
              lookback: 21, hold: 21, shortVol: 21, longVol: 120, momentumOnly: false, stressGated: false, useShock: true),
        .init(name: "Monthly, momentum leaders", note: "Same, within the top half by 12-1 momentum",
              lookback: 21, hold: 21, shortVol: 21, longVol: 120, momentumOnly: true, stressGated: false, useShock: true),
        .init(name: "Plain weekly reversal", note: "Baseline: last week's losers, ignoring volatility",
              lookback: 5, hold: 5, shortVol: 10, longVol: 60, momentumOnly: false, stressGated: false, useShock: false),
        .init(name: "Plain monthly reversal", note: "Baseline: last month's losers, ignoring volatility",
              lookback: 21, hold: 21, shortVol: 21, longVol: 120, momentumOnly: false, stressGated: false, useShock: false),
    ]

    struct Features {
        let z: Double
        let shock: Double
        let momentum: Double
        let move: Double

        func signal(_ spec: FactorSpec) -> Double { spec.useShock ? -z * shock : -z }
    }

    /// Flat arrays with running sums, so any window's volatility is O(1).
    struct Prepared {
        let instrument: Instrument
        let bars: [Bar]
        let closes: [Double]
        let sum: [Double]    // cumulative log returns
        let sum2: [Double]   // cumulative squared log returns

        init(_ instrument: Instrument, _ series: PriceSeries) {
            self.instrument = instrument
            bars = series.bars
            closes = series.closes
            var s = [0.0], s2 = [0.0]
            s.reserveCapacity(closes.count)
            s2.reserveCapacity(closes.count)
            for i in 1..<max(closes.count, 1) {
                let r = log(closes[i] / closes[i - 1])
                s.append(s[i - 1] + r)
                s2.append(s2[i - 1] + r * r)
            }
            sum = s
            sum2 = s2
        }

        /// Sample stdev of daily log returns over bars (a, b].
        func vol(_ a: Int, _ b: Int) -> Double? {
            let n = Double(b - a)
            guard a >= 0, b < sum.count, n >= 2 else { return nil }
            let s = sum[b] - sum[a], s2 = sum2[b] - sum2[a]
            return max((s2 - s * s / n) / (n - 1), 0).squareRoot()
        }

        func features(at e: Int, _ spec: FactorSpec) -> Features? {
            guard e >= 260, e < closes.count,
                  let longVol = vol(e - spec.lookback - spec.longVol, e - spec.lookback),
                  let shortVol = vol(e - spec.shortVol, e) else { return nil }
            let floor = max(longVol, 0.004)
            let r = log(closes[e] / closes[e - spec.lookback])
            return Features(z: r / (floor * Double(spec.lookback).squareRoot()),
                            shock: shortVol / floor,
                            momentum: closes[e - 21] / closes[e - 252] - 1,
                            move: closes[e] / closes[e - spec.lookback] - 1)
        }
    }

    static func run(universe: [Instrument], series: [String: PriceSeries], calendar: [Bar], vix: [Bar],
                    credit: [Int: Double] = [:], quality: [Int: Double] = [:], title: String) -> FactorReport {
        let prepared = universe.compactMap { inst in series[inst.symbol].map { Prepared(inst, $0) } }
        let vixCloses = vix.map(\.close)
        func regime(_ day: Int) -> Regime { Self.regime(day, vix: vix, vixCloses: vixCloses, calendar: calendar, credit: credit, quality: quality) }

        let variants = specs.map { spec -> FactorReport.Variant in
            var periods: [FactorReport.Period] = []
            var previous = (long: Set<String>(), short: Set<String>())
            var wasActive = false
            for start in stride(from: 300, to: max(calendar.count - spec.hold, 300), by: spec.hold) {
                let day = calendar[start].day
                let r = regime(day)
                let active = !spec.stressGated || r.stressed || r.credit
                guard active else {
                    // Flat: closing the book costs one round of turnover.
                    periods.append(.init(day: day, longShort: 0, longExcess: 0, turnover: wasActive ? 1 : 0,
                                         active: false, stressed: r.stressed, shock: r.shock, creditWidening: r.credit, quality: r.quality))
                    previous = ([], [])
                    wasActive = false
                    continue
                }
                let date = TradingDay.date(day)
                var rows: [(id: String, f: Features, fwd: Double)] = []
                for p in prepared {
                    guard let e = p.bars.lastIndex(onOrBefore: day), e + spec.hold < p.closes.count,
                          date.timeIntervalSince(p.bars[e].date) < 6 * 86_400,   // skip stale or suspended lines
                          let f = p.features(at: e, spec) else { continue }
                    rows.append((p.instrument.symbol, f, p.closes[e + spec.hold] / p.closes[e] - 1))
                }
                guard rows.count >= 25 else { continue }
                var candidates = rows
                if spec.momentumOnly {
                    let sorted = rows.map(\.f.momentum).sorted()
                    let median = sorted[sorted.count / 2]
                    candidates = rows.filter { $0.f.momentum >= median }
                }
                guard candidates.count >= 15 else { continue }
                let ranked = candidates.sorted { $0.f.signal(spec) > $1.f.signal(spec) }
                let q = max(candidates.count / 5, 3)
                let long = ranked.prefix(q), short = ranked.suffix(q)
                let longIDs = Set(long.map(\.id)), shortIDs = Set(short.map(\.id))
                let turnover = previous.long.isEmpty ? 1
                    : Double(longIDs.subtracting(previous.long).count + shortIDs.subtracting(previous.short).count) / Double(2 * q)
                previous = (longIDs, shortIDs)
                wasActive = true
                let longReturn = Stats.mean(long.map(\.fwd))
                periods.append(.init(day: day,
                                     longShort: longReturn - Stats.mean(short.map(\.fwd)),
                                     longExcess: longReturn - Stats.mean(candidates.map(\.fwd)),
                                     turnover: turnover, active: true,
                                     stressed: r.stressed, shock: r.shock, creditWidening: r.credit, quality: r.quality))
            }

            // Each replaced position is sold and bought: 2 × cost per side, on each leg traded.
            func net(_ bps: Double) -> [Double] { periods.map { $0.longShort - $0.turnover * 2 * 2 * bps / 10_000 } }
            let ppy = spec.periodsPerYear
            return .init(spec: spec, periods: periods,
                         gross: summarize(periods.map(\.longShort), ppy),
                         net5: summarize(net(5), ppy),
                         net10: summarize(net(10), ppy),
                         longOnly: summarize(periods.map { $0.longExcess - $0.turnover * 2 * 5 / 10_000 }, ppy),
                         calm: summarize(periods.filter { !$0.stressed }.map(\.longShort), ppy),
                         stressed: summarize(periods.filter(\.stressed).map(\.longShort), ppy),
                         shock: summarize(periods.filter(\.shock).map(\.longShort), ppy),
                         creditWidening: summarize(periods.filter(\.creditWidening).map(\.longShort), ppy),
                         riskBudget: summarize(periods.filter { ($0.stressed || $0.creditWidening) && !$0.quality }.map(\.longShort), ppy),
                         creditCrisis: summarize(periods.filter(\.quality).map(\.longShort), ppy),
                         turnover: Stats.mean(periods.filter(\.active).map(\.turnover)))
        }

        // Today's ranking: momentum leaders on the weekly signal.
        let spec = specs[1]
        let latest = prepared.compactMap { p -> (Prepared, Features)? in
            p.features(at: p.closes.count - 1, spec).map { (p, $0) }
        }
        let moms = latest.map(\.1.momentum).sorted()
        let median = moms.isEmpty ? 0 : moms[moms.count / 2]
        let holdings = latest
            .filter { $0.1.momentum >= median }
            .map { p, f in
                FactorReport.Holding(instrument: p.instrument, signal: f.signal(spec), move: f.move, z: f.z, volShock: f.shock,
                                     momentumRank: Double(moms.firstIndex { $0 >= f.momentum } ?? 0) / Double(max(moms.count - 1, 1)))
            }
            .sorted { $0.signal > $1.signal }
        let now = calendar.last.map { regime($0.day) }
        let recentVix = vixCloses.suffix(252).sorted()

        return FactorReport(universe: title, variants: variants, holdings: Array(holdings.prefix(20)),
                            gateOpen: now.map { $0.stressed || $0.credit } ?? false,
                            vixNow: vixCloses.last,
                            vixMedian: recentVix.isEmpty ? nil : recentVix[recentVix.count / 2],
                            creditWeek: MarketStress.change(credit, calendar: calendar, from: calendar.count - 6, to: calendar.count - 1))
    }

    struct Regime {
        let stressed: Bool   // VIX above its trailing 1-year median
        let shock: Bool      // VIX up ≥ 20% over the prior week
        let credit: Bool     // implied HY spread up ≥ 15 bp over the prior week
        let quality: Bool    // BBB − AAA spread widening unusually fast: a credit crisis, not just volatility
        var riskBudget: Bool { (stressed || credit) && !quality }
    }

    /// Regime on a given day, using only data up to that day.
    static func regime(_ day: Int, vix: [Bar], vixCloses: [Double], calendar: [Bar], credit: [Int: Double],
                       quality: [Int: Double] = [:]) -> Regime {
        var stressed = false, shock = false, widening = false, qualityWidening = false
        if let i = vix.lastIndex(onOrBefore: day), i >= 252 {
            let window = vixCloses[(i - 251)...i].sorted()
            stressed = vixCloses[i] > window[window.count / 2]
            shock = vixCloses[i] / vixCloses[i - 5] - 1 >= 0.20
        }
        if let i = calendar.lastIndex(onOrBefore: day),
           let change = MarketStress.change(credit, calendar: calendar, from: i - 5, to: i) {
            widening = change >= 15
        }
        if let i = calendar.lastIndex(onOrBefore: day) {
            qualityWidening = MarketStress.qualityWidening(quality, calendar: calendar, at: i).widening
        }
        return Regime(stressed: stressed, shock: shock, credit: widening, quality: qualityWidening)
    }

    static func summarize(_ returns: [Double], _ periodsPerYear: Double) -> FactorReport.Summary {
        guard returns.count > 2 else { return .init(annReturn: 0, annVol: 0, sharpe: 0, t: 0, hitRate: 0, periods: returns.count) }
        let m = Stats.mean(returns), sd = Stats.stdev(returns)
        let n = Double(returns.count)
        let perPeriod: Double = sd > 0 ? m / sd : 0
        let hits = Double(returns.filter { $0 > 0 }.count)
        return .init(annReturn: m * periodsPerYear, annVol: sd * periodsPerYear.squareRoot(),
                     sharpe: perPeriod * periodsPerYear.squareRoot(), t: perPeriod * n.squareRoot(),
                     hitRate: hits / n, periods: returns.count)
    }
}
