import Foundation

/// Trading costs as a fraction of traded value: a base for commission and spread, plus the
/// transaction taxes that apply on a global stock list.
enum TradingCost {
    static func tax(_ symbol: String, buy: Bool) -> Double {
        guard let dot = symbol.lastIndex(of: ".") else { return 0 }
        switch symbol[symbol.index(after: dot)...] {
        case "L": return buy ? 0.005 : 0           // UK stamp duty
        case "PA": return buy ? 0.004 : 0          // French financial transaction tax
        case "MC": return buy ? 0.002 : 0          // Spanish FTT
        case "MI": return buy ? 0.001 : 0          // Italian FTT
        case "IR": return buy ? 0.01 : 0           // Irish stamp duty
        case "HK": return 0.001                    // Hong Kong stamp duty, both sides
        case "NS", "BO": return 0.001              // Indian securities transaction tax
        case "TW": return buy ? 0 : 0.003          // Taiwan securities transaction tax
        case "KS", "KQ": return buy ? 0 : 0.0015   // Korean securities transaction tax
        case "SS", "SZ": return buy ? 0 : 0.0005   // Chinese stamp duty on sales
        default: return 0
        }
    }

    static func hasTax(_ symbol: String) -> Bool { tax(symbol, buy: true) + tax(symbol, buy: false) > 0 }
}

/// How eagerly the sleeve trades. Weekly rebuilds an equal-weight top list every week; the
/// low-turnover policies only sell names that fall well out of the ranks, let weights drift,
/// hold names a minimum time and keep the gate open a few weeks after stress fades.
struct TurnoverPolicy: Sendable, Equatable {
    var exitRankMultiple: Double?   // nil = rebuild every week; else sell only beyond cut × this rank
    var minHoldWeeks = 0
    var reviewEveryWeeks = 1
    var stickyWeeks = 0             // gate stays open this long after the last stress signal

    static let weekly = TurnoverPolicy()
    static let buffer = TurnoverPolicy(exitRankMultiple: 3)
    static let bufferHold = TurnoverPolicy(exitRankMultiple: 3, minHoldWeeks: 4, stickyWeeks: 4)
    static let monthly = TurnoverPolicy(exitRankMultiple: 3, minHoldWeeks: 4, reviewEveryWeeks: 4, stickyWeeks: 4)
}

struct StrategyConfig: Sendable, Identifiable {
    enum Gate: Sendable { case never, broad, acute, always, riskBudget, creditCrisis }
    enum Sleeve: Sendable { case factorLongs, allLeaders }

    let name: String
    let note: String
    let gate: Gate
    let sleeve: Sleeve
    let tilt: Double
    let excludeTaxed: Bool
    /// Tilt to use instead while the BBB − AAA quality spread is widening (credit crisis).
    var crisisTilt: Double? = nil
    var turnover: TurnoverPolicy = .weekly
    var id: String { name }
}

struct StrategyReport: Sendable {
    struct Result: Identifiable, Sendable {
        let config: StrategyConfig
        let cagr: Double
        let vol: Double
        let sharpe: Double
        let maxDrawdown: Double
        let excessCAGR: Double     // vs. the index
        let infoRatio: Double
        let tExcess: Double
        let tiltedShare: Double    // share of weeks with the gate open
        let excessWhenTilted: Double  // annualised excess during gate-open weeks
        let costPerYear: Double
        var id: String { config.name }
    }

    struct CurvePoint: Sendable {
        let day: Int
        let strategy: Double   // growth of 1
        let index: Double
        let control: Double
        let tilted: Bool
    }

    struct Position: Identifiable, Sendable {
        let instrument: Instrument
        let rank: Int
        let weight: Double         // model weight; 0 for names on deck beyond the model's cut
        let move: Double           // last 5 sessions
        let z: Double
        let volShock: Double
        let momentumRank: Double
        let signal: Double
        var id: String { instrument.symbol }
    }

    /// What the gate looks at, as of the latest close.
    struct Readings: Sendable {
        let vix: Double?
        let vixMedian: Double?
        let vixWeekChange: Double?
        let creditWeek: Double?
        let stressed: Bool
        let shock: Bool
        let creditWidening: Bool
        let qualityChange: Double?   // BBB − AAA, 20-session change, bp
        let qualityWidening: Bool
    }

    let universe: String
    let benchmarkName: String
    let baseBps: Double
    let results: [Result]
    let tilts: [Result]        // the main strategy at 25 / 50 / 100% tilt
    let curve: [CurvePoint]    // weekly main strategy vs. index vs. control
    let monthlyCurve: [CurvePoint]   // low-turnover monthly strategy vs. index vs. its monthly control
    let gateOpen: Bool
    let readings: Readings
    let indexWeight: Double
    let positions: [Position]  // today's sleeve (or what it would hold if the gate opened)
    let onDeck: [Position]     // the next names by signal, to watch
    let tilt: Double
    let ranking: [String]      // today's momentum leaders by signal, best first (for buffer rules)
    let cut: Int               // names in the model
    let allRanked: [Position]  // every momentum leader, ranked (weights only on the top cut)
}

enum SwitchingStrategy {
    static let mainTilt = 0.5
    static let maxNames = 25
    static let acuteHoldWeeks = 4

    static func configs(_ benchmark: String) -> [StrategyConfig] {
        [
            .init(name: "Index only", note: "Buy and hold \(benchmark)", gate: .never, sleeve: .factorLongs, tilt: 0, excludeTaxed: false),
            .init(name: "Switch 50%, broad gate", note: "Tilt half into factor longs while \(VolIndex.current.name) is above its 1-year median or credit spreads widen",
                  gate: .broad, sleeve: .factorLongs, tilt: 0.5, excludeTaxed: false),
            .init(name: "Switch 50%, acute gate", note: "Tilt half for 4 weeks after a \(VolIndex.current.name) shock (+20% in a week) or credit widening",
                  gate: .acute, sleeve: .factorLongs, tilt: 0.5, excludeTaxed: false),
            .init(name: "Switch 50%, 100% in credit crises", note: "Broad gate at 50%, scaled up to 100% while the BBB − AAA quality spread widens",
                  gate: .broad, sleeve: .factorLongs, tilt: 0.5, excludeTaxed: false, crisisTilt: 1.0),
            .init(name: "Switch 50%, risk-budget only", note: "Broad gate, but only while the BBB − AAA quality spread is calm",
                  gate: .riskBudget, sleeve: .factorLongs, tilt: 0.5, excludeTaxed: false),
            .init(name: "Switch 50%, credit crises only", note: "Tilt only while the BBB − AAA quality spread is widening",
                  gate: .creditCrisis, sleeve: .factorLongs, tilt: 0.5, excludeTaxed: false),
            .init(name: "Low turnover: buffer", note: "Broad gate; buy the top ranks but sell only names that fall below 3× the cut; weights drift",
                  gate: .broad, sleeve: .factorLongs, tilt: 0.5, excludeTaxed: false, turnover: .buffer),
            .init(name: "Low turnover: buffer, 4-week hold, sticky gate", note: "Also hold each name ≥ 4 weeks and keep the gate open 4 weeks after stress fades",
                  gate: .broad, sleeve: .factorLongs, tilt: 0.5, excludeTaxed: false, turnover: .bufferHold),
            .init(name: "Low turnover: monthly review", note: "Same rules, but the sleeve is only reviewed every 4 weeks",
                  gate: .broad, sleeve: .factorLongs, tilt: 0.5, excludeTaxed: false, turnover: .monthly),
            .init(name: "Low turnover monthly, 100% in crises", note: "Monthly review, tilt scaled to 100% while BBB − AAA widens",
                  gate: .broad, sleeve: .factorLongs, tilt: 0.5, excludeTaxed: false, crisisTilt: 1.0, turnover: .monthly),
            .init(name: "Switch 50%, broad, no stamp-duty markets", note: "Same as broad, skipping UK, Ireland, France, Spain, Italy, HK, India, Taiwan, Korea, China",
                  gate: .broad, sleeve: .factorLongs, tilt: 0.5, excludeTaxed: true),
            .init(name: "Control, monthly: all momentum leaders", note: "Monthly review and sticky gate, but buys every momentum leader: the fair yardstick for the low-turnover picks",
                  gate: .broad, sleeve: .allLeaders, tilt: 0.5, excludeTaxed: false, turnover: .monthly),
            .init(name: "Control: 50% into all momentum leaders", note: "Same switching, but buys every momentum leader: isolates the factor's picks",
                  gate: .broad, sleeve: .allLeaders, tilt: 0.5, excludeTaxed: false),
            .init(name: "Always 50% in factor longs", note: "No gate: shows what switching saves",
                  gate: .always, sleeve: .factorLongs, tilt: 0.5, excludeTaxed: false),
        ]
    }

    private struct Row {
        let symbol: String
        let features: RiskBudgetFactor.Features
        let forward: Double
    }

    private struct Book {
        var names: [String: Double] = [:]   // symbol → weight
        var indexWeight = 1.0
    }

    /// Week-by-week paths for a set of configs. Costs are kept apart from returns (they don't
    /// change what is held), so any cost level can be applied afterwards.
    struct Simulation: Sendable {
        var days: [Int] = []
        var indexReturns: [Double] = []
        var gross: [[Double]]      // per config, before costs
        var traded: [[Double]]     // value traded each week, as a share of the portfolio
        var taxes: [[Double]]      // transaction taxes paid each week
        var tilted: [[Bool]]
        let hold: Int

        init(count: Int, hold: Int) {
            gross = Array(repeating: [], count: count)
            traded = gross
            taxes = gross
            tilted = Array(repeating: [], count: count)
            self.hold = hold
        }

        var periodsPerYear: Double { 252.0 / Double(hold) }
        var years: Double { Double(indexReturns.count) / periodsPerYear }

        func net(_ i: Int, bps: Double) -> [Double] {
            let base = bps / 10_000
            return gross[i].indices.map { gross[i][$0] - traded[i][$0] * base - taxes[i][$0] }
        }

        func costPerYear(_ i: Int, bps: Double) -> Double {
            years > 0 ? (traded[i].reduce(0, +) * bps / 10_000 + taxes[i].reduce(0, +)) / years : 0
        }

        func cagr(_ r: [Double]) -> Double {
            guard !r.isEmpty else { return 0 }
            let logGrowth = r.reduce(0) { $0 + log(1 + $1) }
            return exp(logGrowth * periodsPerYear / Double(r.count)) - 1
        }

        /// t-stat of the mean weekly difference between two return paths.
        func tStat(_ a: [Double], over b: [Double]) -> Double {
            let d = zip(a, b).map { $0 - $1 }
            let sd = Stats.stdev(d)
            return sd > 0 ? Stats.mean(d) / sd * Double(d.count).squareRoot() : 0
        }
    }

    static func simulate(_ all: [StrategyConfig], prepared: [RiskBudgetFactor.Prepared], benchmark: PriceSeries,
                         vix: [Bar], credit: [Int: Double], quality: [Int: Double]) -> Simulation {
        let spec = RiskBudgetFactor.specs[1]   // weekly, momentum leaders
        let calendar = benchmark.bars, bench = benchmark.closes
        let vixCloses = vix.map(\.close)
        let hold = spec.hold
        let needsUntaxed = all.contains(where: \.excludeTaxed)

        var sim = Simulation(count: all.count, hold: hold)
        var books = Array(repeating: Book(), count: all.count)
        var held = Array(repeating: [String: Int](), count: all.count)   // weeks each name has been held
        var stickyLeft = Array(repeating: 0, count: all.count)
        var lastTilt = Array(repeating: 0.0, count: all.count)
        var acuteCountdown = 0

        for k in stride(from: 300, to: calendar.count - hold, by: hold) {
            let day = calendar[k].day
            let date = TradingDay.date(day)
            let regime = RiskBudgetFactor.regime(day, vix: vix, vixCloses: vixCloses, calendar: calendar, credit: credit, quality: quality)
            if regime.shock || regime.credit { acuteCountdown = acuteHoldWeeks }

            var rows: [Row] = []
            for p in prepared {
                guard let e = p.bars.lastIndex(onOrBefore: day), e + hold < p.closes.count,
                      date.timeIntervalSince(p.bars[e].date) < 6 * 86_400,
                      let f = p.features(at: e, spec) else { continue }
                rows.append(Row(symbol: p.instrument.symbol, features: f, forward: p.closes[e + hold] / p.closes[e] - 1))
            }
            guard rows.count >= 25 else { continue }
            let momenta = rows.map(\.features.momentum).sorted()
            let leaders = rows.filter { $0.features.momentum >= momenta[momenta.count / 2] }
            let forward = Dictionary(uniqueKeysWithValues: rows.map { ($0.symbol, $0.forward) })
            let indexReturn = bench[k + hold] / bench[k] - 1
            sim.indexReturns.append(indexReturn)
            sim.days.append(day)

            // Rank once per week; every config reads the same list.
            let rankedAll = leaders.map { ($0.symbol, $0.features.signal(spec)) }.sorted { $0.1 > $1.1 }.map(\.0)
            let rankedUntaxed = needsUntaxed ? rankedAll.filter { !TradingCost.hasTax($0) } : []

            let period = sim.days.count - 1
            for (i, config) in all.enumerated() {
                let rawOpen: Bool = switch config.gate {
                case .never: false
                case .always: true
                case .broad: regime.stressed || regime.credit
                case .acute: acuteCountdown > 0
                case .riskBudget: regime.riskBudget
                case .creditCrisis: regime.quality
                }
                var open = rawOpen
                if config.turnover.stickyWeeks > 0 {
                    if rawOpen { stickyLeft[i] = config.turnover.stickyWeeks } else if stickyLeft[i] > 0 { stickyLeft[i] -= 1; open = true }
                }
                var book = Book()
                let tilt = regime.quality ? (config.crisisTilt ?? config.tilt) : config.tilt
                if open && tilt > 0 {
                    let ranked = config.excludeTaxed ? rankedUntaxed : rankedAll
                    let cut = min(max(ranked.count / 5, 3), maxNames)
                    if config.sleeve == .factorLongs, let multiple = config.turnover.exitRankMultiple {
                        book = bufferedBook(current: books[i], ranked: ranked, cut: cut, multiple: multiple, tilt: tilt,
                                            previousTilt: lastTilt[i], held: held[i], minHold: config.turnover.minHoldWeeks,
                                            review: period % config.turnover.reviewEveryWeeks == 0, tradable: forward)
                    } else if config.sleeve == .allLeaders, config.turnover.reviewEveryWeeks > 1,
                              !books[i].names.isEmpty, period % config.turnover.reviewEveryWeeks != 0 {
                        book = books[i]   // between reviews: hold and let weights drift
                    } else {
                        let chosen = config.sleeve == .allLeaders ? ranked : Array(ranked.prefix(cut))
                        if !chosen.isEmpty {
                            book.indexWeight = 1 - tilt
                            for symbol in chosen { book.names[symbol] = tilt / Double(chosen.count) }
                        }
                    }
                }
                lastTilt[i] = book.names.isEmpty ? 0 : tilt
                var nowHeld: [String: Int] = [:]
                for symbol in book.names.keys { nowHeld[symbol] = (held[i][symbol] ?? 0) + 1 }
                held[i] = nowHeld

                // What moving from last week's book to this one trades, and the taxes on it.
                let old = books[i]
                var traded = abs(book.indexWeight - old.indexWeight), tax = 0.0
                for symbol in Set(old.names.keys).union(book.names.keys) {
                    let delta = (book.names[symbol] ?? 0) - (old.names[symbol] ?? 0)
                    guard abs(delta) > 1e-9 else { continue }
                    traded += abs(delta)
                    tax += abs(delta) * TradingCost.tax(symbol, buy: delta > 0)
                }
                var r = book.indexWeight * indexReturn
                for (symbol, w) in book.names { r += w * (forward[symbol] ?? indexReturn) }
                sim.gross[i].append(r)
                sim.traded[i].append(traded)
                sim.taxes[i].append(tax)
                sim.tilted[i].append(!book.names.isEmpty)
                // Let weights drift with the week's returns so next week's trades are realistic.
                var drifted = Book()
                let growth = 1 + r
                drifted.indexWeight = book.indexWeight * (1 + indexReturn) / growth
                for (symbol, w) in book.names { drifted.names[symbol] = w * (1 + (forward[symbol] ?? indexReturn)) / growth }
                books[i] = drifted
            }
            if acuteCountdown > 0 { acuteCountdown -= 1 }
        }
        return sim
    }

    static func run(universe: [Instrument], series: [String: PriceSeries], benchmark: PriceSeries,
                    vix: [Bar], credit: [Int: Double], quality: [Int: Double] = [:], title: String, benchmarkName: String,
                    baseBps: Double = 5) -> StrategyReport {
        let spec = RiskBudgetFactor.specs[1]   // weekly, momentum leaders
        let prepared = universe.compactMap { inst in series[inst.symbol].map { RiskBudgetFactor.Prepared(inst, $0) } }
        let calendar = benchmark.bars
        let vixCloses = vix.map(\.close)

        let mainConfigs = configs(benchmarkName)
        let tiltVariants = [0.25, 0.5, 1.0].map { t in
            StrategyConfig(name: "Switch \(Int(t * 100))%, broad gate", note: "", gate: .broad, sleeve: .factorLongs, tilt: t, excludeTaxed: false)
        }
        let all = mainConfigs + tiltVariants.filter { $0.tilt != 0.5 }
        let sim = simulate(all, prepared: prepared, benchmark: benchmark, vix: vix, credit: credit, quality: quality)
        let returns = all.indices.map { sim.net($0, bps: baseBps) }
        let indexReturns = sim.indexReturns, days = sim.days, tilted = sim.tilted
        let periodsPerYear = sim.periodsPerYear

        func maxDrawdown(_ r: [Double]) -> Double {
            var peak = 1.0, value = 1.0, worst = 0.0
            for x in r { value *= 1 + x; peak = max(peak, value); worst = min(worst, value / peak - 1) }
            return worst
        }
        let indexCAGR = sim.cagr(indexReturns)

        func result(_ i: Int) -> StrategyReport.Result {
            let r = returns[i]
            let excess = zip(r, indexReturns).map { $0 - $1 }
            let sd = Stats.stdev(r), sdE = Stats.stdev(excess)
            let tiltedExcess = zip(excess, tilted[i]).filter(\.1).map(\.0)
            return .init(config: all[i], cagr: sim.cagr(r), vol: sd * periodsPerYear.squareRoot(),
                         sharpe: sd > 0 ? Stats.mean(r) / sd * periodsPerYear.squareRoot() : 0,
                         maxDrawdown: maxDrawdown(r), excessCAGR: sim.cagr(r) - indexCAGR,
                         infoRatio: sdE > 0 ? Stats.mean(excess) / sdE * periodsPerYear.squareRoot() : 0,
                         tExcess: sim.tStat(r, over: indexReturns),
                         tiltedShare: Double(tilted[i].filter { $0 }.count) / Double(max(tilted[i].count, 1)),
                         excessWhenTilted: tiltedExcess.isEmpty ? 0 : Stats.mean(tiltedExcess) * periodsPerYear,
                         costPerYear: sim.costPerYear(i, bps: baseBps))
        }

        let results = mainConfigs.indices.map(result)
        let tiltResults = [0.25, 0.5, 1.0].compactMap { t -> StrategyReport.Result? in
            guard let i = all.firstIndex(where: { $0.gate == .broad && $0.sleeve == .factorLongs && !$0.excludeTaxed && $0.tilt == t }) else { return nil }
            return result(i)
        }

        // Growth-of-1 curves: strategy vs. index vs. its control, for the weekly and monthly policies.
        func curve(_ main: Int, _ control: Int) -> [StrategyReport.CurvePoint] {
            var out: [StrategyReport.CurvePoint] = []
            var s = 1.0, x = 1.0, c = 1.0
            for (j, day) in days.enumerated() {
                s *= 1 + returns[main][j]; x *= 1 + indexReturns[j]; c *= 1 + returns[control][j]
                out.append(.init(day: day, strategy: s, index: x, control: c, tilted: tilted[main][j]))
            }
            return out
        }
        let weeklyControl = mainConfigs.firstIndex { $0.sleeve == .allLeaders && $0.turnover == .weekly } ?? 1
        let monthlyMain = mainConfigs.firstIndex { $0.name == "Low turnover: monthly review" } ?? 1
        let monthlyControl = mainConfigs.firstIndex { $0.sleeve == .allLeaders && $0.turnover == .monthly } ?? weeklyControl

        // Today: the ranking as of the latest close.
        let todayRegime = calendar.last.map {
            RiskBudgetFactor.regime($0.day, vix: vix, vixCloses: vixCloses, calendar: calendar, credit: credit, quality: quality)
        }
        let gateOpen = todayRegime.map { $0.stressed || $0.credit } ?? false
        let latest = prepared.compactMap { p in p.features(at: p.closes.count - 1, spec).map { (p.instrument, $0) } }
        let latestMomenta = latest.map(\.1.momentum).sorted()
        let latestLeaders = latest.filter { !latestMomenta.isEmpty && $0.1.momentum >= latestMomenta[latestMomenta.count / 2] }
        let ranked = latestLeaders.sorted { $0.1.signal(spec) > $1.1.signal(spec) }
        let cut = min(max(latestLeaders.count / 5, 3), maxNames)
        let momentumRank = { (m: Double) in
            Double(latestMomenta.firstIndex { $0 >= m } ?? 0) / Double(max(latestMomenta.count - 1, 1))
        }
        let candidates = ranked.enumerated().map { i, item in
            StrategyReport.Position(instrument: item.0, rank: i + 1, weight: i < cut ? mainTilt / Double(cut) : 0,
                                    move: item.1.move, z: item.1.z, volShock: item.1.shock,
                                    momentumRank: momentumRank(item.1.momentum), signal: item.1.signal(spec))
        }

        let vixNow = vixCloses.last
        let vixYear = vixCloses.suffix(252).sorted()
        let readings = StrategyReport.Readings(
            vix: vixNow,
            vixMedian: vixYear.isEmpty ? nil : vixYear[vixYear.count / 2],
            vixWeekChange: vixCloses.count > 5 ? vixCloses[vixCloses.count - 1] / vixCloses[vixCloses.count - 6] - 1 : nil,
            creditWeek: MarketStress.change(credit, calendar: calendar, from: calendar.count - 6, to: calendar.count - 1),
            stressed: todayRegime?.stressed ?? false, shock: todayRegime?.shock ?? false,
            creditWidening: todayRegime?.credit ?? false,
            qualityChange: MarketStress.qualityWidening(quality, calendar: calendar, at: calendar.count - 1).change,
            qualityWidening: todayRegime?.quality ?? false)

        return StrategyReport(universe: title, benchmarkName: benchmarkName, baseBps: baseBps,
                              results: results, tilts: tiltResults, curve: curve(1, weeklyControl),
                              monthlyCurve: curve(monthlyMain, monthlyControl), gateOpen: gateOpen,
                              readings: readings, indexWeight: gateOpen ? 1 - mainTilt : 1,
                              positions: candidates.filter { $0.weight > 0 },
                              onDeck: Array(candidates.filter { $0.weight == 0 }.prefix(12)),
                              tilt: mainTilt, ranking: ranked.map(\.0.symbol), cut: cut, allRanked: candidates)
    }

    /// Low-turnover rebalance: keep held names unless they fall below `cut × multiple` in rank
    /// (or have no data), respect a minimum holding time, refill freed weight with the best
    /// new names, and otherwise let weights drift.
    private static func bufferedBook(current: Book, ranked: [String], cut: Int, multiple: Double, tilt: Double,
                                     previousTilt: Double, held: [String: Int], minHold: Int, review: Bool,
                                     tradable: [String: Double]) -> Book {
        if current.names.isEmpty {
            var fresh = Book()
            let chosen = ranked.prefix(cut)
            guard !chosen.isEmpty else { return fresh }
            fresh.indexWeight = 1 - tilt
            for symbol in chosen { fresh.names[symbol] = tilt / Double(chosen.count) }
            return fresh
        }
        var book = current
        if review {
            let rank = Dictionary(uniqueKeysWithValues: ranked.enumerated().map { ($1, $0 + 1) })
            let exitRank = Int((Double(cut) * multiple).rounded())
            var keep: [String: Double] = [:]
            var freed = 0.0
            for (symbol, w) in current.names {
                let inBand = rank[symbol].map { $0 <= exitRank } ?? false
                let tooSoon = (held[symbol] ?? 0) < minHold && tradable[symbol] != nil
                if inBand || tooSoon { keep[symbol] = w } else { freed += w }
            }
            let newcomers = ranked.filter { keep[$0] == nil }.prefix(max(cut - keep.count, 0))
            book.names = keep
            if newcomers.isEmpty {
                book.indexWeight += freed
            } else {
                for symbol in newcomers { book.names[symbol] = freed / Double(newcomers.count) }
            }
        }
        // A changed target tilt (e.g. a credit crisis starting or ending) rescales the sleeve.
        let sleeve = book.names.values.reduce(0, +)
        if abs(tilt - previousTilt) > 1e-9, sleeve > 0 {
            for (symbol, w) in book.names { book.names[symbol] = w * tilt / sleeve }
            book.indexWeight = 1 - tilt
        }
        return book
    }
}

// MARK: - Ranking history

/// The top of the factor ranking in one ISO week, kept so the screen can show what changed.
struct RankingSnapshot: Codable, Sendable {
    let week: Int            // ISO year × 100 + ISO week
    let date: Date
    let stressOn: Bool
    let top: [String]        // best first
}

enum RankingTracker {
    private struct History: Codable {
        var current: RankingSnapshot?
        var previous: RankingSnapshot?
    }

    static func week(of date: Date) -> Int {
        let c = Calendar(identifier: .iso8601).dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return (c.yearForWeekOfYear ?? 0) * 100 + (c.weekOfYear ?? 0)
    }

    private static func url(_ key: String) -> URL {
        Universe.directory.appendingPathComponent("ranking-\(key).json")
    }

    /// Stores this week's ranking and returns the latest one from an earlier week.
    static func record(_ snapshot: RankingSnapshot, key: String) -> RankingSnapshot? {
        var history = (try? Data(contentsOf: url(key))).flatMap { try? JSONDecoder().decode(History.self, from: $0) } ?? History()
        if let current = history.current, current.week != snapshot.week { history.previous = current }
        history.current = snapshot
        if let data = try? JSONEncoder().encode(history) { try? data.write(to: url(key), options: .atomic) }
        return history.previous
    }

    /// Names that entered and left the top list, each best-ranked first.
    static func changes(from old: RankingSnapshot?, to new: RankingSnapshot) -> (entered: [String], left: [String]) {
        guard let old else { return ([], []) }
        let before = Set(old.top), after = Set(new.top)
        return (new.top.filter { !before.contains($0) }, old.top.filter { !after.contains($0) })
    }
}
