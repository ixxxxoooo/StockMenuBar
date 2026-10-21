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
    let capabilities: Set<ProviderCapability> = [.quotes, .minute, .search, .futuresQuotes, .futuresMinute, .kline]
    private let http: HTTPClient

    init(http: HTTPClient) { self.http = http }

    /// 期货/全球指数:腾讯只覆盖美股指数(`usDJI` 等),其余由其他源承担
    func canServe(_ capability: ProviderCapability, symbol: StockSymbol?) -> Bool {
        guard capabilities.contains(capability) else { return false }
        guard let symbol, symbol.isFuture else { return true }
        // K 线:期货/全球指数无数据源
        if capability == .kline { return false }
        return FuturesCatalog.tencentCode(secid: symbol.code) != nil
    }

    func fetchQuotes(_ symbols: [StockSymbol]) async throws -> [Quote] {
        guard !symbols.isEmpty else { return [] }
        var all: [Quote] = []
        let globals = symbols.filter { $0.isFuture && FuturesCatalog.tencentCode(secid: $0.code) != nil }
        if !globals.isEmpty {
            let list = globals.compactMap { FuturesCatalog.tencentCode(secid: $0.code) }.joined(separator: ",")
            guard let url = URL(string: "https://qt.gtimg.cn/q=\(list)") else { throw ProviderError.invalidData("URL") }
            let data = try await http.send(URLRequest(url: url))
            guard let text = TextCodec.decodeGBK(data) else { throw ProviderError.invalidData("编码") }
            all += TencentParser.parseGlobalQuotes(text, requested: globals)
        }
        let symbols = symbols.filter { !$0.isFuture }
        for chunk in ParseUtil.chunked(symbols, size: 60) {
            let list = chunk.map(\.full).joined(separator: ",")
            guard let url = URL(string: "https://qt.gtimg.cn/q=\(list)") else { throw ProviderError.invalidData("URL") }
            let data = try await http.send(URLRequest(url: url))
            guard let text = TextCodec.decodeGBK(data) else { throw ProviderError.invalidData("编码") }
            all += TencentParser.parseQuotes(text)
        }
        return all
    }

    func fetchKLine(symbol: StockSymbol, period: KLinePeriod) async throws -> KLineSeries {
        guard !symbol.isFuture,
              let url = URL(string: "https://web.ifzq.gtimg.cn/appstock/app/fqkline/get?param=\(symbol.full),\(period.tencentKey),,,\(KLineConfig.fetchCount),qfq") else {
            throw ProviderError.unsupported
        }
        let data = try await http.send(URLRequest(url: url))
        return try TencentParser.parseKLine(data, symbol: symbol, period: period)
    }

    func fetchMinute(symbol: StockSymbol) async throws -> MinuteSeries {
        if symbol.isFuture {
            guard let code = FuturesCatalog.tencentCode(secid: symbol.code),
                  let url = URL(string: "https://web.ifzq.gtimg.cn/appstock/app/UsMinute/query?code=\(code)") else {
                throw ProviderError.unsupported
            }
            let data = try await http.send(URLRequest(url: url))
            return try TencentParser.parseUSMinute(data, symbol: symbol, code: code)
        }
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
    /// 解析 fqkline:`["日期","开","收","高","低","量(手)"]`;复权数据在 `qfq<周期>`,指数在 `<周期>`。
    /// 指数成交量单位与 A 股不一致,一律记 0(图表自动隐藏量能)
    static func parseKLine(_ data: Data, symbol: StockSymbol, period: KLinePeriod) throws -> KLineSeries {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let all = root["data"] as? [String: Any],
              let node = all[symbol.full] as? [String: Any],
              let rows = (node["qfq" + period.tencentKey] ?? node[period.tencentKey]) as? [[Any]] else {
            throw ProviderError.invalidData("K线结构")
        }
        let isIndex = symbol.kind == .index
        let bars: [KLineBar] = rows.compactMap { r in
            guard r.count >= 5, let date = r[0] as? String,
                  let o = ParseUtil.double(r[1]), let c = ParseUtil.double(r[2]),
                  let h = ParseUtil.double(r[3]), let l = ParseUtil.double(r[4]), c > 0, h >= l else { return nil }
            let volume = (!isIndex && r.count > 5) ? ParseUtil.double(r[5]) ?? 0 : 0
            return KLineBar(date: date, open: o, close: c, high: h, low: l, volume: volume, amount: 0)
        }
        guard !bars.isEmpty else { throw ProviderError.invalidData("K线为空") }
        return KLineSeries(symbol: symbol, period: period, bars: bars, source: .tencent, decimals: symbol.kind.decimals)
    }

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

    /// 解析美股指数行情(腾讯 `usDJI` 等)。字段:
    /// 1 名称, 3 现价, 4 昨收, 5 今开, 6 成交量(股), 30 时间(美东), 31 涨跌额, 33 最高, 34 最低
    /// - Parameters:
    ///   - text: 响应文本
    ///   - requested: 请求的标的,用于把腾讯代码反查回 `StockSymbol`
    static func parseGlobalQuotes(_ text: String, requested: [StockSymbol]) -> [Quote] {
        var result: [Quote] = []
        for raw in text.split(whereSeparator: { $0 == "\n" || $0 == ";" }) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("v_"), let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.index(line.startIndex, offsetBy: 2)..<eq])
            guard let symbol = FuturesCatalog.symbol(tencentKey: key, among: requested) else { continue }
            let payload = line[line.index(after: eq)...].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            let f = payload.split(separator: "~", omittingEmptySubsequences: false).map(String.init)
            guard f.count > 34 else { continue }
            func d(_ i: Int) -> Double? { i < f.count ? Double(f[i]) : nil }
            let prev = d(4) ?? 0
            var price = d(3) ?? 0
            if price <= 0 { price = prev }
            result.append(Quote(
                symbol: symbol,
                name: FuturesCatalog.preset(secid: symbol.code)?.name ?? f[1],
                price: price, prevClose: prev, open: d(5) ?? 0,
                high: d(33) ?? price, low: d(34) ?? price,
                volume: d(6) ?? 0, amount: 0, turnover: nil, bids: [], asks: [],
                time: easternTime(f[30]), source: .tencent,
                openInterest: nil, decimalsHint: 2))
        }
        return result
    }

    /// 解析美东时间 `yyyy-MM-dd HH:mm:ss`
    static func easternTime(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/New_York")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: text)
    }

    /// 解析美股指数分时 `UsMinute`:`data.<code>.data.data` 为 `"HHMM 价格 累计量"`(美东时间,9:30-16:00),
    /// 昨收取自 `qt.<code>[4]`。横轴为美东 9:30-16:00 共 390 分钟。
    static func parseUSMinute(_ data: Data, symbol: StockSymbol, code: String) throws -> MinuteSeries {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataNode = root["data"] as? [String: Any],
              let node = dataNode[code] as? [String: Any],
              let inner = node["data"] as? [String: Any],
              let lines = inner["data"] as? [String] else {
            throw ProviderError.invalidData("分时结构")
        }
        var prevClose = 0.0
        if let qt = node["qt"] as? [String: Any], let arr = qt[code] as? [String], arr.count > 4 {
            prevClose = Double(arr[4]) ?? 0
        }
        let axis = MinuteAxis(segments: [.init(start: 9 * 60 + 30, end: 16 * 60)])
        var bars: [MinuteBar] = []
        var lastCum = 0.0
        for line in lines {
            let parts = line.split(separator: " ")
            guard parts.count >= 3, let hhmm = Int(parts[0]), let price = Double(parts[1]), price > 0,
                  let idx = axis.index(forMinute: hhmm / 100 * 60 + hhmm % 100) else { continue }
            let cum = Double(parts[2]) ?? lastCum
            let vol = max(cum - lastCum, 0)
            lastCum = max(cum, lastCum)
            if let last = bars.last, last.index == idx { bars.removeLast() }
            bars.append(MinuteBar(index: idx, price: price, volume: vol, avgPrice: nil))
        }
        guard !bars.isEmpty else { throw ProviderError.invalidData("分时为空") }
        if prevClose <= 0 { prevClose = bars[0].price }
        var series = MinuteSeries(symbol: symbol, prevClose: prevClose, date: inner["date"] as? String, bars: bars, source: .tencent)
        series.axis = axis
        series.decimalsHint = 2
        return series
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
