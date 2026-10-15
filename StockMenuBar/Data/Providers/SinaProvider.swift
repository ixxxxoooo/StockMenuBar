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
    let capabilities: Set<ProviderCapability> = [.quotes, .search, .futuresQuotes, .futuresMinute]
    private let http: HTTPClient

    init(http: HTTPClient) { self.http = http }

    /// 期货:仅能服务有新浪代码映射的标的;分时仅国内期货(nf_)可用
    func canServe(_ capability: ProviderCapability, symbol: StockSymbol?) -> Bool {
        guard capabilities.contains(capability) else { return false }
        guard let symbol, symbol.isFuture else { return true }
        guard let mapping = FuturesCatalog.sinaMapping(secid: symbol.code) else { return false }
        return capability == .futuresMinute ? mapping.code.hasPrefix("nf_") : true
    }

    func fetchQuotes(_ symbols: [StockSymbol]) async throws -> [Quote] {
        guard !symbols.isEmpty else { return [] }
        var all: [Quote] = []
        let futures = symbols.filter(\.isFuture)
        let stocks = symbols.filter { !$0.isFuture }
        if !futures.isEmpty { all += try await fetchFuturesQuotes(futures) }
        for chunk in ParseUtil.chunked(stocks, size: 60) {
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

    /// 批量获取期货行情(nf_ 国内、hf_ 外盘),只请求有映射的标的
    private func fetchFuturesQuotes(_ symbols: [StockSymbol]) async throws -> [Quote] {
        let mapped = symbols.compactMap { s in FuturesCatalog.sinaMapping(secid: s.code).map { _ in s } }
        guard !mapped.isEmpty else { return [] }
        let list = mapped.compactMap { FuturesCatalog.sinaMapping(secid: $0.code)?.code }.joined(separator: ",")
        guard let url = URL(string: "https://hq.sinajs.cn/list=\(list)") else { throw ProviderError.invalidData("URL") }
        var request = URLRequest(url: url)
        request.setValue("https://finance.sina.com.cn", forHTTPHeaderField: "Referer")
        let data = try await http.send(request)
        guard let text = TextCodec.decodeGBK(data) else { throw ProviderError.invalidData("编码") }
        return SinaParser.parseFuturesQuotes(text, requested: mapped)
    }

    /// 国内期货分时(新浪 getMinLine)
    func fetchMinute(symbol: StockSymbol) async throws -> MinuteSeries {
        guard symbol.isFuture, let mapping = FuturesCatalog.sinaMapping(secid: symbol.code), mapping.code.hasPrefix("nf_") else {
            throw ProviderError.unsupported
        }
        let key = String(mapping.code.dropFirst(3))
        guard let url = URL(string: "https://stock2.finance.sina.com.cn/futures/api/jsonp.php/var%20t=/InnerFuturesNewService.getMinLine?symbol=\(key)") else {
            throw ProviderError.invalidData("URL")
        }
        var request = URLRequest(url: url)
        request.setValue("https://finance.sina.com.cn", forHTTPHeaderField: "Referer")
        let data = try await http.send(request)
        return try SinaParser.parseFuturesMinute(data, symbol: symbol, sinaKey: key)
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

    // MARK: - 期货

    /// 解析期货行情。
    /// - 国内 `nf_`:0 名称, 2 今开, 3 最高, 4 最低, 5 昨收, 8 现价, 10 昨结算, 13 持仓量, 14 成交量
    /// - 全球指数 `znb_`:1 现价, 8 今开, 9 昨收, 10 最高, 11 最低
    /// - 外盘 `hf_`:0 现价, 4 最高, 5 最低, 7 昨收, 8 今开, 13 名称, 14 成交量(价格按预置换算系数折算)
    static func parseFuturesQuotes(_ text: String, requested: [StockSymbol]) -> [Quote] {
        var result: [Quote] = []
        for raw in text.split(whereSeparator: { $0 == "\n" || $0 == ";" }) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("var hq_str_"), let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.index(line.startIndex, offsetBy: "var hq_str_".count)..<eq])
            guard let hit = FuturesCatalog.symbol(sinaKey: key, among: requested) else { continue }
            let payload = line[line.index(after: eq)...].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            guard !payload.isEmpty else { continue }
            let f = payload.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            let symbol = hit.symbol
            let scale = hit.scale
            func d(_ i: Int) -> Double? { i < f.count ? Double(f[i]) : nil }
            let presetName = FuturesCatalog.preset(secid: symbol.code)?.name
            let quote: Quote
            if key.lowercased().hasPrefix("nf_") {
                guard f.count > 14 else { continue }
                let prev = (d(10) ?? 0) > 0 ? (d(10) ?? 0) : (d(5) ?? 0)
                var price = d(8) ?? 0
                if price <= 0 { price = prev }
                quote = Quote(symbol: symbol, name: presetName ?? f[0], price: price, prevClose: prev, open: d(2) ?? 0,
                              high: d(3) ?? price, low: d(4) ?? price, volume: d(14) ?? 0, amount: 0, turnover: nil,
                              bids: [], asks: [], time: nil, source: .sina,
                              openInterest: d(13), decimalsHint: inferDecimals(price))
            } else if key.lowercased().hasPrefix("znb_") {
                // 全球指数:1 现价, 8 今开, 9 昨收, 10 最高, 11 最低
                guard f.count > 11 else { continue }
                let prev = d(9) ?? 0
                var price = d(1) ?? 0
                if price <= 0 { price = prev }
                quote = Quote(symbol: symbol, name: presetName ?? f[0], price: price, prevClose: prev, open: d(8) ?? 0,
                              high: d(10) ?? price, low: d(11) ?? price, volume: 0, amount: 0, turnover: nil,
                              bids: [], asks: [], time: nil, source: .sina,
                              openInterest: nil, decimalsHint: 2)
            } else {
                guard f.count > 13 else { continue }
                let prev = (d(7) ?? 0) * scale
                var price = (d(0) ?? 0) * scale
                if price <= 0 { price = prev }
                quote = Quote(symbol: symbol, name: presetName ?? f[13], price: price, prevClose: prev, open: (d(8) ?? 0) * scale,
                              high: (d(4) ?? 0) * scale, low: (d(5) ?? 0) * scale, volume: d(14) ?? 0, amount: 0, turnover: nil,
                              bids: [], asks: [], time: nil, source: .sina,
                              openInterest: nil, decimalsHint: inferDecimals(price))
            }
            result.append(quote)
        }
        return result
    }

    /// 按价格量级推断报价小数位(新浪不提供精度)
    static func inferDecimals(_ price: Double) -> Int {
        switch price {
        case 10000...: return 0
        case 1000...: return 1
        case 10...: return 2
        case 1...: return 3
        default: return 4
        }
    }

    /// 解析国内期货分时:`var t=([["21:00","价","均价","量","持仓","昨收","交易日"],["21:01",...]]);`
    /// 夜盘跨零点时按「时刻回绕」累计分钟,横轴由品种夜盘模板决定。
    static func parseFuturesMinute(_ data: Data, symbol: StockSymbol, sinaKey: String) throws -> MinuteSeries {
        guard let text = String(data: data, encoding: .utf8) ?? TextCodec.decodeGBK(data),
              let open = text.range(of: "var t=("), let close = text.lastIndex(of: ")") else {
            throw ProviderError.invalidData("分时结构")
        }
        let json = String(text[open.upperBound..<close])
        guard let rows = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[Any]], !rows.isEmpty else {
            throw ProviderError.invalidData("分时为空")
        }
        func hm(_ row: [Any]) -> Int? {
            guard let t = row.first as? String else { return nil }
            let p = t.split(separator: ":").compactMap { Int($0) }
            return p.count == 2 ? p[0] * 60 + p[1] : nil
        }
        guard let firstMinute = hm(rows[0]) else { throw ProviderError.invalidData("分时时间") }
        let hasNight = firstMinute >= 21 * 60
        let product = String(sinaKey.prefix { $0.isLetter })
        // 数据含夜盘才使用夜盘模板;模板认为无夜盘但数据有夜盘时按 23:00 收盘兜底
        let nightEnd: Int? = hasNight ? (FuturesCatalog.nightEnd(product: product, observedNight: true) ?? 23 * 60) : nil
        let axis = FuturesCatalog.domesticAxis(nightEnd: nightEnd)
        var bars: [MinuteBar] = []
        var wrap = 0
        var previous = firstMinute
        for row in rows {
            guard let m = hm(row), row.count >= 4,
                  let price = Double(row[1] as? String ?? ""), price > 0 else { continue }
            if m < previous { wrap += 1440 }
            previous = m
            guard let idx = axis.index(forMinute: m + wrap) else { continue }
            let avg = Double(row[2] as? String ?? "")
            let vol = Double(row[3] as? String ?? "") ?? 0
            if let last = bars.last, last.index == idx { bars.removeLast() }
            bars.append(MinuteBar(index: idx, price: price, volume: vol, avgPrice: (avg ?? 0) > 0 ? avg : nil))
        }
        guard !bars.isEmpty else { throw ProviderError.invalidData("分时为空") }
        var prev = rows[0].count > 5 ? (Double(rows[0][5] as? String ?? "") ?? 0) : 0
        if prev <= 0 { prev = bars[0].price }
        let day = rows[0].count > 6 ? (rows[0][6] as? String)?.replacingOccurrences(of: "-", with: "") : nil
        var series = MinuteSeries(symbol: symbol, prevClose: prev, date: day, bars: bars, source: .sina)
        series.axis = axis
        series.decimalsHint = inferDecimals(bars[0].price)
        return series
    }
}
