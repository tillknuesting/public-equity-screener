import Foundation

/// Minimal client for Yahoo Finance's public endpoints (no API key needed):
/// daily charts, the fundamentals timeseries and per-ticker RSS headlines.
struct YahooClient: Sendable {
    enum ClientError: LocalizedError {
        case http(Int)
        case noData(String)

        var errorDescription: String? {
            switch self {
            case .http(let code): "HTTP \(code)"
            case .noData(let msg): msg
            }
        }
    }

    /// Years of daily history to request (16 reaches back to late 2010: 2011, 2015, 2018, 2020, 2022…).
    var years = 16.0

    // MARK: Prices

    func fetchDaily(symbol: String) async throws -> PriceSeries {
        var lastError: Error = ClientError.noData("no attempt")
        for (attempt, host) in ["query1", "query2", "query1"].enumerated() {
            if attempt > 0 { try await Task.sleep(for: .milliseconds(700 * attempt)) }
            do {
                return try await fetchChart(symbol: symbol, host: host)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// USD per one unit of `currency`, from the latest FX close.
    func fetchUSDRate(currency: String) async throws -> Double {
        let series = try await YahooClient(years: 0.05).fetchDaily(symbol: "\(currency)USD=X")
        guard let close = series.bars.last?.close else { throw ClientError.noData("No FX for \(currency)") }
        return close
    }

    private func fetchChart(symbol: String, host: String) async throws -> PriceSeries {
        let now = Int(Date().timeIntervalSince1970)
        let from = now - Int(years * 365.25 * 86_400)
        let url = URL(string: "https://\(host).finance.yahoo.com/v8/finance/chart/\(Self.encode(symbol))?period1=\(from)&period2=\(now + 86_400)&interval=1d&includeAdjustedClose=true&events=div,split")!
        let data = try await get(url)
        let decoded = try JSONDecoder().decode(ChartResponse.self, from: data)
        guard let result = decoded.chart.result?.first, let timestamps = result.timestamp,
              let quote = result.indicators.quote.first else {
            throw ClientError.noData(decoded.chart.error?.description ?? "No data for \(symbol)")
        }

        let offset = result.meta.gmtoffset ?? 0
        let adj = result.indicators.adjclose?.first?.adjclose
        var bars: [Bar] = []
        bars.reserveCapacity(timestamps.count)
        for (i, ts) in timestamps.enumerated() {
            guard let close = quote.close?[safe: i] ?? nil, close > 0 else { continue }
            let open = (quote.open?[safe: i] ?? nil) ?? close
            let high = (quote.high?[safe: i] ?? nil) ?? close
            let low = (quote.low?[safe: i] ?? nil) ?? close
            let volume = (quote.volume?[safe: i] ?? nil) ?? 0
            let factor = (adj?[safe: i] ?? nil).map { $0 / close } ?? 1
            let bar = Bar(day: TradingDay.from(timestamp: ts, gmtOffset: offset),
                          open: open * factor, high: high * factor, low: low * factor,
                          close: close * factor, volume: volume)
            // Yahoo sometimes repeats the live session as an extra bar; keep the latest.
            if let last = bars.last, last.day == bar.day { bars[bars.count - 1] = bar } else { bars.append(bar) }
        }
        guard bars.count > 1 else { throw ClientError.noData("Too little history for \(symbol)") }

        return PriceSeries(symbol: symbol,
                           currency: result.meta.currency ?? "",
                           bars: PriceRepair.repair(bars),
                           marketTime: result.meta.regularMarketTime.map { Date(timeIntervalSince1970: TimeInterval($0)) })
    }

    // MARK: Fundamentals

    func fetchFundamentals(symbol: String) async throws -> Fundamentals {
        let types = ["trailingFreeCashFlow", "trailingTotalRevenue", "quarterlyTotalRevenue", "annualTotalRevenue",
                     "trailingOperatingIncome", "trailingNetIncome",
                     "trailingMarketCap", "trailingPeRatio", "trailingForwardPeRatio"]
        let now = Int(Date().timeIntervalSince1970)
        let url = URL(string: "https://query1.finance.yahoo.com/ws/fundamentals-timeseries/v1/finance/timeseries/\(Self.encode(symbol))?type=\(types.joined(separator: ","))&period1=\(now - 3 * 365 * 86_400)&period2=\(now + 86_400)")!
        let data = try await get(url)

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = (root["timeseries"] as? [String: Any])?["result"] as? [[String: Any]] else {
            throw ClientError.noData("No fundamentals for \(symbol)")
        }

        struct Point { let day: Int; let value: Double; let currency: String? }
        var series: [String: [Point]] = [:]
        for result in results {
            guard let type = ((result["meta"] as? [String: Any])?["type"] as? [String])?.first,
                  let entries = result[type] as? [Any] else { continue }
            series[type] = entries.compactMap { entry -> Point? in
                guard let e = entry as? [String: Any],
                      let day = (e["asOfDate"] as? String).flatMap(TradingDay.from(isoDate:)),
                      let raw = ((e["reportedValue"] as? [String: Any])?["raw"] as? NSNumber)?.doubleValue else { return nil }
                return Point(day: day, value: raw, currency: e["currencyCode"] as? String)
            }
            .sorted { $0.day < $1.day }
        }

        var f = Fundamentals()
        f.fcf = series["trailingFreeCashFlow"]?.last?.value
        let revenue = series["trailingTotalRevenue"] ?? []
        f.revenue = revenue.last?.value
        // Growth: TTM vs. TTM a year earlier; else latest quarter vs. the same quarter last year;
        // else last fiscal year vs. the one before. Yahoo often only keeps one TTM point.
        func yearApart(_ a: Point, _ b: Point) -> Bool {
            (300...430).contains(TradingDay.date(a.day).timeIntervalSince(TradingDay.date(b.day)) / 86_400)
        }
        let quarterly = series["quarterlyTotalRevenue"] ?? []
        let annual = series["annualTotalRevenue"] ?? []
        // Growth only from a positive base: a zero would give infinity, which also breaks the JSON cache.
        func growth(_ now: Point, _ then: Point) -> Double? { then.value > 0 ? now.value / then.value - 1 : nil }
        if revenue.count >= 2, yearApart(revenue[revenue.count - 1], revenue[revenue.count - 2]) {
            f.revenueGrowth = growth(revenue[revenue.count - 1], revenue[revenue.count - 2])
        } else if quarterly.count >= 5, yearApart(quarterly[quarterly.count - 1], quarterly[quarterly.count - 5]) {
            f.revenueGrowth = growth(quarterly[quarterly.count - 1], quarterly[quarterly.count - 5])
        } else if annual.count >= 2 {
            f.revenueGrowth = growth(annual[annual.count - 1], annual[annual.count - 2])
        }
        f.operatingIncome = series["trailingOperatingIncome"]?.last?.value
        f.netIncome = series["trailingNetIncome"]?.last?.value
        f.reportCurrency = series["trailingFreeCashFlow"]?.last?.currency ?? revenue.last?.currency
        if let cap = series["trailingMarketCap"]?.last {
            f.marketCap = cap.value
            f.marketCapDay = cap.day
            f.marketCapCurrency = cap.currency ?? series["trailingMarketCap"]?.last(where: { $0.currency != nil })?.currency
        }
        f.pe = series["trailingPeRatio"]?.last?.value
        f.forwardPE = series["trailingForwardPeRatio"]?.last?.value
        return f
    }

    // MARK: News

    func fetchNews(symbol: String) async throws -> [NewsItem] {
        let url = URL(string: "https://feeds.finance.yahoo.com/rss/2.0/headline?s=\(Self.encode(symbol))&region=US&lang=en-US")!
        let data = try await get(url)
        return RSSParser.parse(data)
    }

    /// Latest and upcoming earnings dates, up to 50 symbols per request. The quote endpoint
    /// needs a session cookie and crumb, which `YahooSession` fetches once.
    func fetchEarnings(symbols: [String]) async throws -> [String: [EarningsDate]] {
        let list = symbols.map(Self.encode).joined(separator: ",")
        let fields = "earningsTimestamp,earningsTimestampStart,earningsTimestampEnd,isEarningsDateEstimate"
        var crumb = try await YahooSession.shared.crumb()
        var data: Data
        do {
            data = try await get(URL(string: "https://query1.finance.yahoo.com/v7/finance/quote?symbols=\(list)&fields=\(fields)&crumb=\(crumb)")!)
        } catch ClientError.http(401) {
            crumb = try await YahooSession.shared.crumb(renew: true)
            data = try await get(URL(string: "https://query1.finance.yahoo.com/v7/finance/quote?symbols=\(list)&fields=\(fields)&crumb=\(crumb)")!)
        }
        struct Response: Decodable {
            struct Body: Decodable { let result: [Quote]? }
            struct Quote: Decodable {
                let symbol: String
                let earningsTimestamp: Int?
                let earningsTimestampStart: Int?
                let isEarningsDateEstimate: Bool?
                let exchangeTimezoneName: String?
                let gmtOffSetMilliseconds: Int?
            }
            let quoteResponse: Body
        }
        let now = Int(Date().timeIntervalSince1970)
        var out: [String: [EarningsDate]] = [:]
        for q in try JSONDecoder().decode(Response.self, from: data).quoteResponse.result ?? [] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = q.exchangeTimezoneName.flatMap(TimeZone.init(identifier:))
                ?? TimeZone(secondsFromGMT: (q.gmtOffSetMilliseconds ?? 0) / 1000) ?? .gmt
            let isUS = !q.symbol.contains(".")
            func date(_ ts: Int, estimate: Bool) -> EarningsDate {
                let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: Date(timeIntervalSince1970: TimeInterval(ts)))
                let day = c.year! * 10000 + c.month! * 100 + c.day!
                // Only US times are real (16:00 = after the close, 08:00 = before the open); 00:00 means unknown.
                let hour = c.hour ?? 0, midnight = hour == 0 && (c.minute ?? 0) == 0
                let afterClose: Bool? = !isUS || midnight ? nil : hour >= 15 ? true : hour < 10 ? false : nil
                return EarningsDate(day: day, estimate: estimate, afterClose: afterClose)
            }
            var dates: [EarningsDate] = []
            if let ts = q.earningsTimestamp { dates.append(date(ts, estimate: ts > now && (q.isEarningsDateEstimate ?? false))) }
            if let start = q.earningsTimestampStart, start > now, start != q.earningsTimestamp {
                dates.append(date(start, estimate: q.isEarningsDateEstimate ?? false))
            }
            if !dates.isEmpty { out[q.symbol] = dates }
        }
        return out
    }

    // MARK: Plumbing

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ClientError.http(http.statusCode)
        }
        return data
    }

    private static func encode(_ symbol: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))
        return symbol.addingPercentEncoding(withAllowedCharacters: allowed) ?? symbol
    }
}

/// STOXX publishes the VSTOXX family as free daily files (Yahoo doesn't carry them).
enum StoxxClient {
    /// `code` is STOXX's index code, e.g. "V2TX" (VSTOXX) or "V6I3" (its 3-month sub-index).
    static func series(_ code: String, symbol: String, years: Double = 16) async throws -> PriceSeries {
        let url = URL(string: "https://www.stoxx.com/document/Indices/Current/HistoricalData/h_\(code.lowercased()).txt")!
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw YahooClient.ClientError.http(http.statusCode) }
        let cutoff = TradingDay.day(from: Date().addingTimeInterval(-years * 365.25 * 86_400))
        var bars: [Bar] = []
        // Lines look like "23.10.2026;V2TX;21.9152".
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let f = line.split(separator: ";")
            guard f.count >= 3, let value = Double(f[2].trimmingCharacters(in: .whitespaces)), value > 0 else { continue }
            let d = f[0].split(separator: ".")
            guard d.count == 3, let dd = Int(d[0]), let mm = Int(d[1]), let yyyy = Int(d[2]) else { continue }
            let day = yyyy * 10000 + mm * 100 + dd
            guard day >= cutoff else { continue }
            bars.append(Bar(day: day, open: value, high: value, low: value, close: value, volume: 0))
        }
        guard bars.count > 250 else { throw YahooClient.ClientError.noData("\(code): \(bars.count) rows") }
        bars.sort { $0.day < $1.day }
        return PriceSeries(symbol: symbol, currency: "EUR", bars: bars, marketTime: bars.last?.date)
    }
}

/// Yahoo's quote endpoints want a session cookie (set by fc.yahoo.com) and a matching crumb.
actor YahooSession {
    static let shared = YahooSession()
    private var cached: String?

    func crumb(renew: Bool = false) async throws -> String {
        if let cached, !renew { return cached }
        func request(_ s: String) -> URLRequest {
            var r = URLRequest(url: URL(string: s)!, timeoutInterval: 20)
            r.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36",
                       forHTTPHeaderField: "User-Agent")
            return r
        }
        _ = try? await URLSession.shared.data(for: request("https://fc.yahoo.com/"))   // 404 is normal; it sets the cookie
        let (data, response) = try await URLSession.shared.data(for: request("https://query1.finance.yahoo.com/v1/test/getcrumb"))
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let crumb = String(decoding: data, as: UTF8.self)
        guard code == 200, !crumb.isEmpty, crumb.count < 40, !crumb.contains(" ") else { throw YahooClient.ClientError.http(code) }
        cached = crumb.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? crumb
        return cached!
    }
}

private final class RSSParser: NSObject, XMLParserDelegate {
    private var items: [NewsItem] = []
    private var fields: [String: String] = [:]
    private var element = ""
    private var inItem = false

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f
    }()

    static func parse(_ data: Data) -> [NewsItem] {
        let delegate = RSSParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.items.sorted { $0.date > $1.date }
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        element = name
        if name == "item" { inItem = true; fields = [:] }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inItem else { return }
        fields[element, default: ""] += string
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard name == "item" else { return }
        inItem = false
        let title = fields["title"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty,
              let date = fields["pubDate"].flatMap({ Self.dateFormatter.date(from: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }) else { return }
        let summary = fields["description"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        items.append(NewsItem(title: title,
                              link: fields["link"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                              date: date,
                              summary: summary?.isEmpty == true ? nil : summary))
    }
}

private struct ChartResponse: Decodable {
    struct Chart: Decodable {
        let result: [ChartResult]?
        let error: APIError?
    }
    struct APIError: Decodable {
        let code: String?
        let description: String?
    }
    struct ChartResult: Decodable {
        let meta: Meta
        let timestamp: [Int]?
        let indicators: Indicators
    }
    struct Meta: Decodable {
        let currency: String?
        let gmtoffset: Int?
        let regularMarketTime: Int?
    }
    struct Indicators: Decodable {
        let quote: [Quote]
        let adjclose: [AdjClose]?
    }
    struct Quote: Decodable {
        let open: [Double?]?
        let high: [Double?]?
        let low: [Double?]?
        let close: [Double?]?
        let volume: [Double?]?
    }
    struct AdjClose: Decodable {
        let adjclose: [Double?]?
    }

    let chart: Chart
}


/// FRED's public CSV download (no key): Moody's daily Baa and Aaa corporate yields.
enum FredClient {
    static func series(_ id: String) async throws -> [Int: Double] {
        let url = URL(string: "https://fred.stlouisfed.org/graph/fredgraph.csv?id=\(id)&cosd=2010-01-01")!
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw YahooClient.ClientError.http(http.statusCode) }
        var out: [Int: Double] = [:]
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).dropFirst() {
            let parts = line.split(separator: ",")
            guard parts.count == 2, let day = TradingDay.from(isoDate: String(parts[0])), let v = Double(parts[1]) else { continue }
            out[day] = v
        }
        return out
    }

    /// Baa − Aaa in basis points by day: the classic default (quality) spread.
    static func baaAaaSpread() async throws -> [Int: Double] {
        async let baa = series("DBAA")
        async let aaa = series("DAAA")
        let (b, a) = try await (baa, aaa)
        var out: [Int: Double] = [:]
        for (day, v) in b { if let w = a[day] { out[day] = (v - w) * 100 } }
        return out
    }
}
