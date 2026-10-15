//
//  ChinaTime.swift
//  StockMenuBar
//
//  东八区(Asia/Shanghai)时间工具:A 股所有时间判断与行情时间解析都基于此。
//  @author ixxxxoooo
//

import Foundation

enum ChinaTime {
    /// 东八区时区
    static let timeZone: TimeZone = TimeZone(identifier: "Asia/Shanghai") ?? TimeZone(secondsFromGMT: 8 * 3600)!

    /// 固定使用东八区的公历日历
    static let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        cal.locale = Locale(identifier: "en_US_POSIX")
        return cal
    }()

    /// 由年月日时分秒构造东八区时间
    /// - Returns: 构造失败返回 nil
    static func date(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0, second: Int = 0) -> Date? {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        comps.second = second
        return calendar.date(from: comps)
    }

    /// 解析紧凑时间串,如 `20261015161456`(yyyyMMddHHmmss)或 `202610151614`(yyyyMMddHHmm)
    /// - Parameter text: 紧凑时间字符串
    /// - Returns: 解析成功返回 Date
    static func parse(compact text: String) -> Date? {
        let digits = Array(text.filter { $0.isNumber })
        guard digits.count == 14 || digits.count == 12 || digits.count == 8 else { return nil }
        func num(_ from: Int, _ len: Int) -> Int? { Int(String(digits[from..<(from + len)])) }
        guard let y = num(0, 4), let mo = num(4, 2), let d = num(6, 2) else { return nil }
        let h = digits.count >= 12 ? (num(8, 2) ?? 0) : 0
        let mi = digits.count >= 12 ? (num(10, 2) ?? 0) : 0
        let s = digits.count == 14 ? (num(12, 2) ?? 0) : 0
        return date(year: y, month: mo, day: d, hour: h, minute: mi, second: s)
    }

    /// 解析日期串与时间串,如 `2026-10-15` + `15:34:59`
    static func parse(day: String, time: String) -> Date? {
        parse(compact: day.filter { $0.isNumber } + time.filter { $0.isNumber })
    }

    /// 返回 `yyyy-MM-dd` 形式的东八区日期串
    static func dayString(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// 当天已过去的分钟数(0...1439)
    static func minuteOfDay(_ date: Date) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// 是否周末
    static func isWeekend(_ date: Date) -> Bool {
        let w = calendar.component(.weekday, from: date)
        return w == 1 || w == 7
    }

    /// 某天(东八区)零点后第 minutes 分钟对应的时间
    static func date(onDayOf date: Date, minutes: Int, addingDays days: Int = 0) -> Date {
        let start = calendar.startOfDay(for: date)
        let day = calendar.date(byAdding: .day, value: days, to: start) ?? start
        return calendar.date(byAdding: .minute, value: minutes, to: day) ?? day
    }

    /// 两个时间是否为东八区同一天
    static func isSameDay(_ a: Date, _ b: Date) -> Bool {
        calendar.isDate(a, inSameDayAs: b)
    }
}
