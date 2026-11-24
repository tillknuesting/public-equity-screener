import Foundation

/// Compact binary file for daily price history (~16 years × ~600 series). JSON would be
/// ~100 MB and slow to parse on every launch; this is ~24 bytes per bar and loads in a blink.
///
/// Layout: "PEQ1", series count (UInt32), then per series: symbol and currency (UInt16 length +
/// UTF-8), market time (Float64, NaN if unknown), bar count (UInt32), and for each bar
/// day (Int32) + open, high, low, close, volume (Float32).
enum PriceCache {
    private static let magic = Array("PEQ1".utf8)

    static func save(_ series: [String: PriceSeries], to url: URL) {
        var data = Data(magic)
        data.reserveCapacity(series.values.reduce(64) { $0 + 64 + $1.bars.count * 24 })
        append(UInt32(series.count), to: &data)
        for s in series.values {
            append(string: s.symbol, to: &data)
            append(string: s.currency, to: &data)
            append((s.marketTime?.timeIntervalSince1970 ?? .nan).bitPattern, to: &data)
            append(UInt32(s.bars.count), to: &data)
            for b in s.bars {
                append(Int32(b.day), to: &data)
                for v in [b.open, b.high, b.low, b.close, b.volume] { append(Float32(v).bitPattern, to: &data) }
            }
        }
        try? data.write(to: url, options: .atomic)
    }

    static func load(from url: URL) -> [String: PriceSeries] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count > 8,
              Array(data.prefix(4)) == magic else { return [:] }
        var reader = Reader(data: data, offset: 4)
        guard let count: UInt32 = reader.read() else { return [:] }
        var out: [String: PriceSeries] = [:]
        out.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let symbol = reader.readString(), let currency = reader.readString(),
                  let timeBits: UInt64 = reader.read(), let n: UInt32 = reader.read() else { break }
            var bars: [Bar] = []
            bars.reserveCapacity(Int(n))
            for _ in 0..<n {
                guard let day: Int32 = reader.read(), let o: UInt32 = reader.read(), let h: UInt32 = reader.read(),
                      let l: UInt32 = reader.read(), let c: UInt32 = reader.read(), let v: UInt32 = reader.read() else { return out }
                bars.append(Bar(day: Int(day), open: Double(Float32(bitPattern: o)), high: Double(Float32(bitPattern: h)),
                                low: Double(Float32(bitPattern: l)), close: Double(Float32(bitPattern: c)),
                                volume: Double(Float32(bitPattern: v))))
            }
            let time = Double(bitPattern: timeBits)
            out[symbol] = PriceSeries(symbol: symbol, currency: currency, bars: bars,
                                      marketTime: time.isNaN ? nil : Date(timeIntervalSince1970: time))
        }
        return out
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func append(string: String, to data: inout Data) {
        let bytes = Array(string.utf8.prefix(Int(UInt16.max)))
        append(UInt16(bytes.count), to: &data)
        data.append(contentsOf: bytes)
    }

    private struct Reader {
        let data: Data
        var offset: Int

        mutating func read<T: FixedWidthInteger>() -> T? {
            let size = MemoryLayout<T>.size
            guard offset + size <= data.count else { return nil }
            var value: T = 0
            withUnsafeMutableBytes(of: &value) { dst in
                data.copyBytes(to: dst, from: (data.startIndex + offset)..<(data.startIndex + offset + size))
            }
            offset += size
            return T(littleEndian: value)
        }

        mutating func readString() -> String? {
            guard let n: UInt16 = read(), offset + Int(n) <= data.count else { return nil }
            let start = data.startIndex + offset
            offset += Int(n)
            return String(decoding: data[start..<(start + Int(n))], as: UTF8.self)
        }
    }
}
