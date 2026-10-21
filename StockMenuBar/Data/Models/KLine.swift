//
//  KLine.swift
//  StockMenuBar
//
//  K 线数据模型:周期、单根 K 线、K 线序列与均线计算。
//  @author ixxxxoooo
//

import Foundation

/// K 线参数
enum KLineConfig {
    /// 每次拉取的 K 线根数(多于展示根数,保证均线从首根起就有值)
    static let fetchCount = 250
    /// 图表默认展示的最近根数
    static let visibleCount = 120
}

/// K 线周期
enum KLinePeriod: String, CaseIterable, Identifiable, Sendable {
    case day, week, month

    var id: String { rawValue }

    /// 界面标题
    var title: String {
        switch self {
        case .day: return "日K"
        case .week: return "周K"
        case .month: return "月K"
        }
    }

    /// 东财 klt 参数
    var eastmoneyKlt: Int {
        switch self {
        case .day: return 101
        case .week: return 102
        case .month: return 103
        }
    }

    /// 腾讯 K 线周期参数
    var tencentKey: String { rawValue }
}

/// 单根 K 线
struct KLineBar: Sendable, Equatable, Identifiable {
    /// 交易日(周/月 K 为该周期最后一个交易日),格式 yyyy-MM-dd
    let date: String
    let open: Double
    let close: Double
    let high: Double
    let low: Double
    /// 成交量(手),无数据为 0
    let volume: Double
    /// 成交额(元),无数据为 0
    let amount: Double

    var id: String { date }

    /// 收盘不低于开盘记为上涨
    var isUp: Bool { close >= open }
}

/// K 线序列(按日期升序)
struct KLineSeries: Sendable, Equatable {
    let symbol: StockSymbol
    let period: KLinePeriod
    let bars: [KLineBar]
    let source: ProviderID

    /// 价格小数位(东财随响应给出,其余按品种类别)
    let decimals: Int

    /// 简单移动平均:前 n-1 根返回 nil
    /// - Parameter n: 窗口长度(必须大于 0)
    /// - Returns: 与 bars 等长的均线数组
    func movingAverage(_ n: Int) -> [Double?] {
        guard n > 0 else { return Array(repeating: nil, count: bars.count) }
        var result: [Double?] = []
        var sum = 0.0
        for (i, bar) in bars.enumerated() {
            sum += bar.close
            if i >= n { sum -= bars[i - n].close }
            result.append(i >= n - 1 ? sum / Double(n) : nil)
        }
        return result
    }
}
