//
//  KLineParsers.swift
//  StockMenuBar
//
//  新浪、雅虎的 K 线解析,以及日线聚合为周/月线(新浪期货与美股指数只有日线)。
//  @author ixxxxoooo
//

import Foundation

/// 日线聚合为周/月线
enum KLineAggregator {
    private static let iso: Calendar = {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = .gmt
        return c
    }()

    /// 周期分组键:同键的相邻日线合并为一根
    private static func key(_ date: String, period: KLinePeriod) -> String {
        switch period {
        case .day: return date
        case .month: return String(date.prefix(7))
        case .week:
            let p = date.split(separator: "-").compactMap { Int($0) }
            guard p.count == 3, let d = iso.date(from: DateComponents(year: p[0], month: p[1], day: p[2])) else { return date }
            let c = iso.dateComponents([.yearForWeekOfYear, .weekOfYear], from: d)
            return "\(c.yearForWeekOfYear ?? 0)-W\(c.weekOfYear ?? 0)"
        }
    }

    /// 聚合:开盘取首日,收盘与日期取末日,最高/最低取极值,量额求和
    /// - Parameters:
    ///   - bars: 升序日线
    ///   - period: 目标周期
    static func aggregate(_ bars: [KLineBar], period: KLinePeriod) -> [KLineBar] {
        guard period != .day else { return bars }
        var result: [KLineBar] = []
        var lastKey = ""
        for bar in bars {
            let k = key(bar.date, period: period)
            if k == lastKey, let last = result.popLast() {
                result.append(KLineBar(date: bar.date, open: last.open, close: bar.close,
                                       high: max(last.high, bar.high), low: min(last.low, bar.low),
                                       volume: last.volume + bar.volume, amount: last.amount + bar.amount))
            } else {
                result.append(bar)
            }
            lastKey = k
        }
        return result
    }
}

/// 新浪 K 线解析
enum SinaKLineParser {
    /// 新浪 K 线接口类型
    enum Layout { case aShare, domesticFutures, globalFutures, usIndex }

    /// 解析新浪 K 线(JSONP 或纯 JSON 数组)
    /// - Parameters:
    ///   - data: 响应
    ///   - symbol: 证券
    ///   - period: 周期;期货与美股指数只有日线,会在此聚合
    ///   - layout: 接口类型(字段名不同)
    ///   - scale: 价格换算系数(如 COMEX 铜新浪为美分)
    static func parse(_ data: Data, symbol: StockSymbol, period: KLinePeriod, layout: Layout, scale: Double = 1) throws -> KLineSeries {
        let text = String(decoding: data, as: UTF8.self)
        guard let l = text.firstIndex(of: "["), let r = text.lastIndex(of: "]"), l < r,
              let rows = try? JSONSerialization.jsonObject(with: Data(text[l...r].utf8)) as? [[String: Any]] else {
            throw ProviderError.invalidData("新浪K线结构")
        }
        // A 股成交量单位为股,换算为手;指数/期货按各自口径(指数量能无参考价值记 0)
        let isIndex = symbol.kind == .index
        func num(_ row: [String: Any], _ keys: [String]) -> Double? {
            for k in keys { if let v = ParseUtil.double(row[k]) { return v } }
            return nil
        }
        var daily: [KLineBar] = rows.compactMap { row in
            guard let date = (row["day"] ?? row["d"] ?? row["date"]) as? String,
                  let o = num(row, ["open", "o"]), let h = num(row, ["high", "h"]),
                  let lo = num(row, ["low", "l"]), let c = num(row, ["close", "c"]), c > 0, h >= lo else { return nil }
            var volume = num(row, ["volume", "v"]) ?? 0
            if layout == .aShare { volume = isIndex ? 0 : volume / 100 }
            if layout == .usIndex { volume = 0 }
            return KLineBar(date: String(date.prefix(10)), open: o * scale, close: c * scale, high: h * scale, low: lo * scale,
                            volume: volume, amount: 0)
        }
        guard !daily.isEmpty else { throw ProviderError.invalidData("新浪K线为空") }
        if layout != .aShare { daily = KLineAggregator.aggregate(daily, period: period) }
        let bars = Array(daily.suffix(KLineConfig.fetchCount))
        let decimals = layout == .aShare ? symbol.kind.decimals : (layout == .usIndex ? 2 : SinaParser.inferDecimals(bars[bars.count - 1].close))
        return KLineSeries(symbol: symbol, period: period, bars: bars, source: .sina, decimals: decimals)
    }
}

extension YahooParser {
    /// 解析雅虎 K 线(interval=1d/1wk/1mo);空值(停盘日)跳过
    static func parseKLine(_ data: Data, symbol: StockSymbol, period: KLinePeriod) throws -> KLineSeries {
        let chart = try parseChart(data)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        var bars: [KLineBar] = []
        for (i, stamp) in chart.timestamps.enumerated() {
            guard i < chart.closes.count, i < chart.opens.count, i < chart.highs.count, i < chart.lows.count,
                  let c = chart.closes[i], let o = chart.opens[i], let h = chart.highs[i], let l = chart.lows[i], c > 0 else { continue }
            let comp = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: TimeInterval(stamp + chart.gmtOffset)))
            let date = String(format: "%04d-%02d-%02d", comp.year ?? 0, comp.month ?? 0, comp.day ?? 0)
            let volume = i < chart.volumes.count ? (chart.volumes[i] ?? 0) : 0
            bars.append(KLineBar(date: date, open: o, close: c, high: h, low: l, volume: volume, amount: 0))
        }
        guard !bars.isEmpty else { throw ProviderError.invalidData("雅虎K线为空") }
        let isIndex = symbol.code.hasPrefix("100.")
        return KLineSeries(symbol: symbol, period: period, bars: Array(bars.suffix(KLineConfig.fetchCount)), source: .yahoo,
                           decimals: isIndex ? 2 : SinaParser.inferDecimals(bars[bars.count - 1].close))
    }
}
