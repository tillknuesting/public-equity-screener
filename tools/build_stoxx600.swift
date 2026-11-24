// Builds the STOXX Europe 600 approximation as a Swift source file.
//
// Qontigo doesn't publish constituents for free, so this lists every equity on the main
// exchanges of the index's 17 countries with Yahoo's screener, keeps one line per company,
// drops foreign cross-listings, and ranks the rest by free-float market cap in EUR. That is how
// the index is formed, give or take its liquidity screens and buffer rules.
//
// Written in Swift because Yahoo's screener and key statistics need a session crumb, which
// Yahoo only hands to clients it trusts (URLSession works; curl and urllib get HTTP 429).
//
// Usage:
//     swift tools/build_stoxx600.swift Sources/MarketScreener/UniverseSTOXX600.swift

import Foundation

let target = 600
let minimumClassCapEUR = 1.0e9   // before free float; the 600th name is well above this after it

/// Yahoo exchange code → the country whose companies count there first.
let exchanges: [(code: String, country: String)] = [
    ("LSE", "GB"), ("GER", "DE"), ("PAR", "FR"), ("AMS", "NL"), ("BRU", "BE"), ("LIS", "PT"),
    ("MIL", "IT"), ("MCE", "ES"), ("EBS", "CH"), ("STO", "SE"), ("CPH", "DK"), ("HEL", "FI"),
    ("OSL", "NO"), ("ISE", "IE"), ("VIE", "AT"), ("WSE", "PL"),
]

/// Yahoo's company countries → STOXX country. Channel Islands, Isle of Man and Bermuda companies
/// listed in London count as UK, as STOXX treats them.
let countries: [String: String] = [
    "United Kingdom": "GB", "Germany": "DE", "France": "FR", "Netherlands": "NL", "Belgium": "BE",
    "Portugal": "PT", "Italy": "IT", "Spain": "ES", "Switzerland": "CH", "Sweden": "SE", "Denmark": "DK",
    "Finland": "FI", "Norway": "NO", "Ireland": "IE", "Austria": "AT", "Poland": "PL", "Luxembourg": "LU",
    "Jersey": "GB", "Guernsey": "GB", "Isle of Man": "GB", "Bermuda": "GB",
]

let sectors = [
    "Technology": "Technology", "Financial Services": "Financials", "Healthcare": "Health Care",
    "Consumer Cyclical": "Consumer Disc.", "Consumer Defensive": "Consumer Staples",
    "Communication Services": "Communication", "Industrials": "Industrials", "Energy": "Energy",
    "Basic Materials": "Materials", "Real Estate": "Real Estate", "Utilities": "Utilities",
]

let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36"

func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

func request(_ url: String, body: Data? = nil) async -> Data? {
    var r = URLRequest(url: URL(string: url)!, timeoutInterval: 25)
    r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    if let body {
        r.httpMethod = "POST"
        r.httpBody = body
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    for attempt in 0..<4 {
        if let (data, response) = try? await URLSession.shared.data(for: r),
           (response as? HTTPURLResponse)?.statusCode == 200 { return data }
        try? await Task.sleep(for: .milliseconds(1000 * (attempt + 1)))
    }
    return nil
}

func json(_ data: Data?) -> [String: Any]? { data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }

struct Listing {
    var symbol: String
    let exchange: String
    let exchangeCountry: String
    let name: String
    let classCapEUR: Double
    let tradedEUR: Double      // 3-month average daily value traded
}

struct Member {
    let listing: Listing
    let country: String
    let sector: String
    let floatFactor: Double
    var floatCapEUR: Double { listing.classCapEUR * floatFactor }
}

/// What Yahoo's profile says about one group of lines, before groups of the same company merge.
struct Profile {
    let lines: [Listing]
    let identity: String       // the company's website host, the same on every exchange
    let countryName: String
    let country: String
    let sector: String
    let floatFactor: Double
}

/// Yahoo suffix of each country's home exchange.
let homeSuffix = ["GB": "L", "DE": "DE", "FR": "PA", "NL": "AS", "BE": "BR", "PT": "LS", "IT": "MI", "ES": "MC", "CH": "SW",
                  "SE": "ST", "DK": "CO", "FI": "HE", "NO": "OL", "IE": "IR", "AT": "VI", "PL": "WA"]

// Names Yahoo spells out at full legal length.
let shortNames = ["MUV2.DE": "Munich Re", "HNR1.DE": "Hannover Re", "BMW.DE": "BMW", "PAH3.DE": "Porsche SE", "P911.DE": "Porsche AG",
                  "MC.PA": "LVMH", "PKO.WA": "PKO Bank Polski", "ERIC-B.ST": "Ericsson", "BBVA.MC": "BBVA", "MB.MI": "Mediobanca",
                  "ACS.MC": "ACS", "REC.MI": "Recordati", "SCA-B.ST": "SCA", "ATS.VI": "AT&S", "PZU.WA": "PZU",
                  "PEO.WA": "Bank Pekao", "KGH.WA": "KGHM", "PGE.WA": "PGE"]

// Taken over, with Yahoo's free-float figure lagging; left out by hand.
let excluded = ["covestro": "about 91% owned by ADNOC since its 2025 takeover"]

/// "Atlas Copco AB ser. A" and "ATLAS COPCO AB" → "atlas copco": one key per company.
func companyKey(_ name: String) -> String {
    var s = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
    for pattern in [#"\bser\.?\s*[a-z]\b"#, #"\bclass\s+[a-z]\b"#, #"\b(series|serie)\s+[a-z]\b"#, #"[\-\s][ab]$"#, #"\(.*?\)"#, #"[^a-z0-9 ]"#] {
        s = s.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
    }
    let legal: Set = ["plc", "ag", "se", "sa", "nv", "n", "v", "ab", "asa", "as", "a", "s", "oyj", "spa", "p", "ltd",
                      "limited", "group", "holding", "holdings", "the", "co", "kgaa", "publ", "corporation", "inc", "aktiengesellschaft"]
    let words = s.split(separator: " ").map(String.init).filter { !legal.contains($0) }
    return words.prefix(3).joined(separator: " ")
}

func fxToEUR() async -> [String: Double] {
    var out = ["EUR": 1.0]
    for ccy in ["GBP", "CHF", "SEK", "DKK", "NOK", "PLN", "USD"] {
        let url = "https://query1.finance.yahoo.com/v8/finance/chart/\(ccy)EUR=X?range=5d&interval=1d"
        if let meta = ((json(await request(url))?["chart"] as? [String: Any])?["result"] as? [[String: Any]])?.first?["meta"] as? [String: Any],
           let rate = meta["regularMarketPrice"] as? Double { out[ccy] = rate }
    }
    if let gbp = out["GBP"] { out["GBp"] = gbp / 100; out["GBX"] = gbp / 100 }
    return out
}

func screen(_ exchange: String, country: String, crumb: String, fx: [String: Double]) async -> [Listing] {
    var out: [Listing] = []
    var offset = 0
    while true {
        let query: [String: Any] = [
            "size": 250, "offset": offset, "sortField": "intradaymarketcap", "sortType": "DESC", "quoteType": "EQUITY",
            "query": ["operator": "AND", "operands": [
                ["operator": "EQ", "operands": ["exchange", exchange]],
                ["operator": "GT", "operands": ["intradaymarketcap", 300_000_000]],
            ]],
            "userId": "", "userIdType": "guid",
        ]
        let url = "https://query1.finance.yahoo.com/v1/finance/screener?crumb=\(crumb)&lang=en-US&region=US&formatted=false"
        guard let result = ((json(await request(url, body: try! JSONSerialization.data(withJSONObject: query)))?["finance"] as? [String: Any])?["result"] as? [[String: Any]])?.first,
              let quotes = result["quotes"] as? [[String: Any]], !quotes.isEmpty else { break }
        for q in quotes {
            guard (q["quoteType"] as? String) == "EQUITY", let symbol = q["symbol"] as? String,
                  let ccy = q["currency"] as? String, let rate = fx[ccy],
                  let price = q["regularMarketPrice"] as? Double, let shares = q["sharesOutstanding"] as? Double,
                  shares > 0, price > 0 else { continue }
            let name = (q["longName"] as? String) ?? (q["shortName"] as? String) ?? symbol
            let volume = (q["averageDailyVolume3Month"] as? Double) ?? 0
            out.append(Listing(symbol: symbol, exchange: exchange, exchangeCountry: country, name: name,
                               classCapEUR: shares * price * rate, tradedEUR: volume * price * rate))
        }
        offset += quotes.count
        if offset >= (result["total"] as? Int ?? 0) || offset >= 1500 { break }
    }
    return out
}

/// Boards where Xetra, Vienna and SIX list foreign stocks second-hand; London's international
/// order book lines start with a digit (0Y0Y.L = Accenture).
func isCrossListing(_ l: Listing) -> Bool {
    ["GER", "VIE", "EBS"].contains(l.exchange) || (l.exchange == "LSE" && l.symbol.first?.isNumber == true)
}

/// The company's home line if it has one (most traded class first); otherwise a main-board
/// listing abroad (Airbus in Paris, Stellantis in Milan), never a cross-listing board.
func chooseLine(_ lines: [Listing], country: String) -> Listing? {
    let home = lines.filter { $0.exchangeCountry == country && !($0.exchange == "LSE" && $0.symbol.first?.isNumber == true) }
    if let best = home.max(by: { $0.tradedEUR < $1.tradedEUR }) { return best }
    return lines.filter { !isCrossListing($0) }.max { $0.tradedEUR < $1.tradedEUR }
}

func profile(_ lines: [Listing], crumb: String) async -> Profile? {
    guard let probe = lines.max(by: { $0.tradedEUR < $1.tradedEUR }) else { return nil }
    let url = "https://query1.finance.yahoo.com/v10/finance/quoteSummary/\(probe.symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? probe.symbol)?modules=assetProfile,defaultKeyStatistics&crumb=\(crumb)"
    guard let result = ((json(await request(url))?["quoteSummary"] as? [String: Any])?["result"] as? [[String: Any]])?.first else { return nil }
    let profile = result["assetProfile"] as? [String: Any] ?? [:]
    let stats = result["defaultKeyStatistics"] as? [String: Any] ?? [:]
    func raw(_ key: String) -> Double? { (stats[key] as? [String: Any])?["raw"] as? Double }
    guard let countryName = profile["country"] as? String, let country = countries[countryName] else { return nil }
    let website = (profile["website"] as? String).flatMap { URL(string: $0)?.host?.lowercased() }
        .map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
    let shares = raw("sharesOutstanding") ?? raw("impliedSharesOutstanding")
    let float = raw("floatShares")
    let factor = (float != nil && shares != nil && shares! > 0) ? min(max(float! / shares!, 0.05), 1) : 1
    return Profile(lines: lines, identity: website ?? companyKey(probe.name), countryName: countryName, country: country,
                   sector: sectors[(profile["sector"] as? String) ?? ""] ?? "Other", floatFactor: factor)
}

func cleanName(_ name: String) -> String {
    var n = name
    var trimmed = true
    while trimmed {
        trimmed = false
        for suffix in [" Société anonyme", " société anonyme", ", Société Européenne", " Société en commandite par actions",
                       " Spólka Akcyjna", " Spółka Akcyjna", " Public Limited Company", " Oyj Abp", " Ltd.",
                       " plc", " PLC", " Plc", " p.l.c.", " P.L.C.", " S.E.", " AG", " SE", " S.A.", " SA", " N.V.", " NV", " AB (publ)", " AB", " ASA", " A/S",
                       " Oyj", " S.p.A.", " SpA", " Limited", " Ltd", " KGaA", " & Co.", " Aktiengesellschaft", " (publ)", ","]
            where n.hasSuffix(suffix) {
            n = String(n.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            trimmed = true
        }
    }
    return n
}

func run(_ outPath: String) async {
    _ = await request("https://fc.yahoo.com/")   // sets the session cookie (a 404 is normal)
    guard let data = await request("https://query1.finance.yahoo.com/v1/test/getcrumb"),
          let raw = String(data: data, encoding: .utf8), raw.count < 40, !raw.contains(" ") else {
        log("No Yahoo crumb; try again later.")
        exit(1)
    }
    let crumb = raw.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? raw
    let fx = await fxToEUR()
    log("FX to EUR: " + fx.sorted { $0.key < $1.key }.map { "\($0.key) \(String(format: "%.4f", $0.value))" }.joined(separator: ", "))

    var listings: [Listing] = []
    for (code, country) in exchanges {
        let found = await screen(code, country: country, crumb: crumb, fx: fx)
        log("\(code): \(found.count) listings")
        listings += found
    }

    // Group every line (exchange, share class) by company; the line is chosen once the country is known.
    var byCompany: [String: [Listing]] = [:]
    for l in listings where l.classCapEUR >= minimumClassCapEUR { byCompany[companyKey(l.name), default: []].append(l) }
    let candidates = byCompany.values.sorted { ($0.map(\.classCapEUR).max() ?? 0) > ($1.map(\.classCapEUR).max() ?? 0) }
    log("\(candidates.count) companies above €\(Int(minimumClassCapEUR / 1e9))bn after merging lines")

    // Country, sector, free float and website, a few requests at a time.
    var profiles: [Profile] = []
    var dropped = 0
    await withTaskGroup(of: Profile?.self) { group in
        var queue = candidates.makeIterator()
        for _ in 0..<5 { if let l = queue.next() { group.addTask { await profile(l, crumb: crumb) } } }
        while let result = await group.next() {
            if let p = result { profiles.append(p) } else { dropped += 1 }
            if let l = queue.next() { group.addTask { await profile(l, crumb: crumb) } }
        }
    }

    // Name variants ("ALLIANZ SE NA O.N." on Xetra, "Allianz SE" elsewhere) share a website:
    // merge them, then pick the company's home line (or a main-board line abroad).
    var members: [Member] = []
    for (_, same) in Dictionary(grouping: profiles, by: \.identity) {
        let first = same[0]
        let lines = same.flatMap(\.lines)
        if let reason = excluded.first(where: { key, _ in lines.contains { companyKey($0.name).contains(key) } }) {
            log("  excluded \(reason.key): \(reason.value)")
            continue
        }
        guard let listing = chooseLine(lines, country: first.country) else { dropped += 1; continue }
        // Offshore holding companies only count as UK when they list in London.
        if ["Jersey", "Guernsey", "Isle of Man", "Bermuda"].contains(first.countryName), listing.exchange != "LSE" { dropped += 1; continue }
        members.append(Member(listing: listing, country: first.country, sector: first.sector, floatFactor: first.floatFactor))
    }
    log("\(members.count) European companies, \(dropped) dropped (foreign, unknown or no data)")

    // Yahoo's screener misses some home lines (Allianz isn't in its Xetra list), so a company
    // left on a foreign line gets its ticker tried at home, kept only if Yahoo names the same company.
    let abroad = members.indices.filter { members[$0].listing.exchangeCountry != members[$0].country && homeSuffix[members[$0].country] != nil }
    let tries = abroad.map { i -> String in
        let symbol = members[i].listing.symbol
        let base = symbol.split(separator: ".").dropLast().joined(separator: ".")
        return base + "." + homeSuffix[members[i].country]!
    }
    var homeNames: [String: String] = [:]
    for start in stride(from: 0, to: tries.count, by: 40) {
        let batch = tries[start..<min(start + 40, tries.count)].joined(separator: ",")
        let url = "https://query1.finance.yahoo.com/v7/finance/quote?symbols=\(batch)&crumb=\(crumb)"
        for q in ((json(await request(url))?["quoteResponse"] as? [String: Any])?["result"] as? [[String: Any]]) ?? []
            where (q["quoteType"] as? String) == "EQUITY" && q["regularMarketPrice"] != nil {
            if let symbol = q["symbol"] as? String { homeNames[symbol] = (q["longName"] as? String) ?? (q["shortName"] as? String) }
        }
    }
    for (i, home) in zip(abroad, tries) {
        guard let name = homeNames[home],
              companyKey(name).split(separator: " ").first == companyKey(members[i].listing.name).split(separator: " ").first else { continue }
        log("  home line: \(members[i].listing.symbol) → \(home)")
        members[i] = Member(listing: Listing(symbol: home, exchange: "home", exchangeCountry: members[i].country, name: members[i].listing.name,
                                             classCapEUR: members[i].listing.classCapEUR, tradedEUR: members[i].listing.tradedEUR),
                            country: members[i].country, sector: members[i].sector, floatFactor: members[i].floatFactor)
    }

    members.sort { $0.floatCapEUR > $1.floatCapEUR }
    let picked = Array(members.prefix(target))
    let byCountry = Dictionary(grouping: picked, by: \.country).mapValues(\.count).sorted { $0.value > $1.value }
    log("Kept \(picked.count): " + byCountry.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
    if let last = picked.last { log(String(format: "Smallest free-float cap kept: €%.2fbn (%@)", last.floatCapEUR / 1e9, last.listing.symbol)) }

    func quoted(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
    var lines = [
        "// Generated by tools/build_stoxx600.swift. Do not edit by hand; rerun the script instead.",
        "// Approximates the STOXX Europe 600: the 600 largest companies of its 17 countries by free-float",
        "// market cap in EUR, one listing each.",
        "",
        "extension Universe {",
        "    static let stoxx600: [Instrument] = [",
    ]
    for m in picked {
        lines.append("        .init(symbol: \(quoted(m.listing.symbol)), name: \(quoted(shortNames[m.listing.symbol] ?? cleanName(m.listing.name))), country: \(quoted(m.country)), sector: \(quoted(m.sector))),")
    }
    lines += ["    ]", "}", ""]
    try? lines.joined(separator: "\n").write(toFile: outPath, atomically: true, encoding: .utf8)
}

let out = CommandLine.arguments.dropFirst().first ?? "UniverseSTOXX600.swift"
let done = DispatchSemaphore(value: 0)
Task {
    await run(out)
    done.signal()
}
done.wait()
