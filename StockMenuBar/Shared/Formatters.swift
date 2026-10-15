//
//  Formatters.swift
//  StockMenuBar
//
//  数字与文本格式化工具:价格、涨跌幅、成交量、成交额、时间。
//  @author ixxxxoooo
//

import Foundation

enum Fmt {
    /// 价格格式化,按小数位数补零
    /// - Parameters:
    ///   - value: 价格
    ///   - decimals: 小数位数(股票 2 位,ETF 3 位)
    static func price(_ value: Double, decimals: Int = 2) -> String {
        String(format: "%.\(decimals)f", value)
    }

    /// 涨跌幅百分比,带正负号,如 `+1.25%`;接近 0 时显示 `0.00%`
    static func percent(_ value: Double) -> String {
        if abs(value) < 0.005 { return "0.00%" }
        return String(format: "%+.2f%%", value)
    }

    /// 无符号百分比,如换手率 `0.46%`
    static func plainPercent(_ value: Double) -> String {
        String(format: "%.2f%%", value)
    }

    /// 涨跌额,带正负号
    static func signed(_ value: Double, decimals: Int = 2) -> String {
        if abs(value) < pow(10, -Double(decimals)) / 2 { return String(format: "%.\(decimals)f", 0.0) }
        return String(format: "%+.\(decimals)f", value)
    }

    /// 成交量格式化(输入单位:手)
    static func volume(_ lots: Double) -> String {
        if lots >= 100_000_000 { return String(format: "%.2f亿手", lots / 100_000_000) }
        if lots >= 10_000 { return String(format: "%.2f万手", lots / 10_000) }
        return String(format: "%.0f手", lots)
    }

    /// 盘口挂单量格式化(输入单位:手),保持紧凑
    static func depthVolume(_ lots: Double) -> String {
        if lots >= 100_000 { return String(format: "%.1f万", lots / 10_000) }
        return String(format: "%.0f", lots)
    }

    /// 成交额格式化(输入单位:元)
    static func amount(_ yuan: Double) -> String {
        if yuan >= 100_000_000 { return String(format: "%.2f亿", yuan / 100_000_000) }
        if yuan >= 10_000 { return String(format: "%.2f万", yuan / 10_000) }
        return String(format: "%.0f", yuan)
    }

    /// 时分秒文本,东八区
    static func clock(_ date: Date) -> String {
        let c = ChinaTime.calendar.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    /// 时分文本,东八区
    static func hourMinute(_ date: Date) -> String {
        let c = ChinaTime.calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// 分时序号(0...240)对应的时间文本
    static func minuteLabel(index: Int) -> String {
        let total = index <= 120 ? 570 + index : 780 + (index - 120)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
