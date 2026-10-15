//
//  TradingClock.swift
//  StockMenuBar
//
//  A 股交易时段判定:交易中(9:15-11:30、13:00-15:05)、午休(11:30-13:00)、休市。
//  @author ixxxxoooo
//

import Foundation

/// 市场阶段
enum MarketPhase: Sendable, Equatable {
    case trading
    case lunch
    case closed
}

struct TradingClock: Sendable {
    /// 开盘(含集合竞价)9:15
    static let openMinute = 9 * 60 + 15
    /// 上午收盘 11:30
    static let morningCloseMinute = 11 * 60 + 30
    /// 下午开盘 13:00
    static let afternoonOpenMinute = 13 * 60
    /// 收盘后缓冲 15:05
    static let closeMinute = 15 * 60 + 5

    /// 内置休市日参考(yyyy-MM-dd)。仅收录确定的日期;
    /// 即便缺失也有「行情时间戳非当日 → 自动判休市」的数据兜底,见 QuoteStore。
    static let builtinHolidays: Set<String> = [
        "2026-01-01", "2026-01-02", "2026-10-01", "2026-10-02"
    ]

    let holidays: Set<String>

    init(holidays: Set<String> = TradingClock.builtinHolidays) {
        self.holidays = holidays
    }

    /// 是否为交易日(非周末且不在休市日表)
    func isTradingDay(_ date: Date) -> Bool {
        if ChinaTime.isWeekend(date) { return false }
        return !holidays.contains(ChinaTime.dayString(date))
    }

    /// 给定时刻所处的市场阶段
    func phase(at date: Date) -> MarketPhase {
        guard isTradingDay(date) else { return .closed }
        let m = ChinaTime.minuteOfDay(date)
        if m >= Self.openMinute && m < Self.morningCloseMinute { return .trading }
        if m >= Self.morningCloseMinute && m < Self.afternoonOpenMinute { return .lunch }
        if m >= Self.afternoonOpenMinute && m < Self.closeMinute { return .trading }
        return .closed
    }

    /// 下一次开盘(9:15)的时间:若当天为交易日且尚未开盘则为当天,否则顺延至下一交易日
    func nextOpen(after date: Date) -> Date {
        for offset in 0..<20 {
            let candidate = ChinaTime.date(onDayOf: date, minutes: Self.openMinute, addingDays: offset)
            if candidate > date && isTradingDay(candidate) { return candidate }
        }
        return ChinaTime.date(onDayOf: date, minutes: Self.openMinute, addingDays: 1)
    }

    /// 距离下一个阶段边界的秒数(交易日内为下一个关键时点,否则为下次开盘)
    func secondsToNextBoundary(from date: Date) -> TimeInterval {
        if isTradingDay(date) {
            let m = ChinaTime.minuteOfDay(date)
            for boundary in [Self.openMinute, Self.morningCloseMinute, Self.afternoonOpenMinute, Self.closeMinute] where boundary > m {
                return ChinaTime.date(onDayOf: date, minutes: boundary).timeIntervalSince(date)
            }
        }
        return nextOpen(after: date).timeIntervalSince(date)
    }

    /// 期货(含外盘)是否可能处于交易中。
    /// 国内期货日盘 9:00-15:00、夜盘 21:00-次日 2:30,外盘(COMEX/LME/NYMEX)近 24 小时交易,
    /// 因此以「周一 06:00 至周六 05:00(上海时间)」作为可能开市的宽窗口,周日全天休市。
    /// 窗口内是否真有成交由行情自身决定,调度只负责不在周末空转。
    func futuresMayBeOpen(at date: Date) -> Bool {
        let weekday = ChinaTime.calendar.component(.weekday, from: date) // 1=周日 ... 7=周六
        let m = ChinaTime.minuteOfDay(date)
        switch weekday {
        case 1: return false
        case 2: return m >= 6 * 60
        case 7: return m < 5 * 60
        default: return true
        }
    }
}
