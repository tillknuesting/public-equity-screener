import AppKit
import SwiftUI

/// Command-line modes besides the normal app:
///   MarketScreener --picks [--ftse|--sectors]          print the automatic top 5 matches
///   MarketScreener --scan [--window N] [--sectors]     print the screen to stdout
///   MarketScreener --snapshot out.png [--light] [--range yyyymmdd:yyyymmdd]
///                        [--ftse|--sectors] [--expand vix|backtest|picks|SYMBOL]  render the UI to a PNG (uses the cache)
@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        func value(after flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }
        if let path = value(after: "--share-card") {
            Task { @MainActor in
                await HeadlessScan.shareCard(to: path)
                exit(0)
            }
            dispatchMain()
        } else if args.contains("--data-check") {
            Task { @MainActor in
                HeadlessScan.dataCheck()
                exit(0)
            }
            dispatchMain()
        } else if args.contains("--robustness") {
            Task { @MainActor in
                await HeadlessScan.robustness()
                exit(0)
            }
            dispatchMain()
        } else if args.contains("--strategy") {
            Task { @MainActor in
                await HeadlessScan.strategy()
                exit(0)
            }
            dispatchMain()
        } else if args.contains("--factor") {
            Task { @MainActor in
                await HeadlessScan.factor()
                await HeadlessScan.lastStore?.waitForSave()
                exit(0)
            }
            dispatchMain()
        } else if args.contains("--picks") {
            Task { @MainActor in
                await HeadlessScan.picks()
                await HeadlessScan.lastStore?.waitForSave()
                exit(0)
            }
            dispatchMain()
        } else if args.contains("--backtest") {
            Task { @MainActor in
                await HeadlessScan.backtest(window: value(after: "--window").flatMap(Int.init))
                await HeadlessScan.lastStore?.waitForSave()
                exit(0)
            }
            dispatchMain()
        } else if args.contains("--scan") {
            Task { @MainActor in
                await HeadlessScan.run(window: value(after: "--window").flatMap(Int.init))
                await HeadlessScan.lastStore?.waitForSave()
                exit(0)
            }
            dispatchMain()
        } else if let path = value(after: "--snapshot") {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            Task { @MainActor in
                let range = value(after: "--range").map { $0.split(separator: ":").compactMap { Int($0) } }
                await Snapshot.render(to: URL(fileURLWithPath: path), light: args.contains("--light"),
                                      range: range.flatMap { $0.count == 2 ? ($0[0], $0[1]) : nil })
                exit(0)
            }
            app.run()
        } else {
            EquityScreenerApp.main()
        }
    }
}

@MainActor
enum Snapshot {
    static func render(to url: URL, light: Bool, range: (Int, Int)?) async {
        let store = ScreenerStore()
        HeadlessScan.lastStore = store
        if let kind = HeadlessScan.universeFlag { await store.switchUniverse(kind) }
        await store.refreshIfStale()
        if let range { store.pickAnchor(.range(range.0, range.1)) }
        UserDefaults.standard.set(CommandLine.arguments.contains("--map") ? "map" : "table", forKey: "screenerMode")
        UserDefaults.standard.set("screener", forKey: "mainMode")
        store.selection = store.visibleResults.first?.id

        // --expand vix|SYMBOL renders the large-chart sheet instead of the main window.
        let args = CommandLine.arguments
        let expand = args.firstIndex(of: "--expand").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        let size = switch expand {
        case nil: NSSize(width: 1600, height: 960)
        case "picks": NSSize(width: 420, height: 440)
        case "desk", "chart", "robustness", "share": NSSize(width: 1600, height: 960)
        default: NSSize(width: 1400, height: 820)
        }
        if expand == "chart" {
            store.chartSymbol = args.firstIndex(of: "--symbol").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? store.topPicks.first?.id
            if args.contains("--demo-drawings"), let s = store.chartSymbol, let bars = store.series[s]?.bars, bars.count > 130 {
                // A trend line, a Fibonacci retracement over six months and a level, in memory only.
                DrawingStore.persist = false
                let recent = Array(bars.suffix(126))
                let hi = recent.max { $0.high < $1.high }!, lo = recent.min { $0.low < $1.low }!
                let a = bars[bars.count - 120], b = bars[bars.count - 40]
                DrawingStore.demo[s] = [
                    ChartDrawing(kind: .trend, a: ChartAnchor(day: a.day, price: a.low), b: ChartAnchor(day: b.day, price: b.low)),
                    ChartDrawing(kind: .fib, a: ChartAnchor(day: lo.day, price: lo.low), b: ChartAnchor(day: hi.day, price: hi.high)),
                    ChartDrawing(kind: .horizontal, a: ChartAnchor(day: bars.last!.day, price: hi.high), b: ChartAnchor(day: bars.last!.day, price: hi.high)),
                ]
            }
            UserDefaults.standard.set("chart", forKey: "mainMode")
            store.runStrategy()
            while store.isComputingStrategy { try? await Task.sleep(for: .milliseconds(200)) }
        }
        if expand == "desk" {
            store.runStrategy()
            while store.isComputingStrategy { try? await Task.sleep(for: .milliseconds(200)) }
        }
        if expand == "factor" {
            store.runFactor()
            while store.isComputingFactor { try? await Task.sleep(for: .milliseconds(200)) }
        }
        if expand == "robustness" {
            store.runRobustness()
            while store.isComputingRobustness { try? await Task.sleep(for: .milliseconds(200)) }
        }
        if expand == "backtest" {
            store.runBacktest()
            while store.isBacktesting { try? await Task.sleep(for: .milliseconds(200)) }
        }
        let root: AnyView = switch expand {
        case nil: AnyView(ContentView())
        case "vix": AnyView(ChartSheet(chart: .vix))
        case "backtest": AnyView(BacktestSheet())
        case "factor": AnyView(FactorSheet())
        case "robustness": AnyView(RobustnessSheet())
        case "desk": AnyView(VStack(spacing: 6) { TopBar(); TradeDesk() }.padding(6).background(Theme.canvas))
        case "chart": AnyView(VStack(spacing: 6) { TopBar(); ChartWorkspace() }.padding(6).background(Theme.canvas))
        case "share": AnyView(VStack(spacing: 6) { TopBar(); ShareStudio() }.padding(6).background(Theme.canvas))
        case "map": AnyView(ChartSheet(chart: .shockMap))
        case "picks": AnyView(PicksMenu())
        case let symbol?: AnyView(ChartSheet(chart: .price(symbol)))
        }
        let host = NSHostingView(rootView: root.environment(store).frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        window.contentView = host
        window.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(2))   // let SwiftUI lay out and charts draw

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("wrote \(url.path)")
    }
}

@MainActor
enum HeadlessScan {
    /// The store used by the last headless run, so `main` can wait for its cache write.
    static var lastStore: ScreenerStore?

    static var universeFlag: UniverseKind? {
        let args = CommandLine.arguments
        return args.contains("--ftse100") ? .ftse100 : args.contains("--ftse") ? .ftse500 : args.contains("--dax") ? .dax40 : args.contains("--stoxx") ? .stoxx600
            : args.contains("--sectors") ? .sectors : args.contains("--msci") ? .msci100 : nil
    }

    /// `--picks [--ftse|--sectors|--msci]`: the automatic top 5, for a quick look or a cron job.
    static func picks() async {
        let store = ScreenerStore()
        lastStore = store
        if let kind = universeFlag { await store.switchUniverse(kind) }
        if CommandLine.arguments.contains("--refresh") { await store.refresh() } else { await store.refreshIfStale() }
        print("Top matches · \(store.picksContext)")
        let picks = store.topPicks
        if picks.isEmpty { print("No stock passes every check right now.") }
        for (i, m) in picks.enumerated() {
            print(String(format: "%d. %@  %@  score %.0f", i + 1, m.symbol, m.name, m.score.total))
            print("   " + PickSummary.reasons(m).joined(separator: " · "))
        }
    }

    /// `--strategy [--ftse|--sectors]`: stress-gated switching strategy, long-only after costs.
    static func strategy() async {
        let store = ScreenerStore()
        lastStore = store
        if let kind = universeFlag { await store.switchUniverse(kind) }
        guard let r = await store.makeStrategy() else { print("No data."); return }
        func pct(_ v: Double) -> String { String(format: "%+6.1f%%", v * 100) }
        print("Switching strategy · \(r.universe) vs \(r.benchmarkName) · costs \(Int(r.baseBps)) bp + transaction taxes · gate now \(r.gateOpen ? "OPEN" : "closed")")
        print("STRATEGY                                   CAGR    vol  Sharpe  maxDD   excess    IR     t   tilted  ex-tilted  cost/yr")
        for x in r.results + r.tilts where x.config.tilt != 0.5 || r.results.contains(where: { $0.id == x.id }) {
            print(x.config.name.padding(toLength: 42, withPad: " ", startingAt: 0)
                  + "\(pct(x.cagr)) \(String(format: "%5.1f%%", x.vol * 100))  \(String(format: "%+5.2f", x.sharpe)) \(pct(x.maxDrawdown))  \(pct(x.excessCAGR)) \(String(format: "%+5.2f %+5.1f", x.infoRatio, x.tExcess))  \(String(format: "%4.0f%%", x.tiltedShare * 100))  \(pct(x.excessWhenTilted))  \(String(format: "%5.2f%%", x.costPerYear * 100))")
        }
        print("\nTop-ranked today (stress \(r.gateOpen ? "on" : "off")): " + r.positions.map(\.instrument.symbol).joined(separator: ", "))
    }

    /// `--share-card out.png [--template stock|compare|vol|matches] [--format 16:9|4:5|1:1] [--range 1Y]
    /// [--symbol X] [--light] [--caption "…"]`: render a Share card to a PNG (uses the cache).
    static func shareCard(to path: String) async {
        let store = ScreenerStore()
        lastStore = store
        if let kind = universeFlag { await store.switchUniverse(kind) }
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        var s = ShareSettings()
        s.template = value("--template").flatMap { name in ShareTemplate.allCases.first { "\($0)" == name } } ?? .stock
        s.format = value("--format").flatMap(ShareFormat.init(rawValue:)) ?? .landscape
        s.range = value("--range").flatMap(ShareRange.init(rawValue:)) ?? .y1
        s.theme = value("--theme").flatMap { name in ShareTheme.allCases.first { "\($0)" == name || $0.rawValue == name } }
            ?? (args.contains("--light") ? .solarizedLight : .solarizedDark)
        s.symbol = value("--symbol") ?? store.topPicks.first?.id ?? store.universe.first?.symbol ?? ""
        s.caption = value("--caption") ?? ""
        guard let png = ShareRenderer.png(store: store, settings: s) else { print("Render failed"); return }
        try? png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) (\(ShareRenderer.fileName(s)))")
    }

    /// `--data-check [--stoxx|…]`: daily moves beyond ±50% in the cached prices, usually unit or split errors.
    static func dataCheck() {
        let store = ScreenerStore()
        let universe = universeFlag.map(Universe.load) ?? store.universe
        var found = 0
        for inst in universe {
            guard let bars = store.series[inst.symbol]?.bars, bars.count > 1 else { print("\(inst.symbol): no prices"); continue }
            for i in 1..<bars.count where bars[i - 1].close > 0 {
                let move = bars[i].close / bars[i - 1].close - 1
                if move > 0.5 || move < -0.5 {
                    found += 1
                    print(String(format: "%-10@ %@  %10.2f → %10.2f  %+.0f%%", inst.symbol as NSString, TradingDay.label(bars[i].day) as NSString,
                                 bars[i - 1].close, bars[i].close, move * 100))
                }
            }
        }
        print("\(found) moves beyond ±50% in \(universe.count) series")
    }

    /// `--robustness [--ftse|--ftse100|--sectors]`: the stress-gated rule across neighbouring settings.
    static func robustness() async {
        let store = ScreenerStore()
        lastStore = store
        if let kind = universeFlag { await store.switchUniverse(kind) }
        let started = Date()
        guard let r = await store.makeRobustness() else { print("No data."); return }
        print("Robustness grid · \(r.universe) vs \(r.benchmarkName) · \(String(format: "%.1f", r.years)) years · \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        for (k, bps) in r.costLevels.enumerated() where k < 2 {
            print("\n=== base cost \(Int(bps)) bp per side + transaction taxes ===")
            for g in r.grids {
                print("\n\(g.title)  (rows: \(g.rowTitle), columns: \(g.columnTitle); [chosen])")
                print("excess vs index, t   |   vs control, t")
                print("".padding(toLength: 14, withPad: " ", startingAt: 0) + g.columns.map { $0.padding(toLength: 22, withPad: " ", startingAt: 0) }.joined())
                for (ri, row) in g.rows.enumerated() {
                    var line = row.padding(toLength: 14, withPad: " ", startingAt: 0)
                    for ci in g.columns.indices {
                        guard let s = g.cell(ri, ci)?.scores[k] else { continue }
                        let chosen = ri == g.chosenRow && ci == g.chosenColumn
                        let text = String(format: "%+5.1f %+4.1f|%+5.1f %+4.1f", s.excess * 100, s.tExcess, s.vsControl * 100, s.tControl)
                        line += (chosen ? "[" + text + "]" : " " + text + " ").padding(toLength: 22, withPad: " ", startingAt: 0)
                    }
                    print(line)
                }
                let scores = g.cells.map { $0.scores[k] }
                let near = g.neighbourhood().map { $0.scores[k] }
                print(String(format: "positive vs index %d/%d · vs control %d/%d · neighbourhood mean %+.1f%% (control %+.1f%%) · grid median %+.1f%%",
                             scores.filter { $0.excess > 0 }.count, scores.count, scores.filter { $0.vsControl > 0 }.count, scores.count,
                             Stats.mean(near.map(\.excess)) * 100, Stats.mean(near.map(\.vsControl)) * 100,
                             scores.map(\.excess).sorted()[scores.count / 2] * 100))
            }
        }
    }

    /// `--factor [--ftse|--sectors] [--offline] [--refresh]`: risk-budget reversal factor backtest.
    static func factor() async {
        let store = ScreenerStore()
        lastStore = store
        if let kind = universeFlag { await store.switchUniverse(kind) }
        if CommandLine.arguments.contains("--refresh") { await store.refresh() }
        else if !CommandLine.arguments.contains("--offline") { await store.refreshIfStale() }
        let r = await store.makeFactor()
        func pct(_ v: Double) -> String { String(format: "%+6.1f%%", v * 100) }
        func row(_ label: String, _ s: FactorReport.Summary) -> String {
            label.padding(toLength: 21, withPad: " ", startingAt: 0)
                + "\(pct(s.annReturn))/yr  Sharpe \(String(format: "%+5.2f", s.sharpe))  t \(String(format: "%+5.1f", s.t))  hit \(String(format: "%3.0f%%", s.hitRate * 100))  n \(s.periods)"
        }
        print("Risk-budget factor · \(r.universe) · stress gate now: \(r.gateOpen ? "OPEN" : "closed")")
        print("Quality spread source: \(store.qualitySource)")
        for v in r.variants {
            print("\n\(v.spec.name): \(v.spec.note)  (turnover \(String(format: "%.0f%%", v.turnover * 100)) per rebalance)")
            print(row("  long−short gross", v.gross))
            print(row("  net, 5 bp/side", v.net5))
            print(row("  net, 10 bp/side", v.net10))
            print(row("  long-only vs univ.", v.longOnly))
            print(row("  calm \(VolIndex.current.name)", v.calm))
            print(row("  stressed \(VolIndex.current.name)", v.stressed))
            print(row("  \(VolIndex.current.name) shock", v.shock))
            print(row("  credit widening", v.creditWidening))
            print(row("  risk-budget only", v.riskBudget))
            print(row("  credit crisis", v.creditCrisis))
        }
        print("\nHighest-ranked today (momentum leaders): " + r.holdings.prefix(10).map { "\($0.instrument.symbol) (\($0.move.pct), shock \(String(format: "%.1f", $0.volShock))×)" }.joined(separator: ", "))
    }

    static func backtest(window: Int?) async {
        let store = ScreenerStore()
        lastStore = store
        if let kind = universeFlag { await store.switchUniverse(kind) }
        if let window { store.window = window }
        if !CommandLine.arguments.contains("--offline") { await store.refreshIfStale() }
        let started = Date()
        let r = await store.makeBacktest(withoutFundamentals: CommandLine.arguments.contains("--no-quality"))
        print("Backtest · \(r.universe) · \(r.rows.count) spikes evaluated · \(r.window)D reaction window · \(String(format: "%.1fs", Date().timeIntervalSince(started)))")
        func f(_ v: Double?) -> String { v.map { String(format: "%+6.2f%%", $0 * 100) } ?? "     – " }
        print("\nSTRATEGY           " + BacktestReport.horizons.map { "  \($0.label) ret   excess   hit  n " }.joined())
        for name in BacktestReport.strategies + ["Benchmark"] {
            var line = name.padding(toLength: 19, withPad: " ", startingAt: 0)
            for h in BacktestReport.horizons {
                if let s = r.stats[name]?[h.sessions] {
                    line += " \(f(s.meanReturn)) \(name == "Benchmark" ? "        " : f(s.meanExcess)) \(String(format: "%3.0f%%", s.hitRate * 100)) \(String(format: "%2d", s.events))"
                } else { line += String(repeating: " ", count: 32) }
            }
            print(line)
        }
        print("\nALPHA (β-adjusted)   all spikes: α  t(α)  t(excess)   ·   non-overlapping spikes: α  t(α)  n")
        for name in BacktestReport.strategies + BacktestReport.spreads {
            var line = name.padding(toLength: 19, withPad: " ", startingAt: 0)
            for h in BacktestReport.horizons {
                let a = r.stats[name]?[h.sessions], i = r.independentStats[name]?[h.sessions]
                line += "  \(h.label) " + (a.map { "\(f($0.meanAlpha)) \(String(format: "%+4.1f %+4.1f", $0.tAlpha, $0.tExcess))" } ?? "")
                line += " | " + (i.map { "\(f($0.meanAlpha)) \(String(format: "%+4.1f %2d", $0.tAlpha, $0.events))" } ?? "")
            }
            print(line)
        }
        print("\nFACTOR (rank IC)    " + BacktestReport.horizons.map { "  \($0.label) IC     t  " }.joined())
        for factor in r.factors {
            var line = factor.name.padding(toLength: 19, withPad: " ", startingAt: 0)
            for h in BacktestReport.horizons {
                if let ic = factor.ic[h.sessions] { line += String(format: "  %+.3f %+5.1f  ", ic.mean, ic.t) } else { line += "                " }
            }
            print(line)
        }
        print("\nCONDITION (1M excess)        n   thesis   top10")
        for s in r.splits {
            print(s.condition.padding(toLength: 27, withPad: " ", startingAt: 0) + String(format: "%3d", s.events) + "  \(f(s.thesisExcess))  \(f(s.topExcess))")
        }
        print("\nRecent events: " + r.rows.prefix(6).map { "\(TradingDay.label($0.event.day)) picks=\($0.picks.count) term=\($0.termPeak.map { String(format: "%.2f", $0) } ?? "-")" }.joined(separator: " | "))
        let g = store.gauges
        print("Gauges now: corr \(g.correlation.map { String(format: "%.2f", $0) } ?? "-") (median \(g.correlationMedian.map { String(format: "%.2f", $0) } ?? "-")), mom spread \(g.momentumSpread?.pct ?? "-"), \(VolIndex.current.name)/3M \(g.vixTerm.map { String(format: "%.2f", $0) } ?? "-") peak \(g.vixTermPeak.map { String(format: "%.2f", $0) } ?? "-")")
    }

    static func run(window: Int?) async {
        let store = ScreenerStore()
        lastStore = store
        if let kind = universeFlag { await store.switchUniverse(kind) }
        if let window { store.window = window }
        await store.refreshIfStale()
        store.momentumLeaders = false
        await store.waitForGauges()
        let g = store.gauges
        print(String(format: "Gauges: corr %.3f · momentum spread %.4f · \(VolIndex.current.name)/3M peak %.3f",
                     g.correlation ?? .nan, g.momentumSpread ?? .nan, g.vixTermPeak ?? .nan))

        if let s = store.vixStatus {
            print(String(format: "\(VolIndex.current.name) %.2f (%@) on %@ · spike today: %@", s.level, s.change.pct, TradingDay.label(s.day), s.isSpike ? "yes" : "no"))
        }
        print("Spike events: \(store.events.prefix(6).map { "\(TradingDay.label($0.day)) \($0.change.pct)" }.joined(separator: ", "))")
        if let e = store.selectedEvent { print("Anchor: spike of \(TradingDay.label(e.day)) (\(e.sessionsAgo) sessions ago), window \(store.window)D") }
        print("Loaded: \(store.series.count) prices, \(store.fundamentals.values.filter { $0.fcf != nil }.count) with FCF, \(store.news.count) news feeds, \(store.earnings.count) earnings calendars, FX \(store.fx.keys.sorted())")
        if !store.failures.isEmpty { print("Failures: \(store.failures.sorted { $0.key < $1.key }.prefix(10).map { "\($0.key): \($0.value)" })") }
        print("")

        func col(_ s: String, _ w: Int, right: Bool = true) -> String {
            let t = String(s.prefix(w))
            let pad = String(repeating: " ", count: max(0, w - t.count))
            return right ? pad + t : t + pad
        }
        print(col("TICKER", 10, right: false) + col("NAME", 20, right: false) + col("DROP", 8) + col("Z", 6) + col("MOM12-1", 9)
              + col("", 3) + col("FCFYLD", 8) + col("REVG", 8) + col("NEWS", 12) + col("EARN", 8) + col("VSPRE", 8) + col("SCORE", 7))
        let rows = store.visibleResults.prefix(20) + store.visibleResults.dropFirst(20).filter { $0.earnings.inWindow != nil }.prefix(5)
        for m in rows {
            let news: String = switch m.news {
            case .quiet(let h): "flow(\(h))"
            case .catalysts(let c, let h): "news \(c)/\(h)"
            case .unknown: "?"
            }
            let earn = m.earnings.inWindow != nil ? "in win" : m.earnings.daysToNext.map { $0 <= 14 ? "\($0)d" : "" } ?? ""
            print(col(m.symbol, 10, right: false) + col(m.name, 20, right: false) + col(m.windowReturn.pct, 8)
                  + col(String(format: "%.1f", m.zScore), 6) + col(m.momentum12_1?.pct ?? "-", 9) + col(m.isMomentumLeader ? "*" : "", 3)
                  + col(m.instrument.isFinancial ? "n/m" : m.fundamentals.fcfYield.map { String(format: "%.1f%%", $0 * 100) } ?? "-", 8)
                  + col(m.fundamentals.revenueGrowth?.pct ?? "-", 8) + col(news, 12) + col(earn, 8)
                  + col(m.sincePreSpike?.pct ?? "-", 8) + col(String(format: "%.1f", m.score.total), 7))
        }
    }
}
