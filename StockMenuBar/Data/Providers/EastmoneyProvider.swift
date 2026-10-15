//
//  EastmoneyProvider.swift
//  StockMenuBar
//
//  东财行情源(第三源):批量实时行情(无五档)、当日分时、搜索联想。
//  @author ixxxxoooo
//

import Foundation

struct EastmoneyProvider: QuoteProvider {
    let id: ProviderID = .eastmoney
    let capabilities: Set<ProviderCapability> = [.quotes, .minute, .search, .futuresQuotes, .futuresMinute, .futuresSearch]
    private let http: HTTPClient

    init(http: HTTPClient) { self.http = http }

    func fetchQuotes(_ symbols: [StockSymbol]) async throws -> [Quote] {
        guard !symbols.isEmpty else { return [] }
        var all: [Quote] = []
        for chunk in ParseUtil.chunked(symbols, size: 80) {
            let secids = chunk.map(\.eastmoneySecid).joined(separator: ",")
            // f1 报价小数位,f28 昨结算,f108 持仓量(期货字段,A 股请求时忽略)
            let fields = "f1,f2,f3,f4,f5,f6,f8,f12,f13,f14,f15,f16,f17,f18,f28,f108"
            guard let url = URL(string: "https://push2.eastmoney.com/api/qt/ulist.np/get?fltt=2&secids=\(secids)&fields=\(fields)") else {
                throw ProviderError.invalidData("URL")
            }
            let data = try await http.send(URLRequest(url: url))
            all += try EastmoneyParser.parseQuotes(data, requested: chunk)
        }
        return all
    }

    func fetchMinute(symbol: StockSymbol) async throws -> MinuteSeries {
        let f1 = "f1,f2,f3,f4,f5,f6,f7,f8,f9,f10,f11,f12,f13"
        let f2 = "f51,f52,f53,f54,f55,f56,f57,f58"
        guard let url = URL(string: "https://push2his.eastmoney.com/api/qt/stock/trends2/get?secid=\(symbol.eastmoneySecid)&fields1=\(f1)&fields2=\(f2)&iscr=0&ndays=1") else {
            throw ProviderError.invalidData("URL")
        }
        let data = try await http.send(URLRequest(url: url))
        return try EastmoneyParser.parseMinute(data, symbol: symbol)
    }

    func search(keyword: String) async throws -> [SearchResult] {
        let key = ParseUtil.encodeQuery(keyword)
        guard let url = URL(string: "https://searchapi.eastmoney.com/api/suggest/get?input=\(key)&type=14&token=D43BF722C8E33BDC906FB84D85E326E8&count=10") else {
            throw ProviderError.invalidData("URL")
        }
        let data = try await http.send(URLRequest(url: url))
        return try EastmoneyParser.parseSearch(data)
    }

    func searchFutures(keyword: String) async throws -> [SearchResult] {
        let key = ParseUtil.encodeQuery(keyword)
        guard let url = URL(string: "https://searchapi.eastmoney.com/api/suggest/get?input=\(key)&type=14&token=D43BF722C8E33BDC906FB84D85E326E8&count=20") else {
            throw ProviderError.invalidData("URL")
        }
        let data = try await http.send(URLRequest(url: url))
        return try EastmoneyParser.parseFuturesSearch(data)
    }
}

/// 东财数据解析(纯函数,便于测试)
enum EastmoneyParser {
    /// 解析 ulist.np 行情。fltt=2 时价格已是小数:
    /// f2 现价, f5 成交量(手), f6 成交额(元), f8 换手率, f12 代码, f13 市场, f14 名称, f15 最高, f16 最低, f17 今开, f18 昨收
    /// - Parameters:
    ///   - data: 响应
    ///   - requested: 请求的证券,用于把 (f13,f12) 映射回带前缀的 StockSymbol(区分沪深同号)
    static func parseQuotes(_ data: Data, requested: [StockSymbol]) throws -> [Quote] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataNode = root["data"] as? [String: Any],
              let diff = dataNode["diff"] as? [[String: Any]] else {
            throw ProviderError.invalidData("行情结构")
        }
        var byKey: [String: StockSymbol] = [:]
        for s in requested { byKey[s.eastmoneySecid] = s }
        var result: [Quote] = []
        for item in diff {
            guard let code = item["f12"] as? String else { continue }
            let market = Int(ParseUtil.double(item["f13"]) ?? -1)
            guard let symbol = byKey["\(market).\(code)"] else { continue }
            // 期货涨跌以昨结算价为基准,A 股以昨收为基准
            var prev = ParseUtil.double(item["f18"]) ?? 0
            let settle = ParseUtil.double(item["f28"]) ?? 0
            if symbol.isFuture, settle > 0 { prev = settle }
            var price = ParseUtil.double(item["f2"]) ?? 0
            if price <= 0 { price = prev }
            result.append(Quote(
                symbol: symbol,
                name: item["f14"] as? String ?? symbol.code,
                price: price,
                prevClose: prev,
                open: ParseUtil.double(item["f17"]) ?? 0,
                high: ParseUtil.double(item["f15"]) ?? price,
                low: ParseUtil.double(item["f16"]) ?? price,
                volume: ParseUtil.double(item["f5"]) ?? 0,
                amount: ParseUtil.double(item["f6"]) ?? 0,
                turnover: ParseUtil.double(item["f8"]),
                bids: [],
                asks: [],
                time: nil,
                source: .eastmoney,
                openInterest: symbol.isFuture ? ParseUtil.double(item["f108"]) : nil,
                decimalsHint: symbol.isFuture ? ParseUtil.double(item["f1"]).map { Int($0) } : nil
            ))
        }
        return result
    }

    /// 解析分时 trends2:`"2026-10-15 09:30,开,收,高,低,量(手),额,均价"`
    static func parseMinute(_ data: Data, symbol: StockSymbol) throws -> MinuteSeries {
        if symbol.isFuture { return try parseFutureMinute(data, symbol: symbol) }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let node = root["data"] as? [String: Any],
              let trends = node["trends"] as? [String] else {
            throw ProviderError.invalidData("分时结构")
        }
        let isIndex = symbol.kind == .index
        var bars: [MinuteBar] = []
        var day: String?
        for line in trends {
            let f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 8, f[0].count >= 16 else { continue }
            let stamp = f[0]
            if day == nil { day = String(stamp.prefix(10)).replacingOccurrences(of: "-", with: "") }
            let timePart = stamp.suffix(5)
            let hm = timePart.split(separator: ":")
            guard hm.count == 2, let h = Int(hm[0]), let m = Int(hm[1]),
                  let idx = MinuteBar.index(hour: h, minute: m),
                  let price = Double(f[2]), price > 0 else { continue }
            let vol = Double(f[5]) ?? 0
            let avgValue = Double(f[7]) ?? 0
            let avg: Double? = (isIndex || avgValue <= 0) ? nil : avgValue
            if let last = bars.last, last.index == idx { bars.removeLast() }
            bars.append(MinuteBar(index: idx, price: price, volume: vol, avgPrice: avg))
        }
        guard !bars.isEmpty else { throw ProviderError.invalidData("分时为空") }
        var prev = ParseUtil.double(node["preClose"]) ?? 0
        if prev <= 0 { prev = bars[0].price }
        return MinuteSeries(symbol: symbol, prevClose: prev, date: day, bars: bars, source: .eastmoney)
    }

    /// 解析搜索联想:`QuotationCodeTable.Data[]`
    static func parseSearch(_ data: Data) throws -> [SearchResult] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let table = root["QuotationCodeTable"] as? [String: Any] else {
            throw ProviderError.invalidData("搜索结构")
        }
        guard let items = table["Data"] as? [[String: Any]] else { return [] }
        var results: [SearchResult] = []
        for item in items {
            guard let code = item["Code"] as? String, let name = item["Name"] as? String else { continue }
            let mktNum = item["MktNum"] as? String ?? ""
            let market: Market
            if mktNum == "1" {
                market = .sh
            } else if mktNum == "0" {
                market = StockSymbol.resolve(code: code)?.market == .bj ? .bj : .sz
            } else {
                continue
            }
            let symbol = StockSymbol(market: market, code: code)
            let pinyin = (item["PinYin"] as? String) ?? Pinyin.initials(name)
            results.append(SearchResult(symbol: symbol, name: name, pinyin: pinyin.uppercased()))
        }
        return results
    }

    // MARK: - 期货

    /// 解析期货分时:横轴由 `beticks` 给出的交易时段(自零点起的秒数)拼接而成,支持夜盘跨零点。
    /// `beticks` 形如 `开始|开始|结束|段1开始|段1结束|段2开始|段2结束...`
    static func parseFutureMinute(_ data: Data, symbol: StockSymbol) throws -> MinuteSeries {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let node = root["data"] as? [String: Any],
              let trends = node["trends"] as? [String] else {
            throw ProviderError.invalidData("分时结构")
        }
        // 解析时段
        var segments: [MinuteAxis.Segment] = []
        if let raw = node["beticks"] as? String {
            let nums = raw.split(separator: "|").compactMap { Int($0) }
            if nums.count >= 5, (nums.count - 3) % 2 == 0 {
                var i = 3
                while i + 1 < nums.count {
                    if nums[i + 1] > nums[i] { segments.append(.init(start: nums[i] / 60, end: nums[i + 1] / 60)) }
                    i += 2
                }
            } else if nums.count >= 3, nums[2] > nums[0] {
                segments = [.init(start: nums[0] / 60, end: nums[2] / 60)]
            }
        }
        // 先解析原始点:(自首日零点起的分钟, 价格, 量, 均价)
        struct Raw { let minute: Int; let price: Double; let volume: Double; let avg: Double? }
        var raws: [Raw] = []
        var firstDay: Int?
        var firstDate: String?
        for line in trends {
            let f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 8, f[0].count >= 16 else { continue }
            let datePart = String(f[0].prefix(10))
            guard let day = dayNumber(datePart), let price = Double(f[2]), price > 0 else { continue }
            let hm = f[0].suffix(5).split(separator: ":")
            guard hm.count == 2, let h = Int(hm[0]), let m = Int(hm[1]) else { continue }
            if firstDay == nil { firstDay = day; firstDate = datePart.replacingOccurrences(of: "-", with: "") }
            let avgValue = Double(f[7]) ?? 0
            raws.append(Raw(minute: (day - (firstDay ?? day)) * 1440 + h * 60 + m, price: price,
                            volume: Double(f[5]) ?? 0, avg: avgValue > 0 ? avgValue : nil))
        }
        guard let first = raws.first else { throw ProviderError.invalidData("分时为空") }
        if segments.isEmpty {
            // 无时段信息:按实际数据首尾兜底成单一时段
            segments = [.init(start: first.minute, end: max(raws.last?.minute ?? first.minute, first.minute + 1))]
        }
        // 首点早于首个时段起点(例如数据只含日盘):整体平移一天
        let shift = (first.minute < segments[0].start && first.minute + 1440 <= (segments.last?.end ?? 0)) ? 1440 : 0
        let axis = MinuteAxis(segments: segments)
        var bars: [MinuteBar] = []
        for r in raws {
            guard let idx = axis.index(forMinute: r.minute + shift) else { continue }
            if let last = bars.last, last.index == idx { bars.removeLast() }
            bars.append(MinuteBar(index: idx, price: r.price, volume: r.volume, avgPrice: r.avg))
        }
        guard !bars.isEmpty else { throw ProviderError.invalidData("分时为空") }
        var prev = ParseUtil.double(node["preSettlement"]) ?? 0
        if prev <= 0 { prev = ParseUtil.double(node["preClose"]) ?? 0 }
        if prev <= 0 { prev = bars[0].price }
        var series = MinuteSeries(symbol: symbol, prevClose: prev, date: firstDate, bars: bars, source: .eastmoney)
        series.axis = axis
        series.decimalsHint = ParseUtil.double(node["decimal"]).map { Int($0) }
        return series
    }

    /// 解析期货与全球指数搜索:保留 `Futures`、`UniversalFutures` 与市场号 100 的 `UniversalIndex`
    static func parseFuturesSearch(_ data: Data) throws -> [SearchResult] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let table = root["QuotationCodeTable"] as? [String: Any] else {
            throw ProviderError.invalidData("搜索结构")
        }
        guard let items = table["Data"] as? [[String: Any]] else { return [] }
        var results: [SearchResult] = []
        for item in items {
            guard let quoteID = item["QuoteID"] as? String, let name = item["Name"] as? String,
                  let classify = item["Classify"] as? String else { continue }
            let mkt = item["MktNum"] as? String ?? ""
            let isFutures = classify == "Futures" || classify == "UniversalFutures"
            let isGlobalIndex = classify == "UniversalIndex" && mkt == "100"
            guard isFutures || isGlobalIndex, quoteID.contains(".") else { continue }
            let symbol = StockSymbol(market: .future, code: quoteID)
            let pinyin = (item["PinYin"] as? String) ?? Pinyin.initials(name)
            results.append(SearchResult(symbol: symbol, name: name, pinyin: pinyin.uppercased()))
        }
        return results
    }

    /// 公历日期 `yyyy-MM-dd` 转为连续天数(仅用于求差)
    static func dayNumber(_ text: String) -> Int? {
        let p = text.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        // days_from_civil 算法
        let y = p[1] <= 2 ? p[0] - 1 : p[0]
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (p[1] + 9) % 12
        let doy = (153 * mp + 2) / 5 + p[2] - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe
    }
}
