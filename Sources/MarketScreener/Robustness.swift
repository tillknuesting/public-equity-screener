import Foundation

/// Was the low-turnover rule tuned to the data? Reruns the stress-gated strategy across
/// neighbouring settings and scores every cell against the index and against a control that
/// holds all momentum leaders under the same gate, tilt and review timing.
struct RobustnessReport: Sendable {
    struct Score: Sendable {
        let excess: Double      // CAGR minus the index's
        let tExcess: Double
        let vsControl: Double   // CAGR minus the matching control's: the ranking's own edge
        let tControl: Double
        let cost: Double        // per year
    }

    struct Cell: Identifiable, Sendable {
        let row: Int
        let column: Int
        let scores: [Score]     // one per cost level
        let activeShare: Double // share of weeks with the tilt on
        var id: Int { row * 100 + column }
    }

    struct Grid: Identifiable, Sendable {
        let title: String
        let note: String
        let rowTitle: String
        let columnTitle: String
        let rows: [String]
        let columns: [String]
        let chosenRow: Int
        let chosenColumn: Int
        let cells: [Cell]
        var id: String { title }

        func cell(_ row: Int, _ column: Int) -> Cell? { cells.first { $0.row == row && $0.column == column } }

        /// The chosen cell and the cells touching it (including diagonals).
        func neighbourhood() -> [Cell] {
            cells.filter { abs($0.row - chosenRow) <= 1 && abs($0.column - chosenColumn) <= 1 }
        }
    }

    let universe: String
    let benchmarkName: String
    let costLevels: [Double]   // base cost per side in bp; transaction taxes always apply
    let volIndex: String
    let years: Double
    let grids: [Grid]
}

enum Robustness {
    static let costLevels: [Double] = [5, 15, 30]

    private struct Spec {
        let row: Int
        let column: Int
        let config: StrategyConfig
        let control: StrategyConfig
    }

    private struct Layout {
        let title: String
        let note: String
        let rowTitle: String
        let columnTitle: String
        let rows: [String]
        let columns: [String]
        let chosenRow: Int
        let chosenColumn: Int
        let specs: [Spec]
    }

    /// The published low-turnover rule is `rule()` with every default.
    static func rule(gate: StrategyConfig.Gate = .broad, tilt: Double = 0.5, buffer: Double = 3, minHold: Int = 4,
                     review: Int = 4, sticky: Int = 4) -> StrategyConfig {
        let turnover = TurnoverPolicy(exitRankMultiple: buffer, minHoldWeeks: minHold, reviewEveryWeeks: review, stickyWeeks: sticky)
        let c = StrategyConfig(name: "", note: "", gate: gate, sleeve: .factorLongs, tilt: tilt, excludeTaxed: false, turnover: turnover)
        return named(c)
    }

    /// Same gate, tilt, review timing and sticky gate, but holding every momentum leader.
    static func control(of c: StrategyConfig) -> StrategyConfig {
        let turnover = TurnoverPolicy(reviewEveryWeeks: c.turnover.reviewEveryWeeks, stickyWeeks: c.turnover.stickyWeeks)
        return named(StrategyConfig(name: "", note: "", gate: c.gate, sleeve: .allLeaders, tilt: c.tilt, excludeTaxed: false, turnover: turnover))
    }

    /// Names a config by its settings, so identical configs from different grids run once.
    private static func named(_ c: StrategyConfig) -> StrategyConfig {
        let t = c.turnover
        let key = "\(c.gate)|\(c.sleeve)|\(c.tilt)|\(t.exitRankMultiple.map { "\($0)" } ?? "-")|\(t.minHoldWeeks)|\(t.reviewEveryWeeks)|\(t.stickyWeeks)"
        return StrategyConfig(name: key, note: c.note, gate: c.gate, sleeve: c.sleeve, tilt: c.tilt,
                              excludeTaxed: c.excludeTaxed, crisisTilt: c.crisisTilt, turnover: c.turnover)
    }

    private static func layouts() -> [Layout] {
        func grid(_ title: String, _ note: String, rowTitle: String, columnTitle: String,
                  rows: [String], columns: [String], chosen: (Int, Int), make: (Int, Int) -> StrategyConfig) -> Layout {
            var specs: [Spec] = []
            for r in rows.indices {
                for c in columns.indices {
                    let config = make(r, c)
                    specs.append(Spec(row: r, column: c, config: config, control: control(of: config)))
                }
            }
            return Layout(title: title, note: note, rowTitle: rowTitle, columnTitle: columnTitle, rows: rows, columns: columns,
                          chosenRow: chosen.0, chosenColumn: chosen.1, specs: specs)
        }

        let buffers: [Double] = [1, 1.5, 2, 3, 4, 6]
        let reviews = [1, 2, 4, 6, 8]
        let holds = [0, 2, 4, 8, 12]
        let stickies = [0, 2, 4, 8]
        let gates: [(String, StrategyConfig.Gate)] = [("Broad", .broad), ("Acute", .acute), ("Risk budget", .riskBudget),
                                                      ("Credit crisis", .creditCrisis), ("Always on", .always)]
        let tilts = [0.25, 0.5, 0.75, 1.0]
        return [
            grid("Exit buffer × review frequency",
                 "Names leave only below buffer × the top cut; the sleeve is reviewed every N weeks. Hold 4 weeks, sticky gate 4 weeks, 50% tilt.",
                 rowTitle: "Review every", columnTitle: "Exit buffer",
                 rows: reviews.map { $0 == 1 ? "1 week" : "\($0) weeks" },
                 columns: buffers.map { $0 == 1 ? "1× (none)" : String(format: "%g×", $0) },
                 chosen: (reviews.firstIndex(of: 4)!, buffers.firstIndex(of: 3)!)) { r, c in
                rule(buffer: buffers[c], review: reviews[r])
            },
            grid("Minimum hold × sticky gate",
                 "How long a name is kept at least, and how long the stress signal is assumed to last after it fades. 3× buffer, monthly review.",
                 rowTitle: "Sticky gate", columnTitle: "Minimum hold",
                 rows: stickies.map { $0 == 0 ? "off" : "\($0) weeks" },
                 columns: holds.map { $0 == 0 ? "none" : "\($0) wk" },
                 chosen: (stickies.firstIndex(of: 4)!, holds.firstIndex(of: 4)!)) { r, c in
                rule(minHold: holds[c], sticky: stickies[r])
            },
            grid("Stress definition × tilt",
                 "Which stress signal switches the tilt on, and how large the tilt is. Monthly low-turnover rules.",
                 rowTitle: "Stress signal", columnTitle: "Tilt",
                 rows: gates.map(\.0),
                 columns: tilts.map { "\(Int($0 * 100))%" },
                 chosen: (0, tilts.firstIndex(of: 0.5)!)) { r, c in
                rule(gate: gates[r].1, tilt: tilts[c])
            },
        ]
    }

    static func run(universe: [Instrument], series: [String: PriceSeries], benchmark: PriceSeries, vix: [Bar],
                    credit: [Int: Double], quality: [Int: Double], title: String, benchmarkName: String) -> RobustnessReport {
        let layouts = layouts()
        var configs: [StrategyConfig] = []
        var index: [String: Int] = [:]
        for spec in layouts.flatMap(\.specs) {
            for c in [spec.config, spec.control] where index[c.name] == nil {
                index[c.name] = configs.count
                configs.append(c)
            }
        }
        let prepared = universe.compactMap { inst in series[inst.symbol].map { RiskBudgetFactor.Prepared(inst, $0) } }
        let sim = SwitchingStrategy.simulate(configs, prepared: prepared, benchmark: benchmark, vix: vix,
                                             credit: credit, quality: quality)
        let indexCAGR = sim.cagr(sim.indexReturns)
        let net = costLevels.map { bps in configs.indices.map { sim.net($0, bps: bps) } }

        let grids = layouts.map { layout in
            let cells = layout.specs.map { spec -> RobustnessReport.Cell in
                let i = index[spec.config.name]!, j = index[spec.control.name]!
                let scores = costLevels.indices.map { k -> RobustnessReport.Score in
                    let r = net[k][i], control = net[k][j]
                    return .init(excess: sim.cagr(r) - indexCAGR, tExcess: sim.tStat(r, over: sim.indexReturns),
                                 vsControl: sim.cagr(r) - sim.cagr(control), tControl: sim.tStat(r, over: control),
                                 cost: sim.costPerYear(i, bps: costLevels[k]))
                }
                let active = Double(sim.tilted[i].filter { $0 }.count) / Double(max(sim.tilted[i].count, 1))
                return .init(row: spec.row, column: spec.column, scores: scores, activeShare: active)
            }
            return RobustnessReport.Grid(title: layout.title, note: layout.note, rowTitle: layout.rowTitle,
                                         columnTitle: layout.columnTitle, rows: layout.rows, columns: layout.columns,
                                         chosenRow: layout.chosenRow, chosenColumn: layout.chosenColumn, cells: cells)
        }
        return RobustnessReport(universe: title, benchmarkName: benchmarkName, costLevels: costLevels, volIndex: VolIndex.current.name,
                                years: sim.years, grids: grids)
    }
}
