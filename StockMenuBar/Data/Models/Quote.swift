//
//  Quote.swift
//  StockMenuBar
//
//  实时行情、盘口、分时数据模型。
//  @author ixxxxoooo
//

import Foundation

/// 涨跌方向
enum Trend: Sendable {
    case up, down, flat
}

/// 盘口档位(价格 + 挂单量,单位:手)
struct PriceLevel: Sendable, Equatable {
    let price: Double
    let volume: Double
}

/// 实时行情快照
struct Quote: Sendable, Equatable, Identifiable {
    let symbol: StockSymbol
    var name: String
    var price: Double
    var prevClose: Double
    var open: Double
    var high: Double
    var low: Double
    /// 成交量(手)
    var volume: Double
    /// 成交额(元)
    var amount: Double
    /// 换手率(%)
    var turnover: Double?
    /// 买一至买五
    var bids: [PriceLevel]
    /// 卖一至卖五
    var asks: [PriceLevel]
    /// 行情时间(数据源提供,可能为空)
    var time: Date?
    /// 数据来源
    var source: ProviderID

    var id: String { symbol.full }

    /// 涨跌额
    var change: Double { price - prevClose }

    /// 涨跌幅(%),由现价与昨收自行计算,避免依赖数据源口径
    var changePercent: Double {
        prevClose > 0 ? (price - prevClose) / prevClose * 100 : 0
    }

    /// 涨跌方向(按 0.5 个最小价位容差判断平盘)
    var trend: Trend {
        let epsilon = pow(10, -Double(symbol.kind.decimals)) / 2
        if change > epsilon { return .up }
        if change < -epsilon { return .down }
        return .flat
    }

    /// 价格小数位数
    var decimals: Int { symbol.kind.decimals }

    /// 数据是否可用:昨收必须大于 0、价格不能为负
    var isValid: Bool {
        prevClose > 0 && price >= 0 && price.isFinite && prevClose.isFinite
    }
}

/// 分时单点(按分钟)
struct MinuteBar: Sendable, Equatable, Identifiable {
    /// 交易分钟序号:9:30 为 0,11:30 为 120,15:00 为 240
    let index: Int
    let price: Double
    /// 该分钟成交量(手)
    let volume: Double
    /// 均价,指数无均价
    let avgPrice: Double?

    var id: Int { index }

    /// 将 HHMM(如 931、1301)映射为分时序号
    /// - Returns: 盘前、午休时间返回 nil
    static func index(hour: Int, minute: Int) -> Int? {
        let t = hour * 60 + minute
        if t < 570 { return nil }
        if t <= 690 { return t - 570 }
        if t < 780 { return nil }
        return min(t - 780 + 120, 240)
    }
}

/// 当日分时序列
struct MinuteSeries: Sendable, Equatable {
    let symbol: StockSymbol
    let prevClose: Double
    /// 交易日,格式 yyyyMMdd(可能为空)
    let date: String?
    let bars: [MinuteBar]
    let source: ProviderID

    /// 最新价
    var lastPrice: Double? { bars.last?.price }
}

/// 搜索联想结果
struct SearchResult: Sendable, Equatable, Identifiable {
    let symbol: StockSymbol
    let name: String
    let pinyin: String

    var id: String { symbol.full }
    var kind: SecurityKind { symbol.kind }
}
