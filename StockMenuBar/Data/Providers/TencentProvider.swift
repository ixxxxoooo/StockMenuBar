//
//  TencentProvider.swift
//  StockMenuBar
//
//  腾讯行情源(主源):批量实时行情(含五档、换手率)、当日分时、搜索联想(支持拼音)。
//  @author ixxxxoooo
//

import Foundation

struct TencentProvider: QuoteProvider {
    let id: ProviderID = .tencent
    let capabilities: Set<ProviderCapability> = [.quotes, .minute, .search]
    private let http: HTTPClient

    init(http: HTTPClient) { self.http = http }

    func fetchQuotes(_ symbols: [StockSymbol]) async throws -> [Quote] {
        guard !symbols.isEmpty else { return [] }
        var all: [Quote] = []
        for chunk in ParseUtil.chunked(symbols, size: 60) {
            let list = chunk.map(\.full).joined(separator: ",")
            guard let url = URL(string: "https://qt.gtimg.cn/q=\(list)") else { throw ProviderError.invalidData("URL") }
            let data = try await http.send(URLRequest(url: url))
            guard let text = TextCodec.decodeGBK(data) else { throw ProviderError.invalidData("编码") }
            all += TencentParser.parseQuotes(text)
        }
        return all
    }

    func fetchMinute(symbol: StockSymbol) async throws -> MinuteSeries {
        guard let url = URL(string: "https://web.ifzq.gtimg.cn/appstock/app/minute/query?code=\(symbol.full)") else {
            throw ProviderError.invalidData("URL")
        }
        let data = try await http.send(URLRequest(url: url))
        return try TencentParser.parseMinute(data, symbol: symbol)
    }

    func search(keyword: String) async throws -> [SearchResult] {
        let key = ParseUtil.encodeQuery(keyword)
        guard let url = URL(string: "https://smartbox.gtimg.cn/s3/?v=2&q=\(key)&t=all") else { throw ProviderError.invalidData("URL") }
        let data = try await http.send(URLRequest(url: url))
        guard let text = TextCodec.decode(data) else { throw ProviderError.invalidData("编码") }
        return TencentParser.parseSearch(text)
    }
}

/// 腾讯数据解析(纯函数,便于测试)
enum TencentParser {
    /// 解析实时行情文本。字段以 `~` 分隔:
    /// 1 名称, 3 现价, 4 昨收, 5 今开, 9-18 买一至买五(价,量), 19-28 卖一至卖五, 30 时间,
    /// 33 最高, 34 最低, 36 成交量(手), 37 成交额(万), 38 换手率
    static func parseQuotes(_ text: String) -> [Quote] {
        var result: [Quote] = []
        for raw in text.split(whereSeparator: { $0 == "\n" || $0 == ";" }) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("v_"), let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.index(line.startIndex, offsetBy: 2)..<eq])
            guard let symbol = StockSymbol(full: key) else { continue }
            let payload = line[line.index(after: eq)...].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            let f = payload.split(separator: "~", omittingEmptySubsequences: false).map(String.init)
            guard f.count > 38 else { continue }

            func d(_ i: Int) -> Double? { i < f.count ? Double(f[i]) : nil }
            let prev = d(4) ?? 0
            var price = d(3) ?? 0
            if price <= 0 { price = prev }

            func levels(from start: Int) -> [PriceLevel] {
                (0..<5).compactMap { n -> PriceLevel? in
                    guard let p = d(start + n * 2), let v = d(start + n * 2 + 1), p > 0 else { return nil }
                    return PriceLevel(price: p, volume: v)
                }
            }

            let quote = Quote(
                symbol: symbol,
                name: f[1],
                price: price,
                prevClose: prev,
                open: d(5) ?? 0,
                high: d(33) ?? d(41) ?? price,
                low: d(34) ?? d(42) ?? price,
                volume: d(36) ?? d(6) ?? 0,
                amount: (d(37) ?? 0) * 10_000,
                turnover: d(38),
                bids: levels(from: 9),
                asks: levels(from: 19),
                time: ChinaTime.parse(compact: f[30]),
                source: .tencent
            )
            result.append(quote)
        }
        return result
    }

    /// 解析分时 JSON:`data.<code>.data.data` 为 `"HHMM 价格 累计量(手) 累计额"`,
    /// 昨收取自 `data.<code>.qt.<code>[4]`
    static func parseMinute(_ data: Data, symbol: StockSymbol) throws -> MinuteSeries {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataNode = root["data"] as? [String: Any],
              let node = dataNode[symbol.full] as? [String: Any],
              let inner = node["data"] as? [String: Any],
              let lines = inner["data"] as? [String] else {
            throw ProviderError.invalidData("分时结构")
        }
        var prevClose = 0.0
        if let qt = node["qt"] as? [String: Any], let arr = qt[symbol.full] as? [String], arr.count > 4 {
            prevClose = Double(arr[4]) ?? 0
        }
        let isIndex = symbol.kind == .index
        var bars: [MinuteBar] = []
        var lastCum = 0.0
        for line in lines {
            let parts = line.split(separator: " ")
            guard parts.count >= 3, let hhmm = Int(parts[0]), let price = Double(parts[1]), price > 0,
                  let idx = MinuteBar.index(hour: hhmm / 100, minute: hhmm % 100) else { continue }
            let cum = Double(parts[2]) ?? lastCum
            let vol = max(cum - lastCum, 0)
            lastCum = max(cum, lastCum)
            var avg: Double?
            if !isIndex, parts.count >= 4, let amount = Double(parts[3]), cum > 0 {
                avg = amount / (cum * 100)
            }
            if let last = bars.last, last.index == idx { bars.removeLast() }
            bars.append(MinuteBar(index: idx, price: price, volume: vol, avgPrice: avg))
        }
        guard !bars.isEmpty else { throw ProviderError.invalidData("分时为空") }
        if prevClose <= 0 { prevClose = bars[0].price }
        return MinuteSeries(symbol: symbol, prevClose: prevClose, date: inner["date"] as? String, bars: bars, source: .tencent)
    }

    /// 解析 smartbox 搜索:`v_hint="sh~600519~\u8d35...~gzmt~GP-A^..."`
    static func parseSearch(_ text: String) -> [SearchResult] {
        guard let first = text.firstIndex(of: "\""), let last = text.lastIndex(of: "\""), first < last else { return [] }
        let payload = String(text[text.index(after: first)..<last])
        if payload == "N" || payload.isEmpty { return [] }
        // 将 \uXXXX 转义还原为中文
        let wrapped = "\"" + payload + "\""
        let decoded = (try? JSONSerialization.jsonObject(with: Data(wrapped.utf8), options: .fragmentsAllowed)) as? String ?? payload
        var results: [SearchResult] = []
        for entry in decoded.split(separator: "^") {
            let f = entry.split(separator: "~", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 5, let market = Market(rawValue: f[0]) else { continue }
            let type = f[4]
            guard type.hasPrefix("GP") || type.hasPrefix("ZS") || type.hasPrefix("ETF") else { continue }
            let symbol = StockSymbol(market: market, code: f[1])
            results.append(SearchResult(symbol: symbol, name: f[2], pinyin: f[3].uppercased()))
        }
        return results
    }
}
