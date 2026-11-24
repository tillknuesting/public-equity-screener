import Foundation

enum UniverseKind: String, CaseIterable {
    case msci100 = "stocks", ftse500, ftse100, dax40, stoxx600, sectors

    var title: String {
        switch self {
        case .msci100: "MSCI World top 100"
        case .ftse500: "FTSE Global All Cap top 500"
        case .ftse100: "FTSE 100"
        case .dax40: "DAX 40"
        case .stoxx600: "STOXX Europe 600"
        case .sectors: "Sector ETFs"
        }
    }

    var shortTitle: String {
        switch self {
        case .msci100: "MSCI 100"
        case .ftse500: "FTSE GAC"
        case .ftse100: "FTSE 100"
        case .dax40: "DAX 40"
        case .stoxx600: "STOXX 600"
        case .sectors: "Sectors"
        }
    }

    var fileName: String {
        switch self {
        case .msci100: "universe.json"
        case .ftse500: "ftse-global-all-cap-500.json"
        case .ftse100: "ftse-100.json"
        case .dax40: "dax-40.json"
        case .stoxx600: "stoxx-europe-600.json"
        case .sectors: "sector-etfs.json"
        }
    }

    /// The ETF that tracks the universe's index, used for beta and "market" comparisons.
    var benchmarkSymbol: String {
        switch self {
        case .ftse500: "VT"
        case .ftse100: "ISF.L"   // iShares Core FTSE 100 (dividends included via adjusted closes)
        case .dax40: "^GDAXI"    // the DAX is a total-return index
        case .stoxx600: "EXSA.DE" // iShares STOXX Europe 600 (distributions included via adjusted closes)
        case .msci100, .sectors: "URTH"
        }
    }

    var benchmarkName: String {
        switch self {
        case .ftse500: "FTSE GAC"
        case .ftse100: "FTSE 100"
        case .dax40: "DAX"
        case .stoxx600: "STOXX 600"
        case .msci100, .sectors: "MSCI World"
        }
    }
}

/// The screening universes, as Yahoo Finance tickers. Stocks default to ~100 of the largest
/// MSCI World constituents (MSCI doesn't publish constituents for free, so this approximates
/// by weight). Each list is editable as JSON in Application Support.
enum Universe {
    static let vixSymbol = "^VIX"
    static let vstoxxSymbol = "^V2TX"     // from STOXX's files, not Yahoo
    static let vstoxx3mSymbol = "^V6I3"
    static let vix3mSymbol = "^VIX3M"     // 3-month VIX, for the term structure
    /// High-yield bonds vs. similar-duration Treasuries: a market-implied credit spread.
    static let highYieldSymbol = "HYG", treasurySymbol = "IEI"
    /// Investment-grade corporates (about half BBB) vs. Aaa–A corporates: a quality-spread proxy.
    static let investmentGradeSymbol = "LQD", highGradeSymbol = "QLTA"

    static var directory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MarketScreener", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func fileURL(for kind: UniverseKind) -> URL { directory.appendingPathComponent(kind.fileName) }

    static func load(_ kind: UniverseKind) -> [Instrument] {
        let url = fileURL(for: kind)
        if let data = try? Data(contentsOf: url),
           let list = try? JSONDecoder().decode([Instrument].self, from: data), !list.isEmpty {
            return list
        }
        let list = switch kind {
        case .msci100: defaults
        case .ftse500: ftse500
        case .ftse100: ftse100
        case .dax40: dax40
        case .stoxx600: stoxx600
        case .sectors: sectorETFs
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(list).write(to: url)
        return list
    }

    static let sectorETFs: [Instrument] = [
        // Global sectors (iShares Global, S&P Global 1200 sector indices)
        .init(symbol: "IXN", name: "Global Technology", country: "WW", sector: "Global sector", fund: true),
        .init(symbol: "IXG", name: "Global Financials", country: "WW", sector: "Global sector", fund: true),
        .init(symbol: "IXJ", name: "Global Healthcare", country: "WW", sector: "Global sector", fund: true),
        .init(symbol: "IXC", name: "Global Energy", country: "WW", sector: "Global sector", fund: true),
        .init(symbol: "EXI", name: "Global Industrials", country: "WW", sector: "Global sector", fund: true),
        .init(symbol: "RXI", name: "Global Consumer Disc.", country: "WW", sector: "Global sector", fund: true),
        .init(symbol: "KXI", name: "Global Consumer Staples", country: "WW", sector: "Global sector", fund: true),
        .init(symbol: "JXI", name: "Global Utilities", country: "WW", sector: "Global sector", fund: true),
        .init(symbol: "MXI", name: "Global Materials", country: "WW", sector: "Global sector", fund: true),
        .init(symbol: "IXP", name: "Global Communication", country: "WW", sector: "Global sector", fund: true),
        .init(symbol: "REET", name: "Global REITs", country: "WW", sector: "Global sector", fund: true),
        // US sectors (Select Sector SPDRs)
        .init(symbol: "XLK", name: "US Technology", country: "US", sector: "US sector", fund: true),
        .init(symbol: "XLF", name: "US Financials", country: "US", sector: "US sector", fund: true),
        .init(symbol: "XLV", name: "US Health Care", country: "US", sector: "US sector", fund: true),
        .init(symbol: "XLE", name: "US Energy", country: "US", sector: "US sector", fund: true),
        .init(symbol: "XLI", name: "US Industrials", country: "US", sector: "US sector", fund: true),
        .init(symbol: "XLY", name: "US Consumer Disc.", country: "US", sector: "US sector", fund: true),
        .init(symbol: "XLP", name: "US Consumer Staples", country: "US", sector: "US sector", fund: true),
        .init(symbol: "XLU", name: "US Utilities", country: "US", sector: "US sector", fund: true),
        .init(symbol: "XLB", name: "US Materials", country: "US", sector: "US sector", fund: true),
        .init(symbol: "XLC", name: "US Communication", country: "US", sector: "US sector", fund: true),
        .init(symbol: "XLRE", name: "US Real Estate", country: "US", sector: "US sector", fund: true),
        // Industries
        .init(symbol: "SMH", name: "Semiconductors", country: "US", sector: "Industry", fund: true),
        .init(symbol: "IGV", name: "Software", country: "US", sector: "Industry", fund: true),
        .init(symbol: "XBI", name: "Biotech", country: "US", sector: "Industry", fund: true),
        .init(symbol: "KRE", name: "Regional Banks", country: "US", sector: "Industry", fund: true),
        .init(symbol: "ITA", name: "Aerospace & Defense", country: "US", sector: "Industry", fund: true),
        .init(symbol: "XHB", name: "Homebuilders", country: "US", sector: "Industry", fund: true),
        .init(symbol: "XOP", name: "Oil & Gas E&P", country: "US", sector: "Industry", fund: true),
        .init(symbol: "GDX", name: "Gold Miners", country: "US", sector: "Industry", fund: true),
    ]

    static let defaults: [Instrument] = [
        // United States
        .init(symbol: "NVDA", name: "NVIDIA", country: "US", sector: "Technology"),
        .init(symbol: "AAPL", name: "Apple", country: "US", sector: "Technology"),
        .init(symbol: "MSFT", name: "Microsoft", country: "US", sector: "Technology"),
        .init(symbol: "AMZN", name: "Amazon", country: "US", sector: "Consumer Disc."),
        .init(symbol: "GOOGL", name: "Alphabet", country: "US", sector: "Communication"),
        .init(symbol: "META", name: "Meta Platforms", country: "US", sector: "Communication"),
        .init(symbol: "AVGO", name: "Broadcom", country: "US", sector: "Technology"),
        .init(symbol: "TSLA", name: "Tesla", country: "US", sector: "Consumer Disc."),
        .init(symbol: "BRK-B", name: "Berkshire Hathaway", country: "US", sector: "Financials"),
        .init(symbol: "JPM", name: "JPMorgan Chase", country: "US", sector: "Financials"),
        .init(symbol: "LLY", name: "Eli Lilly", country: "US", sector: "Health Care"),
        .init(symbol: "V", name: "Visa", country: "US", sector: "Financials"),
        .init(symbol: "ORCL", name: "Oracle", country: "US", sector: "Technology"),
        .init(symbol: "XOM", name: "Exxon Mobil", country: "US", sector: "Energy"),
        .init(symbol: "MA", name: "Mastercard", country: "US", sector: "Financials"),
        .init(symbol: "NFLX", name: "Netflix", country: "US", sector: "Communication"),
        .init(symbol: "WMT", name: "Walmart", country: "US", sector: "Consumer Staples"),
        .init(symbol: "COST", name: "Costco", country: "US", sector: "Consumer Staples"),
        .init(symbol: "JNJ", name: "Johnson & Johnson", country: "US", sector: "Health Care"),
        .init(symbol: "PLTR", name: "Palantir", country: "US", sector: "Technology"),
        .init(symbol: "HD", name: "Home Depot", country: "US", sector: "Consumer Disc."),
        .init(symbol: "ABBV", name: "AbbVie", country: "US", sector: "Health Care"),
        .init(symbol: "PG", name: "Procter & Gamble", country: "US", sector: "Consumer Staples"),
        .init(symbol: "BAC", name: "Bank of America", country: "US", sector: "Financials"),
        .init(symbol: "AMD", name: "AMD", country: "US", sector: "Technology"),
        .init(symbol: "UNH", name: "UnitedHealth", country: "US", sector: "Health Care"),
        .init(symbol: "GE", name: "GE Aerospace", country: "US", sector: "Industrials"),
        .init(symbol: "CVX", name: "Chevron", country: "US", sector: "Energy"),
        .init(symbol: "KO", name: "Coca-Cola", country: "US", sector: "Consumer Staples"),
        .init(symbol: "CSCO", name: "Cisco", country: "US", sector: "Technology"),
        .init(symbol: "IBM", name: "IBM", country: "US", sector: "Technology"),
        .init(symbol: "WFC", name: "Wells Fargo", country: "US", sector: "Financials"),
        .init(symbol: "MU", name: "Micron", country: "US", sector: "Technology"),
        .init(symbol: "PM", name: "Philip Morris", country: "US", sector: "Consumer Staples"),
        .init(symbol: "TMUS", name: "T-Mobile US", country: "US", sector: "Communication"),
        .init(symbol: "MS", name: "Morgan Stanley", country: "US", sector: "Financials"),
        .init(symbol: "GS", name: "Goldman Sachs", country: "US", sector: "Financials"),
        .init(symbol: "CRM", name: "Salesforce", country: "US", sector: "Technology"),
        .init(symbol: "ABT", name: "Abbott", country: "US", sector: "Health Care"),
        .init(symbol: "AXP", name: "American Express", country: "US", sector: "Financials"),
        .init(symbol: "LIN", name: "Linde", country: "US", sector: "Materials"),
        .init(symbol: "MCD", name: "McDonald's", country: "US", sector: "Consumer Disc."),
        .init(symbol: "CAT", name: "Caterpillar", country: "US", sector: "Industrials"),
        .init(symbol: "RTX", name: "RTX", country: "US", sector: "Industrials"),
        .init(symbol: "MRK", name: "Merck & Co.", country: "US", sector: "Health Care"),
        .init(symbol: "DIS", name: "Walt Disney", country: "US", sector: "Communication"),
        .init(symbol: "PEP", name: "PepsiCo", country: "US", sector: "Consumer Staples"),
        .init(symbol: "LRCX", name: "Lam Research", country: "US", sector: "Technology"),
        .init(symbol: "UBER", name: "Uber", country: "US", sector: "Industrials"),
        .init(symbol: "AMAT", name: "Applied Materials", country: "US", sector: "Technology"),
        .init(symbol: "APP", name: "AppLovin", country: "US", sector: "Technology"),
        .init(symbol: "INTU", name: "Intuit", country: "US", sector: "Technology"),
        .init(symbol: "NOW", name: "ServiceNow", country: "US", sector: "Technology"),
        .init(symbol: "T", name: "AT&T", country: "US", sector: "Communication"),
        .init(symbol: "C", name: "Citigroup", country: "US", sector: "Financials"),
        .init(symbol: "GEV", name: "GE Vernova", country: "US", sector: "Industrials"),
        .init(symbol: "TMO", name: "Thermo Fisher", country: "US", sector: "Health Care"),
        .init(symbol: "ISRG", name: "Intuitive Surgical", country: "US", sector: "Health Care"),
        .init(symbol: "BKNG", name: "Booking Holdings", country: "US", sector: "Consumer Disc."),
        .init(symbol: "VZ", name: "Verizon", country: "US", sector: "Communication"),
        .init(symbol: "QCOM", name: "Qualcomm", country: "US", sector: "Technology"),
        .init(symbol: "INTC", name: "Intel", country: "US", sector: "Technology"),
        .init(symbol: "BLK", name: "BlackRock", country: "US", sector: "Financials"),
        .init(symbol: "SCHW", name: "Charles Schwab", country: "US", sector: "Financials"),
        .init(symbol: "KLAC", name: "KLA", country: "US", sector: "Technology"),
        .init(symbol: "ANET", name: "Arista Networks", country: "US", sector: "Technology"),
        .init(symbol: "TXN", name: "Texas Instruments", country: "US", sector: "Technology"),
        .init(symbol: "AMGN", name: "Amgen", country: "US", sector: "Health Care"),
        .init(symbol: "BA", name: "Boeing", country: "US", sector: "Industrials"),
        .init(symbol: "NEE", name: "NextEra Energy", country: "US", sector: "Utilities"),
        .init(symbol: "SPGI", name: "S&P Global", country: "US", sector: "Financials"),
        .init(symbol: "ADBE", name: "Adobe", country: "US", sector: "Technology"),
        .init(symbol: "GILD", name: "Gilead Sciences", country: "US", sector: "Health Care"),
        .init(symbol: "PFE", name: "Pfizer", country: "US", sector: "Health Care"),
        .init(symbol: "BSX", name: "Boston Scientific", country: "US", sector: "Health Care"),
        // Europe, Japan, Canada, Australia
        .init(symbol: "ASML.AS", name: "ASML", country: "NL", sector: "Technology"),
        .init(symbol: "SAP.DE", name: "SAP", country: "DE", sector: "Technology"),
        .init(symbol: "NESN.SW", name: "Nestlé", country: "CH", sector: "Consumer Staples"),
        .init(symbol: "ROP.SW", name: "Roche", country: "CH", sector: "Health Care"),
        .init(symbol: "NOVN.SW", name: "Novartis", country: "CH", sector: "Health Care"),
        .init(symbol: "AZN.L", name: "AstraZeneca", country: "GB", sector: "Health Care"),
        .init(symbol: "HSBA.L", name: "HSBC", country: "GB", sector: "Financials"),
        .init(symbol: "SHEL.L", name: "Shell", country: "GB", sector: "Energy"),
        .init(symbol: "7203.T", name: "Toyota", country: "JP", sector: "Consumer Disc."),
        .init(symbol: "6758.T", name: "Sony", country: "JP", sector: "Consumer Disc."),
        .init(symbol: "8306.T", name: "Mitsubishi UFJ", country: "JP", sector: "Financials"),
        .init(symbol: "6501.T", name: "Hitachi", country: "JP", sector: "Industrials"),
        .init(symbol: "SIE.DE", name: "Siemens", country: "DE", sector: "Industrials"),
        .init(symbol: "ALV.DE", name: "Allianz", country: "DE", sector: "Financials"),
        .init(symbol: "MC.PA", name: "LVMH", country: "FR", sector: "Consumer Disc."),
        .init(symbol: "SU.PA", name: "Schneider Electric", country: "FR", sector: "Industrials"),
        .init(symbol: "CBA.AX", name: "Commonwealth Bank", country: "AU", sector: "Financials"),
        .init(symbol: "RY.TO", name: "Royal Bank of Canada", country: "CA", sector: "Financials"),
        .init(symbol: "SHOP.TO", name: "Shopify", country: "CA", sector: "Technology"),
        .init(symbol: "TD.TO", name: "Toronto-Dominion", country: "CA", sector: "Financials"),
        .init(symbol: "NOVO-B.CO", name: "Novo Nordisk", country: "DK", sector: "Health Care"),
        .init(symbol: "SAN.MC", name: "Banco Santander", country: "ES", sector: "Financials"),
        .init(symbol: "UBSG.SW", name: "UBS", country: "CH", sector: "Financials"),
        .init(symbol: "RHM.DE", name: "Rheinmetall", country: "DE", sector: "Industrials"),
        .init(symbol: "DTE.DE", name: "Deutsche Telekom", country: "DE", sector: "Communication"),
    ]
}

/// Which implied-volatility index drives spikes, gauges and the stress regime: VIX (S&P 500
/// options) or VSTOXX (Euro Stoxx 50 options). Launch with `-volIndex VSTOXX` to override once.
enum VolIndex: String, CaseIterable, Sendable {
    case vix = "VIX"
    case vstoxx = "VSTOXX"

    static var current: VolIndex {
        VolIndex(rawValue: UserDefaults.standard.string(forKey: "volIndex") ?? "") ?? .vix
    }

    var name: String { rawValue }
    var symbol: String { self == .vix ? Universe.vixSymbol : Universe.vstoxxSymbol }
    var threeMonthSymbol: String { self == .vix ? Universe.vix3mSymbol : Universe.vstoxx3mSymbol }
    var threeMonthName: String { self == .vix ? "VIX3M" : "VSTOXX 3M" }
    var market: String { self == .vix ? "S&P 500" : "Euro Stoxx 50" }
}
