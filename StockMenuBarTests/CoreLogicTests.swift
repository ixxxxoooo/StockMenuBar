//
//  CoreLogicTests.swift
//  StockMenuBarTests
//
//  交易时钟、调度决策、熔断器、市场识别、拼音与格式化测试。
//  @author ixxxxoooo
//

import Foundation
import Testing

/// 东八区时间构造
private func cn(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int = 0) -> Date {
    ChinaTime.date(year: y, month: mo, day: d, hour: h, minute: mi, second: s)!
}

struct TradingClockTests {
    let clock = TradingClock()

    @Test func 交易日各时段边界() {
        // 2026-10-16 为周五
        #expect(clock.phase(at: cn(2026, 10, 16, 9, 14, 59)) == .closed)
        #expect(clock.phase(at: cn(2026, 10, 16, 9, 15)) == .trading)
        #expect(clock.phase(at: cn(2026, 10, 16, 11, 29, 59)) == .trading)
        #expect(clock.phase(at: cn(2026, 10, 16, 11, 30)) == .lunch)
        #expect(clock.phase(at: cn(2026, 10, 16, 12, 59, 59)) == .lunch)
        #expect(clock.phase(at: cn(2026, 10, 16, 13, 0)) == .trading)
        #expect(clock.phase(at: cn(2026, 10, 16, 15, 4, 59)) == .trading)
        #expect(clock.phase(at: cn(2026, 10, 16, 15, 5)) == .closed)
        #expect(clock.phase(at: cn(2026, 10, 16, 23, 59)) == .closed)
    }

    @Test func 周末与休市日全天休市() {
        #expect(clock.phase(at: cn(2026, 10, 17, 10, 0)) == .closed) // 周六
        #expect(clock.phase(at: cn(2026, 10, 18, 10, 0)) == .closed) // 周日
        #expect(clock.phase(at: cn(2026, 10, 1, 10, 0)) == .closed)  // 国庆
    }

    @Test func 下次开盘顺延到下一交易日() {
        // 周五盘后 → 周一 9:15
        #expect(clock.nextOpen(after: cn(2026, 10, 16, 16, 0)) == cn(2026, 10, 19, 9, 15))
        // 周五盘前 → 当天 9:15
        #expect(clock.nextOpen(after: cn(2026, 10, 16, 0, 44)) == cn(2026, 10, 16, 9, 15))
        // 节前最后一个交易日(2026-09-30 周三)盘后 → 跳过国庆休市(1、2 日)与周末,至 10-05 周一
        #expect(clock.nextOpen(after: cn(2026, 9, 30, 16, 0)) == cn(2026, 10, 5, 9, 15))
    }

    @Test func 到下一边界的秒数() {
        #expect(clock.secondsToNextBoundary(from: cn(2026, 10, 16, 9, 0)) == 15 * 60)
        #expect(clock.secondsToNextBoundary(from: cn(2026, 10, 16, 10, 0)) == 90 * 60)
        #expect(clock.secondsToNextBoundary(from: cn(2026, 10, 16, 12, 0)) == 60 * 60)
    }
}

struct SchedulerDecisionTests {
    let clock = TradingClock()

    private func decide(_ now: Date, suspended: Bool = false, consumers: Bool = true, closedToday: Bool = false,
                        interval: Int = 3, conserving: Bool = false) -> RefreshDecision {
        RefreshScheduler.decide(now: now, clock: clock, suspended: suspended, hasConsumers: consumers,
                                marketClosedToday: closedToday, interval: interval, conserving: conserving)
    }

    @Test func 交易时间按用户间隔轮询() {
        #expect(decide(cn(2026, 10, 16, 10, 0), interval: 3) == .poll(3))
        #expect(decide(cn(2026, 10, 16, 14, 0), interval: 10) == .poll(10))
    }

    @Test func 低电量间隔翻倍() {
        #expect(decide(cn(2026, 10, 16, 10, 0), interval: 5, conserving: true) == .poll(10))
    }

    @Test func 午休降频至一分钟() {
        #expect(decide(cn(2026, 10, 16, 12, 0)) == .poll(60))
    }

    @Test func 盘后夜间不轮询() {
        if case .poll = decide(cn(2026, 10, 16, 20, 0)) { Issue.record("盘后不应轮询") }
        if case .poll = decide(cn(2026, 10, 17, 10, 0)) { Issue.record("周末不应轮询") }
    }

    @Test func 盘后空闲时长不超过半小时() {
        guard case .idle(let s) = decide(cn(2026, 10, 16, 20, 0)) else {
            Issue.record("应为 idle")
            return
        }
        #expect(s <= 1800 && s >= 1)
    }

    @Test func 休眠或无界面时暂停() {
        #expect(decide(cn(2026, 10, 16, 10, 0), suspended: true) == .idle(600))
        #expect(decide(cn(2026, 10, 16, 10, 0), consumers: false) == .idle(600))
    }

    @Test func 数据兜底判定休市后低频探测() {
        #expect(decide(cn(2026, 10, 16, 10, 0), closedToday: true) == .poll(300))
    }
}

struct CircuitBreakerTests {
    @Test func 连续失败达到阈值后熔断() {
        let now = Date()
        var b = CircuitBreaker(failureThreshold: 3, openDuration: 30)
        b.recordFailure(now: now)
        b.recordFailure(now: now)
        #expect(b.isAvailable(now: now))
        b.recordFailure(now: now)
        #expect(!b.isAvailable(now: now))
        #expect(!b.isAvailable(now: now.addingTimeInterval(29)))
    }

    @Test func 到期半开仅放行一个探测() {
        let now = Date()
        var b = CircuitBreaker(failureThreshold: 1, openDuration: 30)
        b.recordFailure(now: now)
        let later = now.addingTimeInterval(31)
        #expect(b.isAvailable(now: later))
        b.beginAttempt(now: later)
        #expect(b.state == .halfOpen)
        #expect(!b.isAvailable(now: later))
    }

    @Test func 半开成功恢复_失败重新熔断() {
        let now = Date()
        var b = CircuitBreaker(failureThreshold: 1, openDuration: 30)
        b.recordFailure(now: now)
        b.beginAttempt(now: now.addingTimeInterval(31))
        b.recordSuccess()
        #expect(b.state == .closed)

        var c = CircuitBreaker(failureThreshold: 1, openDuration: 30)
        c.recordFailure(now: now)
        c.beginAttempt(now: now.addingTimeInterval(31))
        c.recordFailure(now: now.addingTimeInterval(31))
        #expect(!c.isAvailable(now: now.addingTimeInterval(32)))
    }

    @Test func 成功清零失败计数() {
        let now = Date()
        var b = CircuitBreaker(failureThreshold: 3, openDuration: 30)
        b.recordFailure(now: now)
        b.recordFailure(now: now)
        b.recordSuccess()
        b.recordFailure(now: now)
        #expect(b.isAvailable(now: now))
    }
}

struct MarketRecognitionTests {
    @Test func 六位代码识别市场() {
        #expect(StockSymbol.resolve(code: "600519")?.full == "sh600519")
        #expect(StockSymbol.resolve(code: "688981")?.full == "sh688981")
        #expect(StockSymbol.resolve(code: "000001")?.full == "sz000001")
        #expect(StockSymbol.resolve(code: "300750")?.full == "sz300750")
        #expect(StockSymbol.resolve(code: "159915")?.full == "sz159915")
        #expect(StockSymbol.resolve(code: "510300")?.full == "sh510300")
        #expect(StockSymbol.resolve(code: "830799")?.full == "bj830799")
        #expect(StockSymbol.resolve(code: "430047")?.full == "bj430047")
        #expect(StockSymbol.resolve(code: "920001")?.full == "bj920001")
        #expect(StockSymbol.resolve(code: "12345") == nil)
        #expect(StockSymbol.resolve(code: "abcdef") == nil)
    }

    @Test func 板块识别() {
        #expect(StockSymbol(full: "sh600519")?.kind == .main)
        #expect(StockSymbol(full: "sh688981")?.kind == .star)
        #expect(StockSymbol(full: "sz300750")?.kind == .gem)
        #expect(StockSymbol(full: "sz301000")?.kind == .gem)
        #expect(StockSymbol(full: "bj830799")?.kind == .beijing)
        #expect(StockSymbol(full: "sh510300")?.kind == .etf)
        #expect(StockSymbol(full: "sz159915")?.kind == .etf)
        #expect(StockSymbol(full: "sh000001")?.kind == .index)
        #expect(StockSymbol(full: "sz399006")?.kind == .index)
        #expect(StockSymbol(full: "sz000001")?.kind == .main)
    }

    @Test func 完整代码解析() {
        #expect(StockSymbol(full: "SH600519")?.full == "sh600519")
        #expect(StockSymbol(full: "xx600519") == nil)
        #expect(StockSymbol(full: "sh6005") == nil)
        #expect(StockSymbol(full: "sh60051a") == nil)
    }

    @Test func 东财secid() {
        #expect(StockSymbol(full: "sh600519")?.eastmoneySecid == "1.600519")
        #expect(StockSymbol(full: "sz000001")?.eastmoneySecid == "0.000001")
        #expect(StockSymbol(full: "bj830799")?.eastmoneySecid == "0.830799")
    }
}

struct UtilityTests {
    @Test func 拼音首字母() {
        #expect(Pinyin.initials("贵州茅台") == "GZMT")
        #expect(Pinyin.initials("平安银行") == "PAYH")
        #expect(Pinyin.initials("*ST工智") == "STGZ")
        #expect(Pinyin.initials("沪深300ETF") == "HS300ETF")
    }

    @Test func 本地匹配支持拼音代码与名称() {
        #expect(Pinyin.matches(keyword: "gzmt", name: "贵州茅台", code: "600519"))
        #expect(Pinyin.matches(keyword: "茅台", name: "贵州茅台", code: "600519"))
        #expect(Pinyin.matches(keyword: "6005", name: "贵州茅台", code: "600519"))
        #expect(!Pinyin.matches(keyword: "xyz", name: "贵州茅台", code: "600519"))
        #expect(Pinyin.matches(keyword: "", name: "贵州茅台", code: "600519"))
    }

    @Test func 格式化() {
        #expect(Fmt.percent(1.2543) == "+1.25%")
        #expect(Fmt.percent(-0.5) == "-0.50%")
        #expect(Fmt.percent(0.001) == "0.00%")
        #expect(Fmt.volume(57677) == "5.77万手")
        #expect(Fmt.volume(9876) == "9876手")
        #expect(Fmt.amount(7_537_706_224) == "75.38亿")
        #expect(Fmt.amount(123_400) == "12.34万")
        #expect(Fmt.minuteLabel(index: 0) == "09:30")
        #expect(Fmt.minuteLabel(index: 120) == "11:30")
        #expect(Fmt.minuteLabel(index: 240) == "15:00")
    }

    @Test func 紧凑时间解析() {
        let d = ChinaTime.parse(compact: "20261015161456")
        #expect(d == cn(2026, 10, 15, 16, 14, 56))
        #expect(ChinaTime.parse(day: "2026-10-15", time: "15:34:59") == cn(2026, 10, 15, 15, 34, 59))
        #expect(ChinaTime.parse(compact: "bad") == nil)
    }

    @Test func 涨跌方向以最小价位为容差() {
        let up = makeQuote("sh600519", price: 10.01, prev: 10.00)
        let flat = makeQuote("sh600519", price: 10.00, prev: 10.00)
        let down = makeQuote("sh600519", price: 9.99, prev: 10.00)
        #expect(up.trend == .up && flat.trend == .flat && down.trend == .down)
        #expect(!makeQuote("sh600519", price: 10, prev: 0).isValid)
    }
}
