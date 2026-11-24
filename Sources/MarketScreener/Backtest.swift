import Foundation

/// Replays the screen at every past VIX spike and measures what the picks did afterwards.
///
/// Known biases, shown in the UI: the universe is today's list (survivorship), fundamentals are
/// today's figures (look-ahead in the quality part), and headlines aren't available historically
/// (the news part is neutral for every stock).
struct BacktestReport: Sendable {
    struct Horizon: Hashable, Identifiable {
        let sessions: Int
        let label: String
        var id: Int { sessions }
    }

    static let horizons = [Horizon(sessions: 5, label: "1W"), Horizon(sessions: 21, label: "1M"), Horizon(sessions: 63, label: "3M")]
    static let strategies = ["Thesis matches", "Top 10 score", "All stocks", "Bottom 10 score"]
    /// Long/short spreads: the selection's edge over the same (survivorship-biased) universe.
    static let spreads = ["Top 10 − Bottom 10", "Thesis − All"]

    struct Stat {
        var meanReturn: Double
        var meanExcess: Double
        var hitRate: Double   // share of events beating the benchmark
        var events: Int
        var meanAlpha = 0.0   // return − β × benchmark (β of the members, estimated before the spike)
        var tExcess = 0.0     // t-statistic of the mean excess across spikes
        var tAlpha = 0.0
    }

    struct EventRow: Identifiable {
        let event: SpikeEvent
        let termPeak: Double?
        let correlation: Double?
        let creditChange: Double?   // implied HY spread move from a week before the spike to the window end, bp
        let qualityWidening: Bool?  // BBB − AAA spread widening unusually fast at the window end
        let picks: [String]
        /// strategy → horizon sessions → equal-weight average forward return
        let returns: [String: [Int: Double]]
        let benchmark: [Int: Double]
        /// strategy → average beta of its members
        let betas: [String: Double]
        var id: Int { event.day }
    }

    struct Factor: Identifiable {
        let name: String
        /// horizon sessions → (mean rank IC, t-stat, events)
        let ic: [Int: (mean: Double, t: Double, n: Int)]
        var id: String { name }
    }

    struct Split: Identifiable {
        let condition: String
        let events: Int
        let thesisExcess: Double?
        let topExcess: Double?
        var id: String { condition }
    }

    var universe: String
    var window: Int
    var withoutFundamentals = false
    var rows: [EventRow]
    var stats: [String: [Int: Stat]]
    /// Same, using only spikes at least one holding period apart, so no two spikes share returns.
    var independentStats: [String: [Int: Stat]]
    var factors: [Factor]
    var splits: [Split]
}

enum Backtest {
    static func run(_ base: Screener.Inputs, universe: String, events: [SpikeEvent], window: Int,
                    termRatio: [Int: Double], correlation: [Int: Double], correlationMedian: Double?,
                    credit: [Int: Double] = [:], quality: [Int: Double] = [:]) -> BacktestReport {
        let benchBars = base.benchmark?.bars ?? []
        var rows: [BacktestReport.EventRow] = []
        var factorICs: [String: [Int: [Double]]] = [:]
        let factors: [(String, (StockMetrics) -> Double?)] = [
            ("Drop size (−z)", { -$0.zScore }),
            ("Momentum 12-1", { $0.momentum12_1 }),
            ("Quality rank", { $0.instrument.isFund ? nil : $0.qualityRank }),
            ("Volume surge", { $0.volumeRatio }),
            ("Oversold (−RSI)", { -$0.rsi }),
            ("Total score", { $0.score.total }),
        ]

        for event in events.reversed() {   // oldest first
            var input = base
            input.news = [:]
            input.period = .reaction(spikeDay: event.day, sessions: window)
            let metrics = Screener.run(input)
            guard metrics.count >= 10 else { continue }

            // Forward returns from each stock's own window end.
            var forward: [String: [Int: Double]] = [:]
            for m in metrics {
                guard let bars = base.series[m.symbol]?.bars,
                      let (_, end) = Screener.bounds(input.period, bars: bars, session: m.instrument.session) else { continue }
                for h in BacktestReport.horizons where end + h.sessions < bars.count {
                    forward[m.symbol, default: [:]][h.sessions] = bars[end + h.sessions].close / bars[end].close - 1
                }
            }
            var bench: [Int: Double] = [:]
            if let (_, end) = Screener.bounds(input.period, bars: benchBars) {
                for h in BacktestReport.horizons where end + h.sessions < benchBars.count {
                    bench[h.sessions] = benchBars[end + h.sessions].close / benchBars[end].close - 1
                }
            }
            guard !bench.isEmpty else { continue }   // too recent to evaluate

            let byScore = metrics.sorted { $0.score.total > $1.score.total }
            let picks = metrics.filter { $0.isMomentumLeader && $0.zScore <= -1.5 }
            let groups: [String: [StockMetrics]] = [
                "Thesis matches": picks,
                "Top 10 score": Array(byScore.prefix(10)),
                "All stocks": metrics,
                "Bottom 10 score": Array(byScore.suffix(10)),
            ]
            var returns: [String: [Int: Double]] = [:]
            var betas: [String: Double] = [:]
            for (name, members) in groups {
                if !members.isEmpty { betas[name] = Stats.mean(members.map(\.beta)) }
                for h in BacktestReport.horizons {
                    let r = members.compactMap { forward[$0.symbol]?[h.sessions] }
                    if !r.isEmpty { returns[name, default: [:]][h.sessions] = Stats.mean(r) }
                }
            }
            for (spread, long, short) in [("Top 10 − Bottom 10", "Top 10 score", "Bottom 10 score"), ("Thesis − All", "Thesis matches", "All stocks")] {
                if let bl = betas[long], let bs = betas[short] { betas[spread] = bl - bs }
                for h in BacktestReport.horizons {
                    if let l = returns[long]?[h.sessions], let s = returns[short]?[h.sessions] { returns[spread, default: [:]][h.sessions] = l - s }
                }
            }

            for (name, value) in factors {
                for h in BacktestReport.horizons {
                    let pairs = metrics.compactMap { m -> (Double, Double)? in
                        guard let x = value(m), let y = forward[m.symbol]?[h.sessions] else { return nil }
                        return (x, y)
                    }
                    if pairs.count >= 10, let ic = spearman(pairs) { factorICs[name, default: [:]][h.sessions, default: []].append(ic) }
                }
            }

            let span = window + 3
            let termDays = termRatio.filter { $0.key >= event.day }.sorted { $0.key < $1.key }.prefix(span)
            let reactionBounds = Screener.bounds(input.period, bars: benchBars)
            let reactionEnd = reactionBounds.map { benchBars[$0.end].day }
            let creditChange = reactionBounds.flatMap { MarketStress.change(credit, calendar: benchBars, from: $0.start - 5, to: $0.end) }
            rows.append(.init(event: event,
                              termPeak: termDays.map(\.value).max(),
                              correlation: reactionEnd.flatMap { correlation[$0] },
                              creditChange: creditChange,
                              qualityWidening: quality.isEmpty ? nil : reactionBounds.map { MarketStress.qualityWidening(quality, calendar: benchBars, at: $0.end).widening },
                              picks: picks.sorted { $0.score.total > $1.score.total }.map(\.symbol),
                              returns: returns, benchmark: bench, betas: betas))
        }

        // Summary per strategy and horizon, over all spikes and over non-overlapping ones.
        var stats: [String: [Int: BacktestReport.Stat]] = [:]
        var independentStats: [String: [Int: BacktestReport.Stat]] = [:]
        for h in BacktestReport.horizons {
            let spaced = spacedOut(rows, minDays: Double(h.sessions) * 7 / 5)
            for name in BacktestReport.strategies + BacktestReport.spreads {
                if let s = summarize(rows, name, h.sessions) { stats[name, default: [:]][h.sessions] = s }
                if let s = summarize(spaced, name, h.sessions) { independentStats[name, default: [:]][h.sessions] = s }
            }
            for (subset, target) in [(rows, 0), (spaced, 1)] {
                let r = subset.compactMap { $0.benchmark[h.sessions] }
                guard !r.isEmpty else { continue }
                let s = BacktestReport.Stat(meanReturn: Stats.mean(r), meanExcess: 0,
                                            hitRate: Double(r.filter { $0 > 0 }.count) / Double(r.count), events: r.count)
                if target == 0 { stats["Benchmark", default: [:]][h.sessions] = s } else { independentStats["Benchmark", default: [:]][h.sessions] = s }
            }
        }

        let factorRows = factors.map { name, _ in
            BacktestReport.Factor(name: name, ic: (factorICs[name] ?? [:]).mapValues { ics in
                let sd = Stats.stdev(ics)
                return (Stats.mean(ics), sd > 0 ? Stats.mean(ics) / sd * Double(ics.count).squareRoot() : 0, ics.count)
            })
        }

        // Does the thesis work better when the stress gauges flash?
        func split(_ label: String, _ include: (BacktestReport.EventRow) -> Bool) -> BacktestReport.Split {
            let subset = rows.filter(include)
            func excess(_ name: String) -> Double? {
                let e = subset.compactMap { row -> Double? in
                    guard let r = row.returns[name]?[21], let b = row.benchmark[21] else { return nil }
                    return r - b
                }
                return e.isEmpty ? nil : Stats.mean(e)
            }
            return .init(condition: label, events: subset.filter { $0.benchmark[21] != nil }.count,
                         thesisExcess: excess("Thesis matches"), topExcess: excess("Top 10 score"))
        }
        var splits = [
            split("\(VolIndex.current.name) curve inverted") { ($0.termPeak ?? 0) > 1 },
            split("\(VolIndex.current.name) curve normal") { ($0.termPeak ?? 0) <= 1 },
        ]
        if let median = correlationMedian {
            splits.append(split("Correlation above median") { ($0.correlation ?? 0) > median })
            splits.append(split("Correlation below median") { ($0.correlation ?? 1) <= median })
        }
        splits.append(split("Credit spreads widened ≥ 25 bp") { ($0.creditChange ?? 0) >= 25 })
        splits.append(split("Credit spreads calm") { ($0.creditChange ?? 0) < 25 && $0.creditChange != nil })
        splits.append(split("Quality spread widening (credit crisis)") { $0.qualityWidening == true })
        splits.append(split("Quality spread calm (risk-budget selling)") { $0.qualityWidening == false })
        splits.append(split("Spikes before 2020") { $0.event.day < 20200101 })
        splits.append(split("Spikes 2020 and later") { $0.event.day >= 20200101 })
        splits.append(split("\(VolIndex.current.name) jump ≥ 25%") { $0.event.change >= 0.25 })
        splits.append(split("\(VolIndex.current.name) jump < 25%") { $0.event.change < 0.25 })

        return BacktestReport(universe: universe, window: window, rows: rows.reversed(), stats: stats,
                              independentStats: independentStats, factors: factorRows, splits: splits)
    }

    private static func summarize(_ rows: [BacktestReport.EventRow], _ name: String, _ h: Int) -> BacktestReport.Stat? {
        // A spread is already market-neutral in dollars, so its "excess" is the spread itself;
        // its alpha removes the remaining beta difference between the two legs.
        let isSpread = BacktestReport.spreads.contains(name)
        let obs = rows.compactMap { row -> (r: Double, excess: Double, alpha: Double)? in
            guard let r = row.returns[name]?[h], let b = row.benchmark[h] else { return nil }
            return (r, isSpread ? r : r - b, r - (row.betas[name] ?? (isSpread ? 0 : 1)) * b)
        }
        guard !obs.isEmpty else { return nil }
        func t(_ x: [Double]) -> Double {
            let sd = Stats.stdev(x)
            return sd > 0 ? Stats.mean(x) / sd * Double(x.count).squareRoot() : 0
        }
        return .init(meanReturn: Stats.mean(obs.map(\.r)), meanExcess: Stats.mean(obs.map(\.excess)),
                     hitRate: Double(obs.filter { $0.excess > 0 }.count) / Double(obs.count), events: obs.count,
                     meanAlpha: Stats.mean(obs.map(\.alpha)), tExcess: t(obs.map(\.excess)), tAlpha: t(obs.map(\.alpha)))
    }

    /// Oldest-first greedy selection of spikes at least `minDays` calendar days apart.
    private static func spacedOut(_ rows: [BacktestReport.EventRow], minDays: Double) -> [BacktestReport.EventRow] {
        var out: [BacktestReport.EventRow] = []
        var last: Date?
        for row in rows {
            let d = TradingDay.date(row.event.day)
            if last.map({ d.timeIntervalSince($0) >= minDays * 86_400 }) ?? true {
                out.append(row)
                last = d
            }
        }
        return out
    }

    /// Spearman rank correlation.
    static func spearman(_ pairs: [(Double, Double)]) -> Double? {
        func ranks(_ v: [Double]) -> [Double] {
            let order = v.indices.sorted { v[$0] < v[$1] }
            var r = [Double](repeating: 0, count: v.count)
            var i = 0
            while i < order.count {
                var j = i
                while j + 1 < order.count && v[order[j + 1]] == v[order[i]] { j += 1 }
                for k in i...j { r[order[k]] = Double(i + j) / 2 }
                i = j + 1
            }
            return r
        }
        let x = ranks(pairs.map(\.0)), y = ranks(pairs.map(\.1))
        let mx = Stats.mean(x), my = Stats.mean(y)
        var cov = 0.0, vx = 0.0, vy = 0.0
        for i in x.indices {
            cov += (x[i] - mx) * (y[i] - my)
            vx += (x[i] - mx) * (x[i] - mx)
            vy += (y[i] - my) * (y[i] - my)
        }
        guard vx > 0, vy > 0 else { return nil }
        return cov / (vx * vy).squareRoot()
    }
}
