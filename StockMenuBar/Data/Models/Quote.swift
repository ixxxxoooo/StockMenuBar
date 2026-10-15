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
    /// 持仓量(手),仅期货有值
    var openInterest: Double? = nil
    /// 价格小数位数(期货按品种报价精度,数据源提供或推断);为空时按证券类别取默认值
    var decimalsHint: Int? = nil

    var id: String { symbol.full }

    /// 涨跌额
    var change: Double { price - prevClose }

    /// 涨跌幅(%),由现价与昨收自行计算,避免依赖数据源口径
    var changePercent: Double {
        prevClose > 0 ? (price - prevClose) / prevClose * 100 : 0
    }

    /// 涨跌方向(按 0.5 个最小价位容差判断平盘)
    var trend: Trend {
        let epsilon = pow(10, -Double(decimals)) / 2
        if change > epsilon { return .up }
        if change < -epsilon { return .down }
        return .flat
    }

    /// 价格小数位数
    var decimals: Int { decimalsHint ?? symbol.kind.decimals }

    /// 数据是否可用:昨收必须大于 0、价格不能为负
    var isValid: Bool {
        prevClose > 0 && price >= 0 && price.isFinite && prevClose.isFinite
    }
}

/// 分时单点(按分钟)
struct MinuteBar: Sendable, Equatable, Identifiable {
    /// 交易分钟序号(沿 `MinuteAxis` 累计):A 股 9:30 为 0,11:30 为 120,15:00 为 240
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

/// 分时横轴:由若干连续交易时段首尾相接而成,序号即累计交易分钟数。
/// A 股为 9:30-11:30 + 13:00-15:00 共 240 分钟;期货含夜盘,时段由交易所/品种决定。
struct MinuteAxis: Sendable, Equatable {
    /// 单个交易时段;分钟数自「时间轴零点」起算,夜盘跨零点时可超过 1440
    struct Segment: Sendable, Equatable {
        let start: Int
        let end: Int
        var length: Int { end - start }
    }

    let segments: [Segment]

    /// A 股标准时间轴
    static let ashare = MinuteAxis(segments: [Segment(start: 570, end: 690), Segment(start: 780, end: 900)])

    /// 总交易分钟数(图表横轴上限)
    var total: Int { max(segments.reduce(0) { $0 + $1.length }, 1) }

    /// 把时间轴上的绝对分钟映射为序号;不在任何交易时段内返回 nil(终点含在内)
    /// - Parameter minute: 自时间轴零点起的分钟数
    func index(forMinute minute: Int) -> Int? {
        var offset = 0
        for seg in segments {
            if minute >= seg.start && minute <= seg.end { return offset + (minute - seg.start) }
            offset += seg.length
        }
        return nil
    }

    /// 序号对应的时间文本(HH:mm)
    func label(index: Int) -> String {
        var offset = 0
        for seg in segments {
            if index <= offset + seg.length { return Self.clock(seg.start + max(index - offset, 0)) }
            offset += seg.length
        }
        return Self.clock(segments.last?.end ?? 0)
    }

    /// 各交易时段文本,如 `21:00 - 01:00`
    var sessionTexts: [String] {
        segments.map { "\(Self.clock($0.start)) - \(Self.clock($0.end))" }
    }

    /// 横轴刻度序号:各时段边界,长时段内部每 6 小时补一个;过密的刻度会被剔除
    var tickIndices: [Int] {
        if self == .ashare { return [0, 60, 120, 180, 240] }
        var ticks: [Int] = []
        var offset = 0
        for seg in segments {
            ticks.append(offset)
            if seg.length > 420 {
                var inner = offset + 360
                while inner < offset + seg.length - 120 { ticks.append(inner); inner += 360 }
            }
            offset += seg.length
            ticks.append(offset)
        }
        var result: [Int] = []
        let minGap = Double(total) * 0.17
        for t in Set(ticks).sorted() {
            if let last = result.last, Double(t - last) < minGap {
                // 保留末尾刻度,优先剔除前一个
                if t == total { result.removeLast() } else { continue }
            }
            result.append(t)
        }
        return result
    }

    /// 刻度文本:时段交界处同时给出收盘与开盘时间,如 `11:30/13:00`
    func tickLabel(index: Int) -> String {
        var times: [String] = []
        var offset = 0
        for seg in segments {
            if offset + seg.length == index { times.append(Self.clock(seg.end)) }
            if offset == index { times.append(Self.clock(seg.start)) }
            offset += seg.length
        }
        var unique: [String] = []
        for t in times where !unique.contains(t) { unique.append(t) }
        return unique.isEmpty ? label(index: index) : unique.joined(separator: "/")
    }

    private static func clock(_ minute: Int) -> String {
        let m = ((minute % 1440) + 1440) % 1440
        return String(format: "%02d:%02d", m / 60, m % 60)
    }
}

/// 当日分时序列
struct MinuteSeries: Sendable, Equatable {
    let symbol: StockSymbol
    /// 昨收(期货为昨结算),分时图中轴与涨跌基准
    var prevClose: Double
    /// 交易日,格式 yyyyMMdd(可能为空)
    let date: String?
    let bars: [MinuteBar]
    let source: ProviderID
    /// 横轴(默认 A 股)
    var axis: MinuteAxis = .ashare
    /// 价格小数位数(期货按品种精度),为空按证券类别默认
    var decimalsHint: Int? = nil

    /// 展示用小数位数
    var decimals: Int { decimalsHint ?? symbol.kind.decimals }

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
