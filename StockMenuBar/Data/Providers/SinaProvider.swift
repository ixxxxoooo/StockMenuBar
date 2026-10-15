//
//  SinaProvider.swift
//  StockMenuBar
//
//  新浪行情源(备源):批量实时行情(含五档,无换手率)与搜索联想。必须携带 Referer。
//  @author ixxxxoooo
//

import Foundation

struct SinaProvider: QuoteProvider {
    let id: ProviderID = .sina
    let capabilities: Set<ProviderCapability> = [.quotes, .search]
    private let http: HTTPClient

    init(http: HTTPClient) { self.http = http }

    func fetchQuotes(_ symbols: [StockSymbol]) async throws -> [Quote] {
        guard !symbols.isEmpty else { return [] }
        var all: [Quote] = []
        for chunk in ParseUtil.chunked(symbols, size: 60) {
            let list = chunk.map(\.full).joined(separator: ",")
            guard let url = URL(string: "https://hq.sinajs.cn/list=\(list)") else { throw ProviderError.invalidData("URL") }
            var request = URLRequest(url: url)
            request.setValue("https://finance.sina.com.cn", forHTTPHeaderField: "Referer")
            let data = try await http.send(request)
            guard let text = TextCodec.decodeGBK(data) else { throw ProviderError.invalidData("编码") }
            all += SinaParser.parseQuotes(text)
        }
        return all
    }

    func search(keyword: String) async throws -> [SearchResult] {
        let key = ParseUtil.encodeQuery(keyword)
        guard let url = URL(string: "https://suggest3.sinajs.cn/suggest/type=11,12,13,14,15&key=\(key)") else {
            throw ProviderError.invalidData("URL")
        }
        var request = URLRequest(url: url)
        request.setValue("https://finance.sina.com.cn", forHTTPHeaderField: "Referer")
        let data = try await http.send(request)
        guard let text = TextCodec.decodeGBK(data) else { throw ProviderError.invalidData("编码") }
        return SinaParser.parseSearch(text)
    }
}

/// 新浪数据解析(纯函数,便于测试)
enum SinaParser {
    /// 解析实时行情。字段以 `,` 分隔:
    /// 0 名称, 1 今开, 2 昨收, 3 现价, 4 最高, 5 最低, 8 成交量(股), 9 成交额(元),
    /// 10-19 买一至买五(量,价), 20-29 卖一至卖五(量,价), 30 日期, 31 时间
    static func parseQuotes(_ text: String) -> [Quote] {
        var result: [Quote] = []
        for raw in text.split(whereSeparator: { $0 == "\n" || $0 == ";" }) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("var hq_str_"), let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.index(line.startIndex, offsetBy: "var hq_str_".count)..<eq])
            guard let symbol = StockSymbol(full: key) else { continue }
            let payload = line[line.index(after: eq)...].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            guard !payload.isEmpty else { continue }
            let f = payload.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard f.count > 31 else { continue }

            func d(_ i: Int) -> Double? { i < f.count ? Double(f[i]) : nil }
            let prev = d(2) ?? 0
            var price = d(3) ?? 0
            if price <= 0 { price = prev }
            // 新浪个股/ETF 成交量单位为股,指数已是手
            let volDivisor: Double = symbol.kind == .index ? 1 : 100

            func levels(from start: Int) -> [PriceLevel] {
                (0..<5).compactMap { n -> PriceLevel? in
                    guard let v = d(start + n * 2), let p = d(start + n * 2 + 1), p > 0 else { return nil }
                    return PriceLevel(price: p, volume: v / 100)
                }
            }

            result.append(Quote(
                symbol: symbol,
                name: f[0],
                price: price,
                prevClose: prev,
                open: d(1) ?? 0,
                high: d(4) ?? price,
                low: d(5) ?? price,
                volume: (d(8) ?? 0) / volDivisor,
                amount: d(9) ?? 0,
                turnover: nil,
                bids: levels(from: 10),
                asks: levels(from: 20),
                time: ChinaTime.parse(day: f[30], time: f[31]),
                source: .sina
            ))
        }
        return result
    }

    /// 解析搜索联想:`var suggestvalue="名称,类型,代码,完整代码,名称,...;..."`
    static func parseSearch(_ text: String) -> [SearchResult] {
        guard let first = text.firstIndex(of: "\""), let last = text.lastIndex(of: "\""), first < last else { return [] }
        let payload = String(text[text.index(after: first)..<last])
        var results: [SearchResult] = []
        for entry in payload.split(separator: ";") {
            let f = entry.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 4, let symbol = StockSymbol(full: f[3]) else { continue }
            // 11=A股/指数 12=B股 14=基金(仅保留 ETF);13 权证、15 债券忽略
            guard ["11", "12", "14"].contains(f[1]) else { continue }
            if f[1] == "14" && symbol.kind != .etf { continue }
            results.append(SearchResult(symbol: symbol, name: f[0], pinyin: Pinyin.initials(f[0])))
        }
        return results
    }
}
