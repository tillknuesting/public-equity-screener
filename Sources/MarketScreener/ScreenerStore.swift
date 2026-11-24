import Foundation
import Observation

enum Anchor: Hashable {
    case latest
    case event(Int)          // spike day, yyyymmdd
    case range(Int, Int)     // custom period dragged on the VIX chart, yyyymmdd…yyyymmdd
}

enum ExpandedChart: Identifiable, Hashable {
    case vix
    case shockMap
    case price(String)

    var id: String {
        switch self {
        case .vix: "vix"
        case .shockMap: "shock-map"
        case .price(let symbol): "price-\(symbol)"
        }
    }
}

enum SortKey: String {
    case ticker, name, trend, move, z, volume, momentum, rsi, fcfYield, growth, news, earnings, recovery, score
}

@MainActor
@Observable
final class ScreenerStore {
    private(set) var universeKind = UniverseKind(rawValue: UserDefaults.standard.string(forKey: "universe") ?? "") ?? .msci100
    private(set) var universe: [Instrument] = []
    private(set) var series: [String: PriceSeries] = [:]
    private(set) var fundamentals: [String: Fundamentals] = [:]
    private(set) var news: [String: [NewsItem]] = [:]
    private(set) var fx: [String: Double] = [:]

    private(set) var loadingStage: String?
    private(set) var loadedCount = 0
    private(set) var totalCount = 0
    private(set) var failures: [String: String] = [:]
    private(set) var lastUpdated: Date?
    private var fundamentalsUpdated: Date?

    private(set) var results: [StockMetrics] = []
    private(set) var events: [SpikeEvent] = []
    private(set) var spikeDays: Set<Int> = []
    private(set) var vixStatus: VIXStatus?

    // Forced-selling gauges
    private(set) var gauges = MarketGauges()
    private(set) var termPeakByEvent: [Int: Double] = [:]
    private(set) var termByDay: [Int: Double] = [:]
    private var creditByDay: [Int: Double] = [:]
    private var qualityByDay: [Int: Double] = [:]
    private var fredQuality: [Int: Double] = [:]
    /// Known earnings reports per symbol (latest, upcoming, and confirmed past ones kept from earlier fetches).
    private(set) var earnings: [String: [EarningsDate]] = [:]
    private var earningsUpdated: Date?
    /// Where the BBB − AAA quality spread comes from.
    private(set) var qualitySource = "LQD vs QLTA proxy"
    private var correlationByDay: [Int: Double] = [:]
    private var correlationMedian: Double?
    private var correlationTask: Task<Void, Never>?
    private var autoRefreshTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?

    // Backtest
    var showBacktest = false
    private(set) var backtest: BacktestReport?
    private(set) var isBacktesting = false

    /// Defaults to the most recent VIX spike until the user picks something else.
    var anchor: Anchor = .latest { didSet { if anchor != oldValue { recompute() } } }
    private var userPickedAnchor = false
    var window = 3 { didSet { if window != oldValue { recompute() } } }
    /// How many sessions of VIX history the chart shows.
    var chartSpan = 504
    var spikeSettings = SpikeSettings() { didSet { if spikeSettings != oldValue { recomputeSpikes() } } }

    var onlyDeclines = true
    var minDecline = 0.0
    var momentumLeaders = true
    var positiveFCF = false
    var noNewsOnly = false
    var selection: String?
    var expandedChart: ExpandedChart?
    /// The stock shown in the Chart workspace.
    var chartSymbol: String?

    /// Opens a stock in the Chart workspace.
    func openChart(_ symbol: String) {
        chartSymbol = symbol
        selection = symbol
        expandedChart = nil
        UserDefaults.standard.set("chart", forKey: "mainMode")
    }
    var sortKey = SortKey.score
    var sortAscending = false

    var isLoading: Bool { loadingStage != nil }
    /// The volatility index in use (VIX or VSTOXX); everything named "vix" below follows it.
    var volIndex = VolIndex.current {
        didSet {
            guard volIndex != oldValue else { return }
            UserDefaults.standard.set(volIndex.rawValue, forKey: "volIndex")
            userPickedAnchor = false
            backtest = nil
            factor = nil
            strategy = nil
            robustness = nil
            recomputeSpikes()
            updateCorrelation()
            if showFactor { runFactor() }
        }
    }
    var vix: PriceSeries? { series[volIndex.symbol] }
    var benchmark: PriceSeries? { series[universeKind.benchmarkSymbol] }
    var vix3m: PriceSeries? { series[volIndex.threeMonthSymbol] }

    var anchorDay: Int? {
        if case .event(let day) = anchor { return day }
        return nil
    }

    var selectedEvent: SpikeEvent? { events.first { $0.day == anchorDay } }

    var selectedRange: (from: Int, to: Int)? {
        if case .range(let from, let to) = anchor { return (from, to) }
        return nil
    }

    var period: Screener.Period {
        switch anchor {
        case .latest: .trailing(sessions: window)
        case .event(let day): .reaction(spikeDay: day, sessions: window)
        case .range(let from, let to): .range(from: from, to: to)
        }
    }

    /// Trading sessions in the selected custom period (counted on the VIX calendar).
    var rangeSessions: Int {
        guard let r = selectedRange, let bars = vix?.bars else { return 0 }
        return bars.filter { $0.day >= r.from && $0.day <= r.to }.count
    }
    var selectedMetrics: StockMetrics? { results.first { $0.id == selection } }

    // MARK: Top matches

    /// The five highest-scoring stocks that pass every thesis gate, whatever the table filters say.
    var topPicks: [StockMetrics] {
        Array(results.filter(Self.passesThesis).sorted { $0.score.total > $1.score.total }.prefix(5))
    }

    static func passesThesis(_ m: StockMetrics) -> Bool {
        let quiet = if case .catalysts = m.news { false } else { true }
        let noCatalysts = quiet && m.earnings.inWindow == nil
        let generatesCash = m.instrument.isFund || m.instrument.isFinancial || (m.fundamentals.fcfYield ?? 0) > 0
        return m.windowReturn < 0 && m.zScore <= -1 && m.isMomentumLeader && noCatalysts && generatesCash
    }

    /// What the matches are measured against, e.g. "22 Oct 2026 spike · FTSE GAC 500".
    var picksContext: String {
        let period = if let r = selectedRange { "\(TradingDay.label(r.from)) → \(TradingDay.label(r.to))" }
            else if let e = selectedEvent { "\(TradingDay.label(e.day)) spike" }
            else { "last \(window) sessions" }
        return "\(period) · \(universeKind.shortTitle)"
    }

    /// Keeps the data fresh while the app runs (the menu bar list stays live without the window).
    func startAutoRefresh() {
        guard autoRefreshTask == nil else { return }
        autoRefreshTask = Task { [weak self] in
            await self?.refreshIfStale()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30 * 60))
                await self?.refreshIfStale()
            }
        }
    }

    var visibleResults: [StockMetrics] {
        results
            .filter { !onlyDeclines || ($0.windowReturn < 0 && $0.windowReturn <= -minDecline) }
            .filter { !momentumLeaders || $0.isMomentumLeader }
            .filter { !positiveFCF || $0.instrument.isFinancial || $0.instrument.isFund || ($0.fundamentals.fcfYield ?? -1) > 0 }
            .filter { !noNewsOnly || $0.news.isQuiet }
            .sorted(by: sortComparator)
    }

    init() {
        universe = Universe.load(universeKind)
        loadCache()
        recomputeSpikes()
        updateCorrelation()
    }

    // MARK: Selection & sorting

    func toggleSort(_ key: SortKey) {
        if sortKey == key { sortAscending.toggle() } else {
            sortKey = key
            sortAscending = [.ticker, .name, .rsi, .news, .earnings].contains(key)
        }
    }

    func moveSelection(by delta: Int) {
        let rows = visibleResults
        guard !rows.isEmpty else { return }
        let current = rows.firstIndex { $0.id == selection } ?? (delta > 0 ? -1 : rows.count)
        selection = rows[min(max(current + delta, 0), rows.count - 1)].id
    }

    private func sortComparator(_ a: StockMetrics, _ b: StockMetrics) -> Bool {
        func numeric(_ m: StockMetrics) -> Double? {
            switch sortKey {
            case .move: m.windowReturn
            case .z: m.zScore
            case .volume: m.volumeRatio
            case .momentum: m.momentum12_1
            case .rsi: m.rsi
            case .fcfYield: m.fundamentals.fcfYield
            case .growth: m.fundamentals.revenueGrowth
            case .news: m.news.sortValue
            case .trend: m.return3m
            case .earnings: m.earnings.inWindow != nil ? -1 : m.earnings.daysToNext.map(Double.init)
            case .recovery: m.sincePreSpike
            case .score: m.score.total
            case .ticker, .name: nil
            }
        }
        switch sortKey {
        case .ticker: return sortAscending ? a.symbol < b.symbol : a.symbol > b.symbol
        case .name: return sortAscending ? a.name < b.name : a.name > b.name
        default:
            // Missing values always sink to the bottom.
            switch (numeric(a), numeric(b)) {
            case let (x?, y?): return sortAscending ? x < y : x > y
            case (.some, nil): return true
            default: return false
            }
        }
    }

    // MARK: Loading

    func refreshIfStale() async {
        if let lastUpdated, Date().timeIntervalSince(lastUpdated) < 15 * 60 { return }
        await refresh()
    }

    func reloadUniverse() async {
        universe = Universe.load(universeKind)
        await refresh()
    }

    func switchUniverse(_ kind: UniverseKind) async {
        guard kind != universeKind else { return }
        universeKind = kind
        UserDefaults.standard.set(kind.rawValue, forKey: "universe")
        universe = Universe.load(kind)
        selection = nil
        backtest = nil
        strategy = nil
        rankingChanges = ([], [])
        recompute()
        updateCorrelation()
        if universe.contains(where: { series[$0.symbol] == nil }) { await refresh() }
    }

    func refresh() async {
        guard !isLoading else { return }
        failures = [:]
        let client = YahooClient()

        // 1. Prices: the screen works as soon as these are in.
        // FRED's Moody's Baa − Aaa, if reachable; the LQD/QLTA proxy covers it otherwise.
        async let fred: [Int: Double]? = try? FredClient.baaAaaSpread()
        async let vstoxx = try? StoxxClient.series("V2TX", symbol: Universe.vstoxxSymbol)
        async let vstoxx3m = try? StoxxClient.series("V6I3", symbol: Universe.vstoxx3mSymbol)
        let symbols = [Universe.vixSymbol, Universe.vix3mSymbol, Universe.highYieldSymbol, Universe.treasurySymbol,
                       Universe.investmentGradeSymbol, Universe.highGradeSymbol,
                       universeKind.benchmarkSymbol] + universe.map(\.symbol)
        let prices = await fetchAll("PRICES", symbols) { try await client.fetchDaily(symbol: $0) }
        series.merge(prices) { _, new in new }   // keep cached data for anything that failed
        lastUpdated = Date()
        if let q = await fred, q.count > 500 { fredQuality = q }
        for s in [await vstoxx, await vstoxx3m].compactMap({ $0 }) { series[s.symbol] = s }
        recomputeSpikes()
        updateCorrelation()

        // 2. Fundamentals change quarterly; refresh at most daily.
        let companies = universe.filter { !$0.isFund }.map(\.symbol)
        let missing = companies.filter { fundamentals[$0] == nil }
        let fundamentalsStale = fundamentalsUpdated.map { Date().timeIntervalSince($0) > 24 * 3600 } ?? true
        let fundamentalSymbols = fundamentalsStale ? companies : missing
        if !fundamentalSymbols.isEmpty {
            let fresh = await fetchAll("FUNDAMENTALS", fundamentalSymbols) { try await client.fetchFundamentals(symbol: $0) }
            fundamentals.merge(fresh) { _, new in new }
            if fundamentalsStale { fundamentalsUpdated = Date() }
        }
        let currencies = Set(fundamentals.values.flatMap { [$0.reportCurrency, $0.marketCapCurrency] }
            .compactMap(Currency.normalize) + series.values.compactMap { Currency.normalize($0.currency) })
            .subtracting(["USD"])
        let rates = await fetchAll("FX", currencies.sorted()) { try await client.fetchUSDRate(currency: $0) }
        fx.merge(rates) { _, new in new }

        // Earnings dates move rarely; refresh twice a day.
        if earningsUpdated.map({ Date().timeIntervalSince($0) > 12 * 3600 }) ?? true || companies.contains(where: { earnings[$0] == nil }) {
            await fetchEarnings(companies, client: client)
        }
        recompute()

        // 3. Headlines per stock, for the flow-vs-news signal. Large universes only fetch the
        //    names that dropped noticeably or score well, to keep the request count sane.
        let newsSymbols = universe.count <= 150 ? universe.map(\.symbol)
            : results.filter { $0.zScore <= -1 || $0.windowReturn <= -0.02 }
                .sorted { $0.score.total > $1.score.total }.prefix(150).map(\.symbol)
        let headlines = await fetchAll("NEWS", newsSymbols) { try await client.fetchNews(symbol: $0) }
        news.merge(headlines) { _, new in new }

        loadingStage = nil
        recompute()
        saveCache()
        if strategy != nil { runStrategy() }   // keep the factor screen current after a refresh
    }

    private func fetchEarnings(_ symbols: [String], client: YahooClient) async {
        loadingStage = "EARNINGS"
        loadedCount = 0
        totalCount = symbols.count
        let today = TradingDay.day(from: Date())
        var fetched = 0
        for start in stride(from: 0, to: symbols.count, by: 50) {
            defer { loadedCount = min(start + 50, symbols.count) }
            let batch = Array(symbols[start..<min(start + 50, symbols.count)])
            guard let fresh = try? await client.fetchEarnings(symbols: batch) else { continue }
            for (symbol, dates) in fresh { earnings[symbol] = EarningsDate.merge(earnings[symbol] ?? [], dates, today: today) }
            fetched += fresh.count
        }
        if fetched > 0 { earningsUpdated = Date() }
    }

    /// Earnings around the last `sessions` closes of a stock (for the factor screen's 5-day signal).
    func recentEarnings(_ symbol: String, sessions: Int = 5) -> EarningsTiming {
        guard let bars = series[symbol]?.bars, bars.count > sessions else { return EarningsTiming() }
        return EarningsTiming(earnings[symbol], from: bars[bars.count - 1 - sessions].day, to: bars[bars.count - 1].day)
    }

    /// Fetches `symbols` with bounded concurrency, updating the progress counters.
    private func fetchAll<T: Sendable>(_ stage: String, _ symbols: [String],
                                       _ op: @escaping @Sendable (String) async throws -> T) async -> [String: T] {
        loadingStage = stage
        loadedCount = 0
        totalCount = symbols.count
        var out: [String: T] = [:]
        await withTaskGroup(of: (String, T?, String?).self) { group in
            var pending = symbols.makeIterator()
            func enqueue() {
                guard let symbol = pending.next() else { return }
                group.addTask {
                    do { return (symbol, try await op(symbol), nil) }
                    catch { return (symbol, nil, error.localizedDescription) }
                }
            }
            for _ in 0..<8 { enqueue() }
            while let (symbol, value, error) = await group.next() {
                if let value { out[symbol] = value }
                if let error { failures["\(stage.lowercased()) \(symbol)"] = error }
                loadedCount += 1
                enqueue()
            }
        }
        return out
    }

    // MARK: Analysis

    private func recomputeSpikes() {
        guard let bars = vix?.bars else {
            events = []; spikeDays = []; vixStatus = nil
            recompute()
            return
        }
        let idx = VIXAnalysis.spikeIndices(bars, settings: spikeSettings)
        spikeDays = Set(idx.map { bars[$0].day })
        // Events need ~13 months of history before them for momentum and the 200-day average.
        events = VIXAnalysis.events(bars, spikes: idx, minIndex: 275)
        vixStatus = VIXAnalysis.status(bars, spikes: idx)
        termByDay = vix3m.map { MarketStress.termRatio(vix: bars, vix3m: $0.bars) } ?? [:]
        if let hy = series[Universe.highYieldSymbol]?.bars, let tsy = series[Universe.treasurySymbol]?.bars {
            creditByDay = MarketStress.creditSpreadIndex(highYield: hy, treasury: tsy)
        }
        if fredQuality.count > 500 {
            qualityByDay = fredQuality
            qualitySource = "Moody's Baa − Aaa (FRED)"
        } else if let ig = series[Universe.investmentGradeSymbol]?.bars, let hg = series[Universe.highGradeSymbol]?.bars {
            qualityByDay = MarketStress.qualitySpreadProxy(investmentGrade: ig, highGrade: hg)
            qualitySource = "LQD vs QLTA proxy"
        }
        termPeakByEvent = Dictionary(uniqueKeysWithValues: events.map { e in
            (e.day, bars.filter { $0.day >= e.day }.prefix(e.sessions + 3).compactMap { termByDay[$0.day] }.max() ?? 0)
        })
        let current = anchor
        if !userPickedAnchor {
            anchor = events.first.map { .event($0.day) } ?? .latest
        } else if case .event(let day) = anchor, !events.contains(where: { $0.day == day }) {
            anchor = .latest
        }
        if anchor == current { recompute() }   // otherwise didSet already did
    }

    private func recompute() {
        results = Screener.run(screenerInputs)
        computeGauges()
    }

    private var screenerInputs: Screener.Inputs {
        .init(universe: universe, series: series, benchmark: benchmark,
              fundamentals: fundamentals, fx: fx, news: news, period: period, earnings: earnings)
    }

    private func computeGauges() {
        var g = MarketGauges()
        if let bars = vix?.bars, let (start, end) = Screener.bounds(period, bars: bars), start >= 0, end > start {
            let endDay = bars[end].day
            g.correlation = bars[...end].reversed().prefix(5).lazy.compactMap { self.correlationByDay[$0.day] }.first
            g.correlationMedian = correlationMedian
            g.vixTerm = termByDay[endDay]
            g.vixTermPeak = bars[(start + 1)...end].compactMap { termByDay[$0.day] }.max()
            g.creditChange = MarketStress.change(creditByDay, calendar: bars, from: start, to: end)
            let q = MarketStress.qualityWidening(qualityByDay, calendar: bars, at: end)
            g.qualityChange = q.change
            g.qualityWidening = q.widening
        }
        let leaders = results.filter { $0.momentumRank >= 2.0 / 3.0 }.map(\.windowReturn)
        let laggards = results.filter { $0.momentumRank <= 1.0 / 3.0 }.map(\.windowReturn)
        if !leaders.isEmpty, !laggards.isEmpty { g.momentumSpread = Stats.mean(leaders) - Stats.mean(laggards) }
        gauges = g
    }

    /// Rolling average correlation of same-session (Americas) names; heavy, so off the main thread.
    private func updateCorrelation() {
        guard let calendar = vix?.bars else { return }
        let input = universe.filter { $0.session == .americas }.compactMap { series[$0.symbol] }
        correlationTask?.cancel()
        correlationTask = Task {
            let corr = await Task.detached(priority: .userInitiated) {
                MarketStress.correlationSeries(input, calendar: calendar, days: calendar.count)
            }.value
            guard !Task.isCancelled else { return }
            correlationByDay = corr
            let recent = calendar.suffix(252).compactMap { corr[$0.day] }.sorted()
            correlationMedian = recent.isEmpty ? nil : recent[recent.count / 2]
            computeGauges()
        }
    }

    // MARK: Backtest

    func runBacktest(withoutFundamentals: Bool? = nil) {
        showBacktest = true
        guard !isBacktesting else { return }
        isBacktesting = true
        let exclude = withoutFundamentals ?? backtest?.withoutFundamentals ?? false
        Task {
            backtest = await makeBacktest(withoutFundamentals: exclude)
            isBacktesting = false
        }
    }

    // MARK: Risk-budget factor

    var showFactor = false
    private(set) var factor: FactorReport?
    private(set) var isComputingFactor = false

    func runFactor() {
        showFactor = true
        guard !isComputingFactor else { return }
        isComputingFactor = true
        Task {
            factor = await makeFactor()
            isComputingFactor = false
        }
    }

    func makeFactor() async -> FactorReport {
        let universe = universe, series = series, title = universeKind.title, credit = creditByDay, quality = qualityByDay
        let calendar = benchmark?.bars ?? vix?.bars ?? [], vixBars = vix?.bars ?? []
        return await Task.detached(priority: .userInitiated) {
            RiskBudgetFactor.run(universe: universe, series: series, calendar: calendar, vix: vixBars,
                                 credit: credit, quality: quality, title: title)
        }.value
    }

    private(set) var strategy: StrategyReport?
    private(set) var isComputingStrategy = false
    /// Names that entered and left the factor's top list since the last recorded week.
    private(set) var rankingChanges: (entered: [String], left: [String]) = ([], [])
    private(set) var previousRanking: RankingSnapshot?

    /// Which backtest variant the factor screen shows: "monthly" (review every 4 weeks) or "weekly".
    var deskPolicy = UserDefaults.standard.string(forKey: "deskPolicy") ?? "monthly" {
        didSet { UserDefaults.standard.set(deskPolicy, forKey: "deskPolicy") }
    }

    func runStrategy() {
        guard !isComputingStrategy else { return }
        isComputingStrategy = true
        Task {
            let report = await makeStrategy()
            if let report {
                let snapshot = RankingSnapshot(week: RankingTracker.week(of: Date()), date: Date(),
                                               stressOn: report.gateOpen, top: report.positions.map(\.id))
                let previous = RankingTracker.record(snapshot, key: universeKind.rawValue)
                previousRanking = previous
                rankingChanges = RankingTracker.changes(from: previous, to: snapshot)
            }
            strategy = report
            isComputingStrategy = false
        }
    }

    func makeStrategy() async -> StrategyReport? {
        guard let bench = benchmark, let vixBars = vix?.bars else { return nil }
        let universe = universe, series = series, title = universeKind.title, credit = creditByDay, quality = qualityByDay
        let name = universeKind.benchmarkName
        return await Task.detached(priority: .userInitiated) {
            SwitchingStrategy.run(universe: universe, series: series, benchmark: bench, vix: vixBars,
                                  credit: credit, quality: quality, title: title, benchmarkName: name)
        }.value
    }

    // MARK: Robustness grid

    var showRobustness = false
    private(set) var robustness: RobustnessReport?
    private(set) var isComputingRobustness = false

    func runRobustness() {
        showRobustness = true
        guard !isComputingRobustness else { return }
        isComputingRobustness = true
        Task {
            robustness = await makeRobustness()
            isComputingRobustness = false
        }
    }

    func makeRobustness() async -> RobustnessReport? {
        guard let bench = benchmark, let vixBars = vix?.bars else { return nil }
        let universe = universe, series = series, title = universeKind.title, credit = creditByDay, quality = qualityByDay
        let name = universeKind.benchmarkName
        return await Task.detached(priority: .userInitiated) {
            Robustness.run(universe: universe, series: series, benchmark: bench, vix: vixBars,
                           credit: credit, quality: quality, title: title, benchmarkName: name)
        }.value
    }

    /// Waits for the background correlation calculation (used by the command-line modes).
    func waitForGauges() async {
        await correlationTask?.value
    }

    /// Waits for the cache to be written (command-line modes exit right after their work).
    func waitForSave() async {
        await saveTask?.value
    }

    /// `withoutFundamentals` holds quality neutral, removing today's-fundamentals look-ahead.
    func makeBacktest(withoutFundamentals: Bool = false) async -> BacktestReport {
        await correlationTask?.value
        var input = screenerInputs
        if withoutFundamentals { input.fundamentals = [:] }
        let events = events, window = window, title = universeKind.title
        let term = termByDay, corr = correlationByDay, median = correlationMedian, credit = creditByDay, quality = qualityByDay
        var report = await Task.detached(priority: .userInitiated) {
            Backtest.run(input, universe: title, events: events, window: window,
                         termRatio: term, correlation: corr, correlationMedian: median, credit: credit, quality: quality)
        }.value
        report.withoutFundamentals = withoutFundamentals
        return report
    }

    func selectNearestEvent(to date: Date) {
        func distance(_ e: SpikeEvent) -> Double { abs(TradingDay.date(e.day).timeIntervalSince(date)) / 86_400 }
        guard let nearest = events.min(by: { distance($0) < distance($1) }), distance(nearest) <= 10 else { return }
        pickAnchor(.event(nearest.day))
    }

    func pickAnchor(_ new: Anchor) {
        userPickedAnchor = true
        anchor = new
    }

    /// Snaps a dragged date range to VIX trading days and analyses it.
    func pickRange(_ dates: ClosedRange<Date>) {
        guard let bars = vix?.bars,
              let from = bars.first(where: { $0.day >= TradingDay.day(from: dates.lowerBound) })?.day,
              let to = bars.last(where: { $0.day <= TradingDay.day(from: dates.upperBound) })?.day,
              from <= to else { return }
        pickAnchor(.range(from, to))
    }

    /// The last `sessions` sessions as a custom period.
    func pickRecent(sessions: Int) {
        guard let bars = vix?.bars, bars.count > sessions else { return }
        pickAnchor(.range(bars[bars.count - sessions].day, bars[bars.count - 1].day))
    }

    func pickYearToDate() {
        guard let last = vix?.bars.last,
              let first = vix?.bars.first(where: { $0.day >= (last.day / 10000) * 10000 + 101 }) else { return }
        pickAnchor(.range(first.day, last.day))
    }

    /// Back to the default: the most recent spike.
    func resetToLatestSpike() {
        userPickedAnchor = false
        anchor = events.first.map { .event($0.day) } ?? .latest
    }

    // MARK: Cache

    /// Everything but prices; prices live in a compact binary file (see PriceCache).
    private struct Cache: Codable {
        let updated: Date
        let fundamentalsUpdated: Date?
        let fundamentals: [String: Fundamentals]
        let fx: [String: Double]
        let news: [String: [NewsItem]]
        var fredQuality: [Int: Double]?
        var earningDates: [String: [EarningsDate]]?
        var earningDatesUpdated: Date?
    }

    /// One NaN or infinity used to make the whole JSON write fail silently; spell them out instead.
    nonisolated private static var cacheEncoder: JSONEncoder {
        let e = JSONEncoder()
        e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return e
    }
    private static var cacheDecoder: JSONDecoder {
        let d = JSONDecoder()
        d.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return d
    }

    private var cacheURL: URL { Universe.directory.appendingPathComponent("cache-v4.json") }
    private var priceCacheURL: URL { Universe.directory.appendingPathComponent("prices-v4.bin") }

    private func loadCache() {
        series = PriceCache.load(from: priceCacheURL).mapValues { $0.repaired() }
        guard let data = try? Data(contentsOf: cacheURL),
              let cache = try? Self.cacheDecoder.decode(Cache.self, from: data) else { return }
        fundamentals = cache.fundamentals
        fredQuality = cache.fredQuality ?? [:]
        earnings = cache.earningDates ?? [:]
        earningsUpdated = cache.earningDatesUpdated
        fx = cache.fx
        news = cache.news
        lastUpdated = cache.updated
        fundamentalsUpdated = cache.fundamentalsUpdated
    }

    private func saveCache() {
        let cache = Cache(updated: lastUpdated ?? Date(), fundamentalsUpdated: fundamentalsUpdated,
                          fundamentals: fundamentals, fx: fx, news: news, fredQuality: fredQuality.isEmpty ? nil : fredQuality,
                          earningDates: earnings, earningDatesUpdated: earningsUpdated)
        let url = cacheURL, pricesURL = priceCacheURL, prices = series
        saveTask = Task.detached(priority: .utility) {
            PriceCache.save(prices, to: pricesURL)
            try? Self.cacheEncoder.encode(cache).write(to: url, options: .atomic)
        }
    }
}
