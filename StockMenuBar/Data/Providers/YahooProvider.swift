//
//  YahooProvider.swift
//  StockMenuBar
//
//  雅虎财经源(全球指数与外盘期货的补充数据源):基于公开的 chart 接口,同时提供实时行情与当日分时。
//  - 仅覆盖预置目录中配置了雅虎代码的标的(美股/日韩/欧洲指数、COMEX/NYMEX/ICE 期货)
//  - 国内访问不一定稳定,因此只作为最后的兜底源,由路由按健康度自动决定是否启用
//  @author ixxxxoooo
//

import Foundation

struct YahooProvider: QuoteProvider {
    let id: ProviderID = .yahoo
    let capabilities: Set<ProviderCapability> = [.futuresQuotes, .futuresMinute, .kline]
    private let http: HTTPClient

    init(http: HTTPClient) { self.http = http }

    /// 仅能服务配置了雅虎代码的期货/全球指数
    func canServe(_ capability: ProviderCapability, symbol: StockSymbol?) -> Bool {
        guard capabilities.contains(capability) else { return false }
        guard let symbol else { return true }
        return symbol.isFuture && FuturesCatalog.yahooCode(secid: symbol.code) != nil
    }

    /// 批量行情:每个标的一次 chart 请求(5 分钟粒度,体积小),并发获取;部分失败不影响其余
    func fetchQuotes(_ symbols: [StockSymbol]) async throws -> [Quote] {
        let targets = symbols.filter { canServe(.futuresQuotes, symbol: $0) }
        guard !targets.isEmpty else { return [] }
        let http = self.http
        return try await withThrowingTaskGroup(of: Quote?.self) { group in
            for symbol in targets {
                group.addTask {
                    guard let code = FuturesCatalog.yahooCode(secid: symbol.code) else { return nil }
                    let data = try await Self.fetchChart(http: http, code: code, interval: "5m")
                    return try YahooParser.parseQuote(data, symbol: symbol)
                }
            }
            var quotes: [Quote] = []
            var lastError: Error?
            while true {
                do {
                    guard let next = try await group.next() else { break }
                    if let next { quotes.append(next) }
                } catch {
                    lastError = error
                }
            }
            if quotes.isEmpty, let lastError { throw lastError }
            return quotes
        }
    }

    /// 当日分时(1 分钟粒度)
    func fetchMinute(symbol: StockSymbol) async throws -> MinuteSeries {
        guard let code = FuturesCatalog.yahooCode(secid: symbol.code) else { throw ProviderError.unsupported }
        let data = try await Self.fetchChart(http: http, code: code, interval: "1m")
        return try YahooParser.parseMinute(data, symbol: symbol)
    }

    /// 日/周/月 K 线:interval 1d/1wk/1mo,区间按周期取足 250 根以上
    func fetchKLine(symbol: StockSymbol, period: KLinePeriod) async throws -> KLineSeries {
        guard let code = FuturesCatalog.yahooCode(secid: symbol.code) else { throw ProviderError.unsupported }
        let (interval, range) = [KLinePeriod.day: ("1d", "2y"), .week: ("1wk", "6y"), .month: ("1mo", "max")][period] ?? ("1d", "2y")
        let data = try await Self.fetchChart(http: http, code: code, interval: interval, range: range)
        return try YahooParser.parseKLine(data, symbol: symbol, period: period)
    }

    /// 请求 chart 接口:query1 失败时换 query2 再试一次
    private static func fetchChart(http: HTTPClient, code: String, interval: String, range: String = "1d") async throws -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))
        let encoded = code.addingPercentEncoding(withAllowedCharacters: allowed) ?? code
        var lastError: Error = ProviderError.emptyResponse
        for host in ["query1", "query2"] {
            guard let url = URL(string: "https://\(host).finance.yahoo.com/v8/finance/chart/\(encoded)?interval=\(interval)&range=\(range)") else {
                throw ProviderError.invalidData("URL")
            }
            do { return try await http.send(URLRequest(url: url)) } catch { lastError = error }
        }
        throw lastError
    }
}

/// 雅虎 chart 数据解析(纯函数,便于测试)
enum YahooParser {
    /// chart 响应的中间表示
    struct Chart {
        let price: Double
        let prevClose: Double
        let dayHigh: Double
        let dayLow: Double
        let volume: Double
        let marketTime: Date?
        let gmtOffset: Int
        let regularStart: Int
        let regularEnd: Int
        let timestamps: [Int]
        let opens: [Double?]
        let highs: [Double?]
        let lows: [Double?]
        let closes: [Double?]
        let volumes: [Double?]
    }

    /// 解析 chart JSON
    static func parseChart(_ data: Data) throws -> Chart {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let chart = root["chart"] as? [String: Any],
              let results = chart["result"] as? [[String: Any]], let result = results.first,
              let meta = result["meta"] as? [String: Any] else {
            throw ProviderError.invalidData("雅虎结构")
        }
        let timestamps = (result["timestamp"] as? [Any])?.compactMap { ParseUtil.double($0).map { Int($0) } } ?? []
        let quote = ((result["indicators"] as? [String: Any])?["quote"] as? [[String: Any]])?.first ?? [:]
        func series(_ key: String) -> [Double?] {
            (quote[key] as? [Any])?.map { ParseUtil.double($0) } ?? []
        }
        let regular = (meta["currentTradingPeriod"] as? [String: Any])?["regular"] as? [String: Any]
        let closes = series("close")
        let price = ParseUtil.double(meta["regularMarketPrice"]) ?? closes.compactMap { $0 }.last ?? 0
        var prev = ParseUtil.double(meta["chartPreviousClose"]) ?? 0
        if prev <= 0 { prev = ParseUtil.double(meta["previousClose"]) ?? 0 }
        return Chart(
            price: price,
            prevClose: prev,
            dayHigh: ParseUtil.double(meta["regularMarketDayHigh"]) ?? 0,
            dayLow: ParseUtil.double(meta["regularMarketDayLow"]) ?? 0,
            volume: ParseUtil.double(meta["regularMarketVolume"]) ?? 0,
            marketTime: ParseUtil.double(meta["regularMarketTime"]).map { Date(timeIntervalSince1970: $0) },
            gmtOffset: Int(ParseUtil.double(meta["gmtoffset"]) ?? 0),
            regularStart: Int(ParseUtil.double(regular?["start"]) ?? 0),
            regularEnd: Int(ParseUtil.double(regular?["end"]) ?? 0),
            timestamps: timestamps,
            opens: series("open"), highs: series("high"), lows: series("low"),
            closes: closes, volumes: series("volume")
        )
    }

    /// 由 chart 生成实时行情。指数最高/最低在元数据中常为 0,此时用分时点自行统计。
    static func parseQuote(_ data: Data, symbol: StockSymbol) throws -> Quote {
        let chart = try parseChart(data)
        guard chart.price > 0, chart.prevClose > 0 else { throw ProviderError.invalidData("雅虎行情为空") }
        let barHighs = chart.highs.compactMap { $0 }
        let barLows = chart.lows.compactMap { $0 }
        let high = chart.dayHigh > 0 ? chart.dayHigh : (barHighs.max() ?? chart.price)
        let low = chart.dayLow > 0 ? chart.dayLow : (barLows.min() ?? chart.price)
        let isIndex = symbol.code.hasPrefix("100.")
        return Quote(
            symbol: symbol,
            name: FuturesCatalog.preset(secid: symbol.code)?.name ?? symbol.displayCode,
            price: chart.price,
            prevClose: chart.prevClose,
            open: chart.opens.compactMap { $0 }.first ?? chart.price,
            high: max(high, chart.price),
            low: min(low, chart.price),
            volume: chart.volume,
            amount: 0, turnover: nil, bids: [], asks: [],
            time: chart.marketTime, source: .yahoo,
            openInterest: nil,
            decimalsHint: isIndex ? 2 : SinaParser.inferDecimals(chart.price)
        )
    }

    /// 由 chart 生成当日分时。
    /// 横轴为单一连续时段:时长取常规交易时段长度,起点为数据首个时间点所在交易日的开盘;
    /// 指数用交易所本地时间,期货统一用北京时间(与东财/新浪的外盘分时口径一致)。
    static func parseMinute(_ data: Data, symbol: StockSymbol) throws -> MinuteSeries {
        let chart = try parseChart(data)
        guard let firstStamp = chart.timestamps.first, chart.prevClose > 0 else {
            throw ProviderError.invalidData("雅虎分时为空")
        }
        var length = max((chart.regularEnd - chart.regularStart) / 60, 60)
        // 常规时段给的是「最近/下一个」交易日,按整天平移到数据所在交易日(留 3 小时容差吸收夏令时)
        let dayShift = Int(floor(Double(firstStamp - chart.regularStart + 3 * 3600) / 86_400))
        let sessionStart = chart.regularStart > 0 ? chart.regularStart + dayShift * 86_400 : firstStamp
        // 实际数据超出常规时段(如收盘集合竞价)时,横轴以实际末尾为准,避免丢点
        if let lastStamp = chart.timestamps.last { length = max(length, (lastStamp - sessionStart) / 60) }
        let isIndex = symbol.code.hasPrefix("100.")
        let offset = isIndex ? chart.gmtOffset : 8 * 3600
        let localSeconds = sessionStart + offset
        let startMinute = ((localSeconds % 86_400) + 86_400) % 86_400 / 60
        let axis = MinuteAxis(segments: [.init(start: startMinute, end: startMinute + length)])

        var bars: [MinuteBar] = []
        for (i, stamp) in chart.timestamps.enumerated() {
            guard i < chart.closes.count, let price = chart.closes[i], price > 0 else { continue }
            let minute = startMinute + (stamp - sessionStart) / 60
            guard let idx = axis.index(forMinute: minute) else { continue }
            let volume = i < chart.volumes.count ? (chart.volumes[i] ?? 0) : 0
            if let last = bars.last, last.index == idx { bars.removeLast() }
            bars.append(MinuteBar(index: idx, price: price, volume: volume, avgPrice: nil))
        }
        guard !bars.isEmpty else { throw ProviderError.invalidData("雅虎分时为空") }
        // 部分指数(如 KOSPI)的量能几乎全集中在某一分钟(多为收盘集合竞价),这类量能没有参考价值,整体丢弃
        let total = bars.reduce(0) { $0 + $1.volume }
        if total <= 0 || (bars.count >= 30 && (bars.map(\.volume).max() ?? 0) > total * 0.25) {
            bars = bars.map { MinuteBar(index: $0.index, price: $0.price, volume: 0, avgPrice: $0.avgPrice) }
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: offset) ?? .gmt
        let c = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: TimeInterval(sessionStart)))
        let date = String(format: "%04d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        var series = MinuteSeries(symbol: symbol, prevClose: chart.prevClose, date: date, bars: bars, source: .yahoo)
        series.axis = axis
        series.decimalsHint = isIndex ? 2 : SinaParser.inferDecimals(bars[0].price)
        return series
    }
}
