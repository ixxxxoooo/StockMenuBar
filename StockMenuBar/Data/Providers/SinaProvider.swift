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
    let capabilities: Set<ProviderCapability> = [.quotes, .minute, .search, .futuresQuotes, .futuresMinute]
    private let http: HTTPClient

    init(http: HTTPClient) { self.http = http }

    /// 期货:仅能服务有新浪代码映射的标的;分时支持国内期货(nf_)与外盘期货(hf_),全球指数(znb_/gb_)无分时
    func canServe(_ capability: ProviderCapability, symbol: StockSymbol?) -> Bool {
        guard capabilities.contains(capability) else { return false }
        guard let symbol, symbol.isFuture else { return true }
        guard let mapping = FuturesCatalog.sinaMapping(secid: symbol.code) else { return false }
        return capability == .futuresMinute ? (mapping.code.hasPrefix("nf_") || mapping.code.hasPrefix("hf_")) : true
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

    /// 分时:A 股/指数(1 分钟 K 线合成)、国内期货(getMinLine)、外盘期货(getGlobalFuturesMinLine)
    func fetchMinute(symbol: StockSymbol) async throws -> MinuteSeries {
        if !symbol.isFuture { return try await fetchAShareMinute(symbol: symbol) }
        guard let mapping = FuturesCatalog.sinaMapping(secid: symbol.code) else { throw ProviderError.unsupported }
        let key = String(mapping.code.dropFirst(3))
        if mapping.code.hasPrefix("nf_") {
            let data = try await get("https://stock2.finance.sina.com.cn/futures/api/jsonp.php/var%20t=/InnerFuturesNewService.getMinLine?symbol=\(key)")
            return try SinaParser.parseFuturesMinute(data, symbol: symbol, sinaKey: key)
        }
        if mapping.code.hasPrefix("hf_") {
            let data = try await get("https://stock2.finance.sina.com.cn/futures/api/jsonp.php/var%20t=/GlobalFuturesService.getGlobalFuturesMinLine?symbol=\(key)")
            return try SinaParser.parseGlobalFuturesMinute(data, symbol: symbol, scale: mapping.scale)
        }
        throw ProviderError.unsupported
    }

    /// A 股分时:取 1 分钟 K 线最近 250 根,只保留最新交易日
    private func fetchAShareMinute(symbol: StockSymbol) async throws -> MinuteSeries {
        let data = try await get("https://quotes.sina.cn/cn/api/jsonp_v2.php/var%20t=/CN_MarketDataService.getKLineData?symbol=\(symbol.full)&scale=1&ma=no&datalen=250")
        return try SinaParser.parseAShareMinute(data, symbol: symbol)
    }

    /// 带 Referer 的 GET 请求
    private func get(_ urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else { throw ProviderError.invalidData("URL") }
        var request = URLRequest(url: url)
        request.setValue("https://finance.sina.com.cn", forHTTPHeaderField: "Referer")
        return try await http.send(request)
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
    /// - 全球指数 `znb_`:1 现价, 6/7 日期时间, 8 今开, 9 昨收, 10 最高, 11 最低
    /// - 美股指数 `gb_`:1 现价, 3 时间, 4 涨跌额, 5 今开, 6 最高, 7 最低, 10 成交量, 26 昨收
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
            } else if key.lowercased().hasPrefix("gb_") {
                // 美股指数:1 现价, 3 时间(北京时间), 4 涨跌额, 5 今开, 6 最高, 7 最低, 10 成交量(股), 26 昨收
                guard f.count > 10 else { continue }
                // 新浪美股指数价格带浮点噪声(如 51621.4805),统一保留 2 位
                func r(_ v: Double?) -> Double? { v.map { ($0 * 100).rounded() / 100 } }
                let price = r(d(1)) ?? 0
                var prev = r(d(26)) ?? 0
                if prev <= 0, let change = r(d(4)) { prev = price - change }
                quote = Quote(symbol: symbol, name: presetName ?? f[0], price: price, prevClose: prev, open: r(d(5)) ?? 0,
                              high: r(d(6)) ?? price, low: r(d(7)) ?? price, volume: d(10) ?? 0, amount: 0, turnover: nil,
                              bids: [], asks: [], time: ChinaTime.parse(compact: f[3]), source: .sina,
                              openInterest: nil, decimalsHint: 2)
            } else if key.lowercased().hasPrefix("znb_") {
                // 全球指数:1 现价, 8 今开, 9 昨收, 10 最高, 11 最低
                guard f.count > 11 else { continue }
                let prev = d(9) ?? 0
                var price = d(1) ?? 0
                if price <= 0 { price = prev }
                quote = Quote(symbol: symbol, name: presetName ?? f[0], price: price, prevClose: prev, open: d(8) ?? 0,
                              high: d(10) ?? price, low: d(11) ?? price, volume: 0, amount: 0, turnover: nil,
                              bids: [], asks: [], time: f.count > 7 ? ChinaTime.parse(day: f[6], time: f[7]) : nil, source: .sina,
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

    /// 解析外盘期货分时(getGlobalFuturesMinLine):
    /// 首行 `[日期, 昨收, 交易所, "", 时间, 价格, 量, 0, 均价, 完整时间]`,其余行 `[时间, 价格, 量, 0, 均价, 完整时间]`。
    /// 完整时间为北京时间,横轴为单一连续时段(起点取首行时刻,时长按交易所给出)。
    /// - Parameters:
    ///   - scale: 价格换算系数(COMEX 铜新浪为美分)
    static func parseGlobalFuturesMinute(_ data: Data, symbol: StockSymbol, scale: Double) throws -> MinuteSeries {
        guard let text = String(data: data, encoding: .utf8) ?? TextCodec.decodeGBK(data),
              let open = text.range(of: "var t=("), let close = text.lastIndex(of: ")") else {
            throw ProviderError.invalidData("分时结构")
        }
        let json = String(text[open.upperBound..<close])
        guard let root = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let rows = root["minLine_1d"] as? [[Any]], rows.count > 1,
              let head = rows.first, head.count >= 10 else {
            throw ProviderError.invalidData("分时为空")
        }
        let exchange = (head[2] as? String ?? "").lowercased()
        let prev = (Double(head[1] as? String ?? "") ?? 0) * scale
        // 完整时间 `yyyy-MM-dd HH:mm:ss` -> 自首日零点起的分钟
        func minute(_ row: [Any]) -> (day: Int, minute: Int)? {
            guard let stamp = row.last as? String, stamp.count >= 16 else { return nil }
            let parts = stamp.split(separator: " ")
            guard parts.count == 2, let day = EastmoneyParser.dayNumber(String(parts[0])) else { return nil }
            let hm = parts[1].split(separator: ":").compactMap { Int($0) }
            guard hm.count >= 2 else { return nil }
            return (day, hm[0] * 60 + hm[1])
        }
        guard let first = minute(head) else { throw ProviderError.invalidData("分时时间") }
        // 各交易所连续时段时长(分钟):CME/LIFFE 约 23 小时,LME/ICE 约 19 小时
        let length = (exchange == "lme" || exchange == "ice") ? 1140 : 1380
        let axis = MinuteAxis(segments: [.init(start: first.minute, end: first.minute + length)])
        var bars: [MinuteBar] = []
        for (i, row) in rows.enumerated() {
            guard let t = minute(row) else { continue }
            let priceIndex = i == 0 ? 5 : 1
            let volIndex = i == 0 ? 6 : 2
            let avgIndex = i == 0 ? 8 : 4
            guard row.count > avgIndex, let raw = Double(row[priceIndex] as? String ?? ""), raw > 0,
                  let idx = axis.index(forMinute: (t.day - first.day) * 1440 + t.minute) else { continue }
            let avg = (Double(row[avgIndex] as? String ?? "") ?? 0) * scale
            let vol = Double(row[volIndex] as? String ?? "") ?? 0
            if let last = bars.last, last.index == idx { bars.removeLast() }
            bars.append(MinuteBar(index: idx, price: raw * scale, volume: vol, avgPrice: avg > 0 ? avg : nil))
        }
        guard !bars.isEmpty else { throw ProviderError.invalidData("分时为空") }
        let date = (head[0] as? String)?.replacingOccurrences(of: "-", with: "")
        var series = MinuteSeries(symbol: symbol, prevClose: prev > 0 ? prev : bars[0].price, date: date, bars: bars, source: .sina)
        series.axis = axis
        series.decimalsHint = inferDecimals(bars[0].price)
        return series
    }

    /// 解析 A 股 1 分钟 K 线并合成分时:`[{"day":"2026-10-15 14:54:00","close":"..","volume":"股","amount":"元"}]`
    /// 只保留最新交易日;均价为累计成交额 / 累计成交量;新浪不提供昨收,先用首根开盘价占位(由行情昨收覆盖)。
    static func parseAShareMinute(_ data: Data, symbol: StockSymbol) throws -> MinuteSeries {
        guard let text = String(data: data, encoding: .utf8) ?? TextCodec.decodeGBK(data),
              let open = text.range(of: "var t=("), let close = text.lastIndex(of: ")") else {
            throw ProviderError.invalidData("分时结构")
        }
        let json = String(text[open.upperBound..<close])
        guard let rows = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: String]], !rows.isEmpty else {
            throw ProviderError.invalidData("分时为空")
        }
        guard let lastDay = rows.last?["day"].map({ String($0.prefix(10)) }) else { throw ProviderError.invalidData("分时时间") }
        let isIndex = symbol.kind == .index
        var bars: [MinuteBar] = []
        var cumVolume = 0.0
        var cumAmount = 0.0
        var firstOpen: Double?
        for row in rows {
            guard let day = row["day"], day.hasPrefix(lastDay), day.count >= 16,
                  let price = Double(row["close"] ?? ""), price > 0 else { continue }
            let hm = day.dropFirst(11).prefix(5).split(separator: ":").compactMap { Int($0) }
            guard hm.count == 2, let idx = MinuteBar.index(hour: hm[0], minute: hm[1]) else { continue }
            if firstOpen == nil { firstOpen = Double(row["open"] ?? "") }
            let shares = Double(row["volume"] ?? "") ?? 0
            let amount = Double(row["amount"] ?? "") ?? 0
            cumVolume += shares
            cumAmount += amount
            let avg: Double? = (!isIndex && cumVolume > 0) ? cumAmount / cumVolume : nil
            if let last = bars.last, last.index == idx { bars.removeLast() }
            bars.append(MinuteBar(index: idx, price: price, volume: isIndex ? shares : shares / 100, avgPrice: avg))
        }
        guard !bars.isEmpty else { throw ProviderError.invalidData("分时为空") }
        return MinuteSeries(symbol: symbol, prevClose: firstOpen ?? bars[0].price,
                            date: lastDay.replacingOccurrences(of: "-", with: ""), bars: bars, source: .sina)
    }
}
