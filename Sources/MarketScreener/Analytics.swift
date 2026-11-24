import Foundation

// MARK: - Basic statistics

enum Stats {
    static func mean<C: Collection>(_ x: C) -> Double where C.Element == Double {
        x.isEmpty ? .nan : x.reduce(0, +) / Double(x.count)
    }

    static func stdev(_ x: [Double]) -> Double {
        guard x.count > 1 else { return 0 }
        let m = mean(x)
        return sqrt(x.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(x.count - 1))
    }

    static func sma(_ c: [Double], period: Int, end: Int) -> Double? {
        guard end + 1 >= period, end < c.count else { return nil }
        return mean(c[(end - period + 1)...end])
    }

    /// Wilder's RSI evaluated at `end`, warmed up over the preceding ~250 bars.
    static func rsi(_ c: [Double], period: Int = 14, end: Int) -> Double? {
        let start = max(1, end - 250)
        guard end - start + 1 >= period * 2 else { return nil }
        var gain = 0.0, loss = 0.0
        for i in start..<(start + period) {
            let d = c[i] - c[i - 1]
            gain += max(d, 0); loss += max(-d, 0)
        }
        gain /= Double(period); loss /= Double(period)
        for i in stride(from: start + period, through: end, by: 1) {
            let d = c[i] - c[i - 1]
            gain = (gain * Double(period - 1) + max(d, 0)) / Double(period)
            loss = (loss * Double(period - 1) + max(-d, 0)) / Double(period)
        }
        guard loss > 0 else { return 100 }
        return 100 - 100 / (1 + gain / loss)
    }

    static func clamp01(_ x: Double) -> Double { min(max(x, 0), 1) }
}

// MARK: - VIX spikes

struct SpikeSettings: Equatable {
    /// Minimum one-day VIX jump (close-to-close, or prior close to intraday high).
    var threshold = 0.15
    /// Ignore jumps that leave VIX below this level (e.g. 12 → 14 isn't stress).
    var minLevel = 18.0
    var useIntradayHigh = true
}

struct SpikeEvent: Identifiable, Hashable, Sendable {
    let day: Int          // first spike session of the cluster
    let close: Double
    let change: Double    // the larger of close-to-close and close-to-high on that day
    let peak: Double      // highest VIX close during the cluster
    let sessions: Int     // spike sessions in the cluster
    let sessionsAgo: Int  // trading sessions between the spike and the latest bar

    var id: Int { day }
}

struct VIXStatus {
    let day: Int
    let level: Double
    let change: Double
    let intradayChange: Double
    let average20: Double
    let percentile1y: Double
    let isSpike: Bool
    let sessionsSinceSpike: Int?
}

enum VIXAnalysis {
    static func spikeIndices(_ bars: [Bar], settings: SpikeSettings) -> [Int] {
        guard bars.count > 1 else { return [] }
        return (1..<bars.count).filter { i in
            let prev = bars[i - 1].close
            let closeMove = bars[i].close / prev - 1
            let highMove = settings.useIntradayHigh ? bars[i].high / prev - 1 : closeMove
            let level = settings.useIntradayHigh ? bars[i].high : bars[i].close
            return max(closeMove, highMove) >= settings.threshold && level >= settings.minLevel
        }
    }

    /// Clusters spike days that are within a few sessions of each other into one event. Newest first.
    static func events(_ bars: [Bar], spikes: [Int], minIndex: Int) -> [SpikeEvent] {
        var events: [SpikeEvent] = []
        var i = 0
        while i < spikes.count {
            var j = i
            while j + 1 < spikes.count, spikes[j + 1] - spikes[j] <= 3 { j += 1 }
            let first = spikes[i]
            if first >= minIndex {
                let lastIdx = min(spikes[j] + 3, bars.count - 1)
                let peak = bars[first...lastIdx].map(\.close).max() ?? bars[first].close
                let prev = bars[first - 1].close
                let change = max(bars[first].close / prev - 1, bars[first].high / prev - 1)
                events.append(SpikeEvent(day: bars[first].day, close: bars[first].close,
                                         change: change, peak: peak, sessions: j - i + 1,
                                         sessionsAgo: bars.count - 1 - first))
            }
            i = j + 1
        }
        return events.reversed()
    }

    static func status(_ bars: [Bar], spikes: [Int]) -> VIXStatus? {
        let n = bars.count
        guard n > 22 else { return nil }
        let c = bars.map(\.close)
        let level = c[n - 1]
        let window = c[max(0, n - 252)..<n]
        let lastSpike = spikes.last
        return VIXStatus(day: bars[n - 1].day,
                         level: level,
                         change: level / c[n - 2] - 1,
                         intradayChange: bars[n - 1].high / c[n - 2] - 1,
                         average20: Stats.mean(c[(n - 21)..<(n - 1)]),
                         percentile1y: Double(window.filter { $0 <= level }.count) / Double(window.count),
                         isSpike: lastSpike == n - 1,
                         sessionsSinceSpike: lastSpike.map { n - 1 - $0 })
    }
}


// MARK: - Forced-selling gauges

/// Market-wide signs that selling is mechanical de-risking rather than stock-specific.
struct MarketGauges {
    var correlation: Double?        // average pairwise correlation, 20 sessions to the period end
    var correlationMedian: Double?  // its 1-year median, for reference
    var momentumSpread: Double?     // momentum leaders' move minus laggards' move over the period
    var vixTerm: Double?            // VIX / VIX3M at the period end (> 1 = inverted, acute stress)
    var vixTermPeak: Double?        // highest VIX / VIX3M inside the period
    var creditChange: Double?       // implied high-yield spread change over the period, in bp
    var qualityChange: Double?      // BBB − AAA quality spread, 20-session change, in bp
    var qualityWidening = false     // that change is unusually large for the past year
}

enum MarketStress {
    /// Average pairwise correlation of daily returns over a rolling window, for each day of
    /// `calendar`. Uses the implied-correlation identity on an equal-weight portfolio, so it is
    /// O(stocks × days) instead of O(stocks² × days). Only pass same-session stocks.
    static func correlationSeries(_ series: [PriceSeries], calendar: [Bar], window: Int = 20, days: Int = 800) -> [Int: Double] {
        let returns: [[Int: Double]] = series.map { s in
            var m = [Int: Double](minimumCapacity: s.bars.count)
            for i in 1..<max(s.bars.count, 1) { m[s.bars[i].day] = s.bars[i].close / s.bars[i - 1].close - 1 }
            return m
        }
        let dayList = calendar.suffix(days + window).map(\.day)
        guard dayList.count > window else { return [:] }
        var out: [Int: Double] = [:]
        for k in window..<dayList.count {
            let span = dayList[(k - window + 1)...k]
            var matrix: [[Double]] = []
            for m in returns {
                var r: [Double] = []
                r.reserveCapacity(window)
                for d in span { guard let x = m[d] else { break }; r.append(x) }
                if r.count == window { matrix.append(r) }
            }
            guard matrix.count >= 10 else { continue }
            let n = Double(matrix.count)
            var portfolio = [Double](repeating: 0, count: window)
            for r in matrix { for t in 0..<window { portfolio[t] += r[t] / n } }
            let sigmas = matrix.map { Stats.stdev($0) }
            let ownVariance = sigmas.reduce(0) { $0 + $1 * $1 } / (n * n)
            let crossTerms = pow(sigmas.reduce(0, +) / n, 2) - ownVariance
            guard crossTerms > 0 else { continue }
            out[dayList[k]] = (pow(Stats.stdev(portfolio), 2) - ownVariance) / crossTerms
        }
        return out
    }

    /// Implied high-yield spread by day, in basis points relative to the start of the data.
    /// HYG's return over IEI (3–7y Treasuries, similar duration) strips out rates; dividing the
    /// cumulative excess return by HYG's duration (~3.5) converts it into a spread move.
    static func creditSpreadIndex(highYield: [Bar], treasury: [Bar], duration: Double = 3.5) -> [Int: Double] {
        var treasuryByDay: [Int: Double] = [:]
        for b in treasury { treasuryByDay[b.day] = b.close }
        var out: [Int: Double] = [:]
        var cumulative = 0.0
        var previous: (hy: Double, tsy: Double)?
        for b in highYield {
            guard let t = treasuryByDay[b.day] else { continue }
            if let p = previous { cumulative += log(b.close / p.hy) - log(t / p.tsy) }
            previous = (b.close, t)
            out[b.day] = -cumulative / duration * 10_000
        }
        return out
    }

    /// Quality-spread proxy in bp: LQD (investment grade, about half BBB) against QLTA (Aaa–A).
    /// Yield moves are −return ÷ duration; since LQD is roughly half BBB, the BBB premium over
    /// high grade moves about twice their yield gap.
    static func qualitySpreadProxy(investmentGrade: [Bar], highGrade: [Bar],
                                   igDuration: Double = 8.3, hgDuration: Double = 7.0) -> [Int: Double] {
        var hgByDay: [Int: Double] = [:]
        for b in highGrade { hgByDay[b.day] = b.close }
        var out: [Int: Double] = [:]
        var cumulative = 0.0
        var previous: (ig: Double, hg: Double)?
        for b in investmentGrade {
            guard let h = hgByDay[b.day] else { continue }
            if let p = previous {
                let igYield = -log(b.close / p.ig) / igDuration, hgYield = -log(h / p.hg) / hgDuration
                cumulative += 2 * (igYield - hgYield)
            }
            previous = (b.close, h)
            out[b.day] = cumulative * 10_000
        }
        return out
    }

    /// Is the quality spread widening unusually fast? Its 20-session change against the spread of
    /// such changes over the past year (scale-free, so it works for FRED levels and the proxy alike).
    static func qualityWidening(_ index: [Int: Double], calendar: [Bar], at i: Int) -> (change: Double?, widening: Bool) {
        let now = change(index, calendar: calendar, from: i - 20, to: i)
        guard let now, i >= 272 else { return (now, false) }
        var history: [Double] = []
        var k = i - 20
        while k >= i - 252 {
            if let c = change(index, calendar: calendar, from: k - 20, to: k) { history.append(c) }
            k -= 5
        }
        let sd = Stats.stdev(history)
        return (now, sd > 0 && now > 1.5 * sd)
    }

    /// Spread change between two days, using the nearest earlier observation for each.
    static func change(_ index: [Int: Double], calendar: [Bar], from a: Int, to b: Int) -> Double? {
        func value(at i: Int) -> Double? {
            var k = i
            while k >= 0 && k > i - 5 { if let v = index[calendar[k].day] { return v }; k -= 1 }
            return nil
        }
        guard a >= 0, b < calendar.count, let va = value(at: a), let vb = value(at: b) else { return nil }
        return vb - va
    }

    /// VIX / VIX3M by day.
    static func termRatio(vix: [Bar], vix3m: [Bar]) -> [Int: Double] {
        var long: [Int: Double] = [:]
        for b in vix3m { long[b.day] = b.close }
        var out: [Int: Double] = [:]
        for b in vix { if let l = long[b.day], l > 0 { out[b.day] = b.close / l } }
        return out
    }
}
