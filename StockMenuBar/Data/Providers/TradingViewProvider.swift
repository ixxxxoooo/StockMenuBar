//
//  TradingViewProvider.swift
//  StockMenuBar
//
//  TradingView 数据源(仅现货黄金 OANDA:XAUUSD,单独处理):
//  - 实时行情:scanner 公开接口
//  - 分时 / 日周月 K 线:匿名 WebSocket(与网页图表同一通道,非官方公开接口,可能变动)
//  只服务预置表里配置了 TradingView 代码的品种,其余品种不会路由到这里。
//  @author ixxxxoooo
//

import Foundation

struct TradingViewProvider: QuoteProvider {
    let id: ProviderID = .tradingview
    let capabilities: Set<ProviderCapability> = [.futuresQuotes, .futuresMinute, .kline]
    private let http: HTTPClient

    init(http: HTTPClient) { self.http = http }

    func canServe(_ capability: ProviderCapability, symbol: StockSymbol?) -> Bool {
        guard capabilities.contains(capability) else { return false }
        guard let symbol else { return true }
        return symbol.isFuture && FuturesCatalog.tradingViewCode(secid: symbol.code) != nil
    }

    func fetchQuotes(_ symbols: [StockSymbol]) async throws -> [Quote] {
        var quotes: [Quote] = []
        for symbol in symbols where canServe(.futuresQuotes, symbol: symbol) {
            quotes.append(try await fetchQuote(symbol))
        }
        return quotes
    }

    private func fetchQuote(_ symbol: StockSymbol) async throws -> Quote {
        guard let code = FuturesCatalog.tradingViewCode(secid: symbol.code),
              let url = URL(string: "https://scanner.tradingview.com/symbol?symbol=\(code)&fields=close,open,high,low,change_abs,volume&no_404=true") else {
            throw ProviderError.unsupported
        }
        var request = URLRequest(url: url)
        request.setValue("https://cn.tradingview.com", forHTTPHeaderField: "Origin")
        return try TradingViewParser.parseQuote(try await http.send(request), symbol: symbol)
    }

    func fetchMinute(symbol: StockSymbol) async throws -> MinuteSeries {
        guard let code = FuturesCatalog.tradingViewCode(secid: symbol.code) else { throw ProviderError.unsupported }
        let quote = try await fetchQuote(symbol)
        let raw = try await TradingViewSocket.fetch(code: code, timeframe: "1", count: 1500)
        return try TradingViewParser.parseMinute(TradingViewParser.parseBars(raw), symbol: symbol, prevClose: quote.prevClose)
    }

    func fetchKLine(symbol: StockSymbol, period: KLinePeriod) async throws -> KLineSeries {
        guard let code = FuturesCatalog.tradingViewCode(secid: symbol.code) else { throw ProviderError.unsupported }
        let timeframe = [KLinePeriod.day: "1D", .week: "1W", .month: "1M"][period] ?? "1D"
        let raw = try await TradingViewSocket.fetch(code: code, timeframe: timeframe, count: KLineConfig.fetchCount)
        return try TradingViewParser.parseKLine(TradingViewParser.parseBars(raw), symbol: symbol, period: period)
    }
}

/// 匿名 WebSocket 取 K 线序列(一次请求一条连接,取完即关)
enum TradingViewSocket {
    private static func frame(_ m: String, _ p: [Any]) -> String {
        let body = (try? JSONSerialization.data(withJSONObject: ["m": m, "p": p])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return "~m~\(body.utf8.count)~m~\(body)"
    }

    /// 拉取原始报文
    /// - Parameters:
    ///   - code: 交易所:代码,如 `OANDA:XAUUSD`
    ///   - timeframe: 周期,`1`(分钟)、`1D`、`1W`、`1M`
    ///   - count: 根数
    /// - Returns: 累积的全部报文(含 timescale_update)
    static func fetch(code: String, timeframe: String, count: Int, timeout: TimeInterval = 10) async throws -> String {
        guard let url = URL(string: "wss://data.tradingview.com/socket.io/websocket") else { throw ProviderError.invalidData("URL") }
        var request = URLRequest(url: url)
        request.setValue("https://cn.tradingview.com", forHTTPHeaderField: "Origin")
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: request)
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel() }

        let chart = "cs_" + String((0..<12).map { _ in "abcdefghijklmnopqrstuvwxyz".randomElement() ?? "a" })
        let symbolJSON = "={\"symbol\":\"\(code)\",\"adjustment\":\"splits\"}"
        let handshake = [
            frame("set_auth_token", ["unauthorized_user_token"]),
            frame("chart_create_session", [chart, ""]),
            frame("resolve_symbol", [chart, "sds_sym_1", symbolJSON]),
            frame("create_series", [chart, "sds_1", "s1", "sds_sym_1", timeframe, count, ""])
        ]
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                for text in handshake { try await task.send(.string(text)) }
                var buffer = ""
                while true {
                    guard case .string(let text) = try await task.receive() else { continue }
                    for part in TradingViewParser.frames(text) {
                        if part.hasPrefix("~h~") { try await task.send(.string("~m~\(part.utf8.count)~m~\(part)")) }
                        if part.contains("\"symbol_error\"") || part.contains("\"critical_error\"") || part.contains("\"series_error\"") {
                            throw ProviderError.invalidData("TradingView 报错")
                        }
                    }
                    buffer += text
                    if text.contains("series_completed") { return buffer }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw ProviderError.invalidData("TradingView 超时")
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw ProviderError.emptyResponse }
            return result
        }
    }
}

/// TradingView 解析(纯函数,便于测试)
enum TradingViewParser {
    /// 单根原始 K 线
    struct RawBar: Sendable, Equatable {
        let time: TimeInterval
        let open: Double, high: Double, low: Double, close: Double, volume: Double
    }

    /// 拆分 `~m~长度~m~` 帧
    static func frames(_ raw: String) -> [String] {
        raw.replacing(/~m~\d+~m~/, with: "\u{1}").split(separator: "\u{1}").map(String.init)
    }

    /// 从报文中提取 K 线(按序号去重、按时间升序)
    static func parseBars(_ raw: String) throws -> [RawBar] {
        var byIndex: [Int: RawBar] = [:]
        for part in frames(raw) where part.hasPrefix("{") {
            guard let root = try? JSONSerialization.jsonObject(with: Data(part.utf8)) as? [String: Any],
                  let m = root["m"] as? String, m == "timescale_update" || m == "du",
                  let p = root["p"] as? [Any], p.count > 1,
                  let series = (p[1] as? [String: Any])?["sds_1"] as? [String: Any],
                  let rows = series["s"] as? [[String: Any]] else { continue }
            for row in rows {
                guard let i = row["i"] as? Int, let v = row["v"] as? [Any], v.count >= 5,
                      let t = ParseUtil.double(v[0]), let o = ParseUtil.double(v[1]), let h = ParseUtil.double(v[2]),
                      let l = ParseUtil.double(v[3]), let c = ParseUtil.double(v[4]) else { continue }
                byIndex[i] = RawBar(time: t, open: o, high: h, low: l, close: c, volume: v.count > 5 ? ParseUtil.double(v[5]) ?? 0 : 0)
            }
        }
        let bars = byIndex.values.sorted { $0.time < $1.time }
        guard !bars.isEmpty else { throw ProviderError.invalidData("TradingView 无K线") }
        return bars
    }

    /// 解析 scanner 行情:昨收 = 现价 - 涨跌额
    static func parseQuote(_ data: Data, symbol: StockSymbol) throws -> Quote {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let price = ParseUtil.double(root["close"]), price > 0,
              let change = ParseUtil.double(root["change_abs"]) else {
            throw ProviderError.invalidData("TradingView 行情结构")
        }
        let prev = price - change
        return Quote(symbol: symbol, name: FuturesCatalog.preset(secid: symbol.code)?.name ?? symbol.displayCode,
                     price: price, prevClose: prev, open: ParseUtil.double(root["open"]) ?? price,
                     high: max(ParseUtil.double(root["high"]) ?? price, price), low: min(ParseUtil.double(root["low"]) ?? price, price),
                     volume: ParseUtil.double(root["volume"]) ?? 0, amount: 0, turnover: nil, bids: [], asks: [],
                     time: Date(), source: .tradingview, openInterest: nil, decimalsHint: 2)
    }

    private static let newYork: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York") ?? .gmt
        return c
    }()

    /// 日/周/月 K:外汇交易日从纽约前一日 17:00 开始,加 8 小时后取纽约日期即为交易日
    static func parseKLine(_ raw: [RawBar], symbol: StockSymbol, period: KLinePeriod) throws -> KLineSeries {
        let bars: [KLineBar] = raw.suffix(KLineConfig.fetchCount).map { r in
            let c = newYork.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: r.time + 8 * 3600))
            let date = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
            return KLineBar(date: date, open: r.open, close: r.close, high: r.high, low: r.low, volume: r.volume, amount: 0)
        }
        return KLineSeries(symbol: symbol, period: period, bars: bars, source: .tradingview, decimals: 2)
    }

    /// 当日分时:从最近一次纽约 17:00(交易日开盘)起 24 小时为横轴,时间按北京时间展示
    static func parseMinute(_ raw: [RawBar], symbol: StockSymbol, prevClose: Double) throws -> MinuteSeries {
        guard let last = raw.last, prevClose > 0 else { throw ProviderError.invalidData("TradingView 分时为空") }
        let lastDate = Date(timeIntervalSince1970: last.time)
        var open = newYork.date(bySettingHour: 17, minute: 0, second: 0, of: lastDate) ?? lastDate
        if open > lastDate { open = newYork.date(byAdding: .day, value: -1, to: open) ?? open }
        let sessionStart = Int(open.timeIntervalSince1970)
        let offset = 8 * 3600
        let startMinute = ((sessionStart + offset) % 86_400 + 86_400) % 86_400 / 60
        let axis = MinuteAxis(segments: [.init(start: startMinute, end: startMinute + 1440)])
        var bars: [MinuteBar] = []
        for r in raw where Int(r.time) >= sessionStart {
            guard let idx = axis.index(forMinute: startMinute + (Int(r.time) - sessionStart) / 60) else { continue }
            if let l = bars.last, l.index == idx { bars.removeLast() }
            bars.append(MinuteBar(index: idx, price: r.close, volume: r.volume, avgPrice: nil))
        }
        guard !bars.isEmpty else { throw ProviderError.invalidData("TradingView 分时为空") }
        let c = newYork.dateComponents([.year, .month, .day], from: open.addingTimeInterval(8 * 3600))
        var series = MinuteSeries(symbol: symbol, prevClose: prevClose,
                                  date: String(format: "%04d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0),
                                  bars: bars, source: .tradingview)
        series.axis = axis
        series.decimalsHint = 2
        return series
    }
}
