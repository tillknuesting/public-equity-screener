import Foundation

struct Instrument: Codable, Hashable, Identifiable, Sendable {
    var symbol: String
    var name: String
    var country: String   // ISO 3166 alpha-2
    var sector: String
    var fund: Bool?       // ETFs: no company fundamentals

    var id: String { symbol }
    var isFinancial: Bool { sector == "Financials" }
    var isFund: Bool { fund == true }

    enum Session { case asiaPacific, europe, americas }

    /// Trading session, from the Yahoo exchange suffix (US-listed ADRs trade in the US session).
    var session: Session {
        guard let dot = symbol.lastIndex(of: ".") else { return .americas }
        let suffix = String(symbol[symbol.index(after: dot)...])
        if Self.asiaPacificSuffixes.contains(suffix) { return .asiaPacific }
        if Self.americasSuffixes.contains(suffix) { return .americas }
        return .europe
    }

    private static let asiaPacificSuffixes: Set<String> = ["T", "HK", "SS", "SZ", "KS", "KQ", "TW", "TWO", "AX", "NZ",
                                                           "SI", "NS", "BO", "JK", "BK", "KL", "SR", "QA", "KW", "AE"]
    private static let americasSuffixes: Set<String> = ["TO", "V", "NE", "MX", "SA", "SN"]

    var flag: String {
        if country == "WW" { return "🌐" }
        return country.uppercased().unicodeScalars
            .compactMap { UnicodeScalar(127397 + $0.value) }
            .map(String.init).joined()
    }
}

/// One daily bar. `day` is the exchange-local calendar date as yyyymmdd.
/// Prices are dividend/split adjusted so ex-dividend gaps don't look like sell-offs.
struct Bar: Codable, Hashable, Sendable {
    let day: Int
    let open: Double
    let high: Double
    let low: Double
    let close: Double
    let volume: Double

    var date: Date { TradingDay.date(day) }

    init(day: Int, open: Double, high: Double, low: Double, close: Double, volume: Double) {
        self.day = day
        self.open = open
        self.high = high
        self.low = low
        self.close = close
        self.volume = volume
    }

    // Encoded as a compact array [day, o, h, l, c, v]: the cache holds ~600 series × 750 bars.
    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        day = try c.decode(Int.self)
        open = try c.decode(Double.self)
        high = try c.decode(Double.self)
        low = try c.decode(Double.self)
        close = try c.decode(Double.self)
        volume = try c.decode(Double.self)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(day)
        for v in [open, high, low, close] { try c.encode((v * 10_000).rounded() / 10_000) }
        try c.encode(volume)
    }
}

struct PriceSeries: Sendable {
    let symbol: String
    let currency: String
    let bars: [Bar]
    let marketTime: Date?
    /// Closes and volumes as flat arrays: the screen and the backtest read them many times over.
    let closes: [Double]
    let volumes: [Double]

    init(symbol: String, currency: String, bars: [Bar], marketTime: Date?) {
        self.symbol = symbol
        self.currency = currency
        self.bars = bars
        self.marketTime = marketTime
        closes = bars.map(\.close)
        volumes = bars.map(\.volume)
    }
}

extension PriceSeries {
    /// The same series with Yahoo's worst price glitches repaired (see `PriceRepair`).
    func repaired() -> PriceSeries {
        let fixed = PriceRepair.repair(bars)
        return fixed == bars ? self : PriceSeries(symbol: symbol, currency: currency, bars: fixed, marketTime: marketTime)
    }
}

/// Yahoo's daily history has two kinds of errors that wreck volatility-based signals:
/// London prices that flip between pence and pounds for a few days (×100 and back), and early
/// history that belongs to another line or unit before a huge one-off jump.
enum PriceRepair {
    static func repair(_ input: [Bar]) -> [Bar] {
        var bars = input
        guard bars.count > 20 else { return bars }
        func scaled(_ b: Bar, _ f: Double) -> Bar {
            Bar(day: b.day, open: b.open * f, high: b.high * f, low: b.low * f, close: b.close * f, volume: b.volume)
        }
        // 1. Unit flips: a ~100× move that reverses within 30 sessions; rescale the stretch in between.
        var i = 1
        while i < bars.count {
            let r = bars[i].close / bars[i - 1].close
            if r > 0, (r < 1 / 50 && r > 1 / 200) || (r > 50 && r < 200) {
                let factor = r < 1 ? 100.0 : 0.01
                if let end = (i + 1..<min(i + 30, bars.count)).first(where: {
                    let back = bars[$0].close / bars[$0 - 1].close
                    return factor == 100 ? (back > 50 && back < 200) : (back < 1 / 50 && back > 1 / 200)
                }) {
                    for k in i..<end { bars[k] = scaled(bars[k], factor) }
                    i = end + 1
                    continue
                }
            }
            i += 1
        }
        // 2. One-day spikes that fully reverse the next session (a bad print): use the prior bar.
        for k in 1..<(bars.count - 1) where bars[k - 1].close > 0 && bars[k].close > 0 {
            let up = bars[k].close / bars[k - 1].close, back = bars[k + 1].close / bars[k].close
            if (up > 1.7 || up < 0.6), (0.9...1.1).contains(up * back) {
                bars[k] = Bar(day: bars[k].day, open: bars[k - 1].close, high: bars[k - 1].close, low: bars[k - 1].close,
                              close: bars[k - 1].close, volume: bars[k].volume)
            }
        }
        // 3. Garbage early history: cut before the last jump of more than 30×, or before a big jump
        //    from a price that is under a fifth of the past year's median.
        let recent = bars.suffix(252).map(\.close).sorted()
        let median = recent[recent.count / 2]
        var cut = 0
        for k in 1..<bars.count where bars[k - 1].close > 0 {
            let r = bars[k].close / bars[k - 1].close
            if r > 30 || r < 1 / 30 || ((r > 1.8 || r < 0.55) && bars[k - 1].close < median * 0.2 && bars[k].close < bars[k - 1].close * 30) {
                cut = k
            }
        }
        if cut > 0, bars.count - cut > 60 { bars.removeFirst(cut) }
        return bars
    }
}

/// Latest trailing-twelve-month figures from Yahoo's fundamentals timeseries.
/// Values are in `reportCurrency`; market cap is in `marketCapCurrency` as of `marketCapDay`.
struct Fundamentals: Codable, Sendable {
    var fcf: Double?
    var revenue: Double?
    var revenueGrowth: Double?      // year over year, see YahooClient.fetchFundamentals
    var operatingIncome: Double?
    var netIncome: Double?
    var reportCurrency: String?
    var marketCap: Double?
    var marketCapDay: Int?
    var marketCapCurrency: String?
    var pe: Double?
    var forwardPE: Double?
}

struct NewsItem: Codable, Hashable, Identifiable, Sendable {
    let title: String
    let link: String
    let date: Date
    let summary: String?

    var id: String { link.isEmpty ? title : link }

    var source: String {
        guard let host = URL(string: link)?.host() else { return "" }
        if host.contains("yahoo") { return "Yahoo" }
        return host.replacingOccurrences(of: "www.", with: "")
    }

    /// Headlines about company-specific events (earnings, ratings, deals, legal...).
    /// A drop with none of these is more likely flow-driven than fundamental.
    var isCatalyst: Bool {
        let lower = title.lowercased()
        if Self.catalystPhrases.contains(where: lower.contains) { return true }
        let words = lower.split { !$0.isLetter && !$0.isNumber }
        return words.contains { Self.catalystWords.contains(String($0)) }
    }

    private static let catalystPhrases = ["price target", "dividend", "share buyback", "stock split"]
    private static let catalystWords: Set<String> = [
        "earnings", "results", "quarter", "quarterly", "q1", "q2", "q3", "q4", "guidance", "outlook",
        "forecast", "downgrade", "downgrades", "downgraded", "upgrade", "upgrades", "upgraded",
        "lawsuit", "sued", "sues", "probe", "investigation", "antitrust", "fda", "recall", "ceo", "cfo",
        "resigns", "resign", "acquire", "acquires", "acquisition", "merger", "buyout", "takeover",
        "misses", "miss", "beats", "warns", "warning", "profit", "layoffs", "tariff", "tariffs",
        "ban", "fined", "sanctions", "halts", "delay", "delays", "eps",
    ]
}

extension Array where Element == Bar {
    /// Index of the last bar dated on or before `day` (binary search; bars are sorted).
    func lastIndex(onOrBefore day: Int) -> Int? {
        var lo = 0, hi = count - 1, found: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if self[mid].day <= day { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return found
    }
}

/// An earnings report on its exchange's local date. Yahoo's report times are only reliable for
/// US listings; elsewhere the time is unknown and the report may move either session.
struct EarningsDate: Codable, Hashable, Sendable {
    let day: Int             // yyyymmdd, exchange-local
    let estimate: Bool       // Yahoo's date is not confirmed yet
    var afterClose: Bool?    // nil = time unknown

    /// The sessions whose close may reflect the report.
    var reactionDays: [Int] {
        switch afterClose {
        case true?: [TradingDay.nextWeekday(day)]
        case false?: [day]
        case nil: [day, TradingDay.nextWeekday(day)]
        }
    }

    var timingNote: String {
        switch afterClose {
        case true?: "after the close"
        case false?: "before the open"
        case nil: "time not given"
        }
    }

    /// Keeps confirmed past reports from earlier fetches and replaces everything else.
    static func merge(_ old: [EarningsDate], _ fresh: [EarningsDate], today: Int) -> [EarningsDate] {
        let kept = old.filter { !$0.estimate && $0.day <= today && !fresh.map(\.day).contains($0.day) }
        return Array((kept + fresh).sorted { $0.day < $1.day }.suffix(8))
    }
}

enum TradingDay {
    private static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    static func from(timestamp: Int, gmtOffset: Int) -> Int {
        let d = Date(timeIntervalSince1970: TimeInterval(timestamp + gmtOffset))
        let c = utc.dateComponents([.year, .month, .day], from: d)
        return c.year! * 10000 + c.month! * 100 + c.day!
    }

    static func from(isoDate: String) -> Int? {
        Int(isoDate.replacingOccurrences(of: "-", with: ""))
    }

    static func day(from date: Date) -> Int {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return c.year! * 10000 + c.month! * 100 + c.day!
    }

    static func date(_ day: Int) -> Date {
        let comps = DateComponents(year: day / 10000, month: (day / 100) % 100, day: day % 100, hour: 12)
        return Calendar.current.date(from: comps) ?? .distantPast
    }

    static func nextWeekday(_ day: Int) -> Int {
        var d = date(day)
        repeat { d = d.addingTimeInterval(86_400) } while Calendar.current.isDateInWeekend(d)
        return self.day(from: d)
    }

    static func days(from a: Int, to b: Int) -> Int {
        Int((date(b).timeIntervalSince(date(a)) / 86_400).rounded())
    }

    static func label(_ day: Int) -> String {
        date(day).formatted(.dateTime.day().month(.abbreviated).year())
    }
}

enum Currency {
    /// Yahoo quotes London in pence (GBp) etc.; fundamentals use the major unit.
    static func normalize(_ code: String?) -> String? {
        guard let code, !code.isEmpty else { return nil }
        switch code {
        case "GBp", "GBX": return "GBP"
        case "ZAc": return "ZAR"
        case "ILA": return "ILS"
        default: return code.uppercased()
        }
    }
}

extension Double {
    /// Signed percent, e.g. "+3.2%" / "-1.0%".
    var pct: String { String(format: "%+.1f%%", self * 100) }

    /// Compact money, e.g. "4.9T", "136.7B".
    var compact: String {
        let a = abs(self)
        switch a {
        case 1e12...: return String(format: "%.2fT", self / 1e12)
        case 1e9...: return String(format: "%.1fB", self / 1e9)
        case 1e6...: return String(format: "%.0fM", self / 1e6)
        default: return String(format: "%.0f", self)
        }
    }
}
