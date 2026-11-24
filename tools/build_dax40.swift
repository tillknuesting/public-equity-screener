// Builds the DAX 40 approximation as a Swift source file.
//
// Qontigo doesn't publish constituents for free, so this takes a pool of German large caps,
// checks each on Yahoo Finance and keeps the 40 largest by free-float market cap (which is how
// the index ranks, give or take its liquidity and fast-entry rules).
//
// Written in Swift rather than Python because Yahoo's key statistics need a session crumb, which
// Yahoo only hands to clients it trusts (URLSession works; curl and urllib get HTTP 429).
//
// Usage:
//     swift tools/build_dax40.swift Sources/MarketScreener/UniverseDAX40.swift

import Foundation

let target = 40

// Xetra tickers without the .DE suffix.
let candidates = """
ADS AIR ALV BAS BAYN BEI BMW BNR CBK CON DTG DBK DB1 DHL DTE EOAN FRE FME G1A HNR1 HEI HEN3 IFX MBG
MRK MTX MUV2 P911 PAH3 QIA RHM RWE SAP SRT3 SIE ENR SHL SY1 VOW3 VNA ZAL G24 1COV PUM KBX HAG TLX
EVD NEM LEG EVK LHA NDA AFX TUI1 RAA BC8 WCH TKA KGX HOT FRA DHER HFG SDF TMV CTS 8TRA HLAG DWNI
""".split(whereSeparator: \.isWhitespace).map(String.init)

// Yahoo's free-float figure lags after takeovers; these are left out by hand.
let excluded = ["1COV": "Covestro: about 91% owned by ADNOC since its 2025 takeover"]

// Names Yahoo spells out at full legal length.
let shortNames = ["MUV2": "Munich Re", "BMW": "BMW", "HNR1": "Hannover Re", "P911": "Porsche AG", "PAH3": "Porsche SE"]

let sectors = [
    "Technology": "Technology", "Financial Services": "Financials", "Healthcare": "Health Care",
    "Consumer Cyclical": "Consumer Disc.", "Consumer Defensive": "Consumer Staples",
    "Communication Services": "Communication", "Industrials": "Industrials", "Energy": "Energy",
    "Basic Materials": "Materials", "Real Estate": "Real Estate", "Utilities": "Utilities",
]
let countries = ["Germany": "DE", "Netherlands": "NL", "France": "FR", "Luxembourg": "LU", "Switzerland": "CH",
                 "United Kingdom": "GB", "Austria": "AT", "Ireland": "IE"]

let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36"

func fetch(_ url: String) async -> Data? {
    var request = URLRequest(url: URL(string: url)!, timeoutInterval: 20)
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    for attempt in 0..<3 {
        if let (data, response) = try? await URLSession.shared.data(for: request),
           (response as? HTTPURLResponse)?.statusCode == 200 { return data }
        try? await Task.sleep(for: .milliseconds(800 * (attempt + 1)))
    }
    return nil
}

struct Found {
    let symbol: String
    let name: String
    let sector: String
    let country: String
    let cap: Double
    let floatFactor: Double
    var floatCap: Double { cap * floatFactor }
}

func lookup(_ ticker: String, crumb: String) async -> Found? {
    let symbol = ticker + ".DE"
    guard let data = await fetch("https://query1.finance.yahoo.com/v10/finance/quoteSummary/\(symbol)?modules=price,defaultKeyStatistics,assetProfile&crumb=\(crumb)"),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let result = ((json["quoteSummary"] as? [String: Any])?["result"] as? [[String: Any]])?.first else { return nil }
    func raw(_ module: String, _ key: String) -> Double? {
        ((result[module] as? [String: Any])?[key] as? [String: Any])?["raw"] as? Double
    }
    let price = result["price"] as? [String: Any] ?? [:]
    let profile = result["assetProfile"] as? [String: Any] ?? [:]
    guard (price["quoteType"] as? String) == "EQUITY", let cap = raw("price", "marketCap"), cap > 0 else { return nil }
    let shares = raw("defaultKeyStatistics", "sharesOutstanding") ?? raw("defaultKeyStatistics", "impliedSharesOutstanding")
    let float = raw("defaultKeyStatistics", "floatShares")
    let factor = (float != nil && shares != nil && shares! > 0) ? min(max(float! / shares!, 0.05), 1) : 1
    var name = (price["longName"] as? String) ?? (price["shortName"] as? String) ?? ticker
    var trimmed = true
    while trimmed {   // "Henkel AG & Co. KGaA" needs several passes
        trimmed = false
        for suffix in [" AG", " SE", " N.V.", " NV", " KGaA", " & Co.", " GmbH", " Aktiengesellschaft", " S.A."] where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
            trimmed = true
        }
    }
    if let short = shortNames[ticker] { name = short }
    return Found(symbol: symbol, name: name.trimmingCharacters(in: .whitespaces),
                 sector: sectors[(profile["sector"] as? String) ?? ""] ?? "Other",
                 country: countries[(profile["country"] as? String) ?? ""] ?? "DE",
                 cap: cap, floatFactor: factor)
}

func run(_ outPath: String) async {
    _ = await fetch("https://fc.yahoo.com/")   // sets the session cookie (the 404 is normal)
    var request = URLRequest(url: URL(string: "https://query1.finance.yahoo.com/v1/test/getcrumb")!)
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    guard let (data, _) = try? await URLSession.shared.data(for: request),
          let crumb = String(data: data, encoding: .utf8), crumb.count < 40, !crumb.contains(" ") else {
        FileHandle.standardError.write("No Yahoo crumb; try again later.\n".data(using: .utf8)!)
        exit(1)
    }
    let encoded = crumb.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? crumb
    var found: [Found] = []
    for (ticker, reason) in excluded { FileHandle.standardError.write("  excluded \(ticker): \(reason)\n".data(using: .utf8)!) }
    for ticker in Array(Set(candidates)).sorted() where excluded[ticker] == nil {
        if let f = await lookup(ticker, crumb: encoded) { found.append(f) }
        else { FileHandle.standardError.write("  skipped \(ticker)\n".data(using: .utf8)!) }
    }
    found.sort { $0.floatCap > $1.floatCap }
    let picked = Array(found.prefix(target))
    FileHandle.standardError.write("\(found.count) of \(candidates.count) candidates found; keeping \(picked.count)\n".data(using: .utf8)!)
    for (i, f) in found.enumerated() {
        let line = String(format: "%3d %-9@ %-32@ cap %6.1fbn float %3.0f%% → %6.1fbn%@\n", i + 1, f.symbol as NSString,
                          String(f.name.prefix(32)) as NSString, f.cap / 1e9, f.floatFactor * 100, f.floatCap / 1e9, i < target ? "" : "  (out)")
        FileHandle.standardError.write(line.data(using: .utf8)!)
    }

    func quoted(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
    var lines = [
        "// Generated by tools/build_dax40.swift. Do not edit by hand; rerun the script instead.",
        "// Approximates the DAX 40: the 40 largest German listings by free-float market cap.",
        "",
        "extension Universe {",
        "    static let dax40: [Instrument] = [",
    ]
    for f in picked {
        lines.append("        .init(symbol: \(quoted(f.symbol)), name: \(quoted(f.name)), country: \(quoted(f.country)), sector: \(quoted(f.sector))),")
    }
    lines += ["    ]", "}", ""]
    try? lines.joined(separator: "\n").write(toFile: outPath, atomically: true, encoding: .utf8)
}

let out = CommandLine.arguments.dropFirst().first ?? "UniverseDAX40.swift"
let done = DispatchSemaphore(value: 0)
Task {
    await run(out)
    done.signal()
}
done.wait()
