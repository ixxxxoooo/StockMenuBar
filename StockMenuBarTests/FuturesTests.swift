//
//  FuturesTests.swift
//  StockMenuBarTests
//
//  期货功能测试:标识解析、分时轴、东财/新浪解析器、目录映射、路由覆盖度与补查、交易窗口与调度。
//  @author ixxxxoooo
//

import Foundation
import Testing

// MARK: - 标识与目录

struct FuturesSymbolTests {
    @Test func 期货标识解析与展示() throws {
        let cu = try #require(StockSymbol(full: "fu113.cum"))
        #expect(cu.market == .future)
        #expect(cu.code == "113.cum")
        #expect(cu.displayCode == "cum")
        #expect(cu.marketTag == "上期所")
        #expect(cu.kind == .future)
        #expect(cu.full == "fu113.cum")
        #expect(cu.eastmoneySecid == "113.cum")
    }

    @Test func 外盘代码保持大小写() throws {
        let hg = try #require(StockSymbol(full: "fu101.HG00Y"))
        #expect(hg.code == "101.HG00Y")
        #expect(hg.marketTag == "COMEX")
        let n225 = try #require(StockSymbol(full: "fu100.N225"))
        #expect(n225.kind == .index)
        #expect(n225.marketTag == "全球指数")
    }

    @Test func 非法期货标识返回空() {
        #expect(StockSymbol(full: "fu") == nil)
        #expect(StockSymbol(full: "fuabc.cum") == nil)
        #expect(StockSymbol(full: "fu113.") == nil)
        // A 股解析不受影响
        #expect(StockSymbol(full: "sh600519")?.market == .sh)
    }

    @Test func 默认期货分组覆盖铜煤东京() {
        let names = FuturesCatalog.defaults.map(\.name)
        #expect(names.contains("沪铜主连") && names.contains("伦铜") && names.contains("COMEX铜"))
        #expect(names.contains("焦煤主连") && names.contains("焦炭主连"))
        #expect(names.contains("日经225"))
        for preset in FuturesCatalog.all { #expect(StockSymbol(full: preset.symbol.full) == preset.symbol) }
    }

    @Test func 新浪代码映射() throws {
        #expect(FuturesCatalog.sinaMapping(secid: "113.cum")?.code == "nf_CU0")
        #expect(FuturesCatalog.sinaMapping(secid: "113.cu2612")?.code == "nf_CU2612")
        #expect(FuturesCatalog.sinaMapping(secid: "115.ZC612")?.code == "nf_ZC2612")
        let hg = try #require(FuturesCatalog.sinaMapping(secid: "101.HG00Y"))
        #expect(hg.code == "hf_HG" && hg.scale == 0.01)
        #expect(FuturesCatalog.sinaMapping(secid: "109.LCPT")?.code == "hf_CAD")
        // 无备源:外盘非预置、中金所
        #expect(FuturesCatalog.sinaMapping(secid: "103.ZS00Y") == nil)
        #expect(FuturesCatalog.sinaMapping(secid: "8.IF2612") == nil)
    }

    @Test func 本地联想命中铜与煤() {
        #expect(FuturesCatalog.localSearch("铜").count >= 3)
        #expect(FuturesCatalog.localSearch("煤").map(\.name).contains("焦煤主连"))
        #expect(FuturesCatalog.localSearch("HTZL").first?.symbol.code == "113.cum")
        #expect(FuturesCatalog.localSearch("").isEmpty)
    }

    @Test func 夜盘模板() {
        #expect(FuturesCatalog.nightEnd(product: "cu", observedNight: true) == 25 * 60)
        #expect(FuturesCatalog.nightEnd(product: "au", observedNight: true) == 26 * 60 + 30)
        #expect(FuturesCatalog.nightEnd(product: "jm", observedNight: true) == 23 * 60)
        #expect(FuturesCatalog.nightEnd(product: "if", observedNight: true) == nil)
        #expect(FuturesCatalog.nightEnd(product: "zz", observedNight: false) == nil)
    }
}

// MARK: - 分时轴

struct MinuteAxisTests {
    @Test func A股轴保持原有刻度() {
        let axis = MinuteAxis.ashare
        #expect(axis.total == 240)
        #expect(axis.tickIndices == [0, 60, 120, 180, 240])
        #expect(axis.tickLabel(index: 0) == "09:30")
        #expect(axis.tickLabel(index: 120) == "11:30/13:00")
        #expect(axis.tickLabel(index: 240) == "15:00")
        #expect(axis.index(forMinute: 9 * 60 + 30) == 0)
        #expect(axis.index(forMinute: 13 * 60) == 120)
        #expect(axis.index(forMinute: 12 * 60) == nil)
    }

    @Test func 国内夜盘轴() {
        // 有色金属:21:00-01:00 夜盘 + 9:00-10:15 + 10:30-11:30 + 13:30-15:00 = 240+75+60+90
        let axis = FuturesCatalog.domesticAxis(nightEnd: 25 * 60)
        #expect(axis.total == 465)
        #expect(axis.index(forMinute: 21 * 60) == 0)
        #expect(axis.index(forMinute: 25 * 60) == 240)
        #expect(axis.index(forMinute: 24 * 60 + 9 * 60) == 240)
        #expect(axis.index(forMinute: 24 * 60 + 15 * 60) == 465)
        #expect(axis.label(index: 0) == "21:00")
        #expect(axis.tickLabel(index: 240) == "01:00/09:00")
        #expect(axis.tickLabel(index: 465) == "15:00")
        #expect(axis.sessionTexts.first == "21:00 - 01:00")
    }

    @Test func 无夜盘轴() {
        let axis = FuturesCatalog.domesticAxis(nightEnd: nil)
        #expect(axis.total == 225)
        #expect(axis.index(forMinute: 9 * 60) == 0)
        #expect(axis.tickLabel(index: 0) == "09:00")
    }

    @Test func 单一长时段补充刻度() {
        // COMEX:06:00-次日 05:00 单一时段 23 小时
        let axis = MinuteAxis(segments: [.init(start: 360, end: 1740)])
        let ticks = axis.tickIndices
        #expect(ticks.first == 0 && ticks.last == axis.total)
        #expect(ticks.count >= 4 && ticks.count <= 7)
    }
}

// MARK: - 东财解析

struct EastmoneyFuturesParserTests {
    @Test func 期货行情解析() throws {
        let data = try Fixture.data("em_futures_quote.json")
        let requested = ["fu113.cum", "fu114.jmm", "fu101.HG00Y", "fu115.ZCM"].compactMap(StockSymbol.init(full:))
        let quotes = try EastmoneyParser.parseQuotes(data, requested: requested)
        #expect(quotes.count == 4)
        let cu = try #require(quotes.first { $0.symbol.code == "113.cum" })
        #expect(cu.price == 108970)
        // 以昨结算价为基准,而不是昨收
        #expect(cu.prevClose == 109750)
        #expect(abs(cu.changePercent - (-0.7107)) < 0.01)
        #expect(cu.openInterest == 185491)
        #expect(cu.decimals == 0)
        let hg = try #require(quotes.first { $0.symbol.code == "101.HG00Y" })
        #expect(hg.decimals == 4)
        #expect(hg.openInterest == nil)
        // 停牌品种:现价取昨结算,仍视为有效
        let zc = try #require(quotes.first { $0.symbol.code == "115.ZCM" })
        #expect(zc.price == 801.4)
    }

    @Test func 夜盘分时跨零点映射() throws {
        let data = try Fixture.data("em_futures_trends.json")
        let symbol = try #require(StockSymbol(full: "fu113.cum"))
        let series = try EastmoneyParser.parseMinute(data, symbol: symbol)
        #expect(series.prevClose == 109750)
        #expect(series.axis.total == 465)
        #expect(series.decimals == 0)
        let indices = series.bars.map(\.index)
        #expect(indices.first == 0)
        #expect(indices.contains(240))     // 01:00 / 09:00 同一交界,后者覆盖前者
        #expect(indices.contains(241))     // 09:01
        #expect(indices.last == 465)       // 15:00
        #expect(indices == indices.sorted())
        #expect(Set(indices).count == indices.count)
        #expect(series.date == "20261015")
    }

    @Test func 期货搜索只保留期货与全球指数() throws {
        let results = try EastmoneyParser.parseFuturesSearch(try Fixture.data("em_futures_search.json"))
        #expect(results.map(\.symbol.full) == ["fu113.cu2612", "fu101.HG00Y", "fu100.N225"])
        #expect(results[0].pinyin == "HT2612")
        // A 股搜索不应返回期货
        let stocks = try EastmoneyParser.parseSearch(try Fixture.data("em_futures_search.json"))
        #expect(stocks.map(\.symbol.full) == ["sh600362"])
    }

    @Test func A股分时轴不受影响() throws {
        let symbol = try #require(StockSymbol(full: "sh600519"))
        let series = try EastmoneyParser.parseMinute(try Fixture.data("em_trends.json"), symbol: symbol)
        #expect(series.axis == .ashare)
        #expect(series.bars.first?.index == 0)
    }
}

// MARK: - 新浪解析

struct SinaFuturesParserTests {
    private func requested() -> [StockSymbol] {
        ["fu113.cum", "fu109.LCPT", "fu101.HG00Y", "fu100.N225", "fu115.ZCM"].compactMap(StockSymbol.init(full:))
    }

    @Test func 国内与外盘行情解析() throws {
        let quotes = SinaParser.parseFuturesQuotes(try Fixture.text("sina_futures_quote.txt"), requested: requested())
        // 动力煤返回空串被忽略
        #expect(quotes.count == 4)
        let cu = try #require(quotes.first { $0.symbol.code == "113.cum" })
        #expect(cu.price == 108970 && cu.prevClose == 109750 && cu.openInterest == 185491)
        #expect(cu.name == "沪铜主连")
        #expect(cu.decimals == 0)
        let lme = try #require(quotes.first { $0.symbol.code == "109.LCPT" })
        #expect(lme.price == 14285.44 && lme.prevClose == 14347)
        #expect(abs(lme.changePercent - (-0.4318)) < 0.01)
    }

    @Test func 美铜价格按系数换算为美元() throws {
        let quotes = SinaParser.parseFuturesQuotes(try Fixture.text("sina_futures_quote.txt"), requested: requested())
        let hg = try #require(quotes.first { $0.symbol.code == "101.HG00Y" })
        #expect(abs(hg.price - 6.54764) < 1e-6)
        #expect(abs(hg.prevClose - 6.6605) < 1e-6)
        #expect(hg.decimals == 3)
    }

    @Test func 日经指数解析() throws {
        let quotes = SinaParser.parseFuturesQuotes(try Fixture.text("sina_futures_quote.txt"), requested: requested())
        let nk = try #require(quotes.first { $0.symbol.code == "100.N225" })
        #expect(nk.price == 64425.73 && nk.prevClose == 67744.29)
        #expect(abs(nk.changePercent - (-4.8985)) < 0.01)
        #expect(nk.high == 66929.30 && nk.low == 64092.74)
    }

    @Test func 国内分时夜盘回绕() throws {
        let data = try Fixture.data("sina_futures_minute.txt")
        let symbol = try #require(StockSymbol(full: "fu113.cum"))
        let series = try SinaParser.parseFuturesMinute(data, symbol: symbol, sinaKey: "CU0")
        #expect(series.axis.total == 465)     // 铜:夜盘到 01:00
        let indices = series.bars.map(\.index)
        #expect(indices.first == 0)
        #expect(indices.contains(179))        // 23:59
        #expect(indices.contains(180))        // 00:00
        #expect(indices.contains(240))        // 01:00 与 09:00 交界
        #expect(indices.last == 465)
        #expect(indices == indices.sorted())
        #expect(series.date == "20261016")
        #expect(series.prevClose == 108940)
    }
}

// MARK: - 路由:覆盖度与补查

/// 按标的过滤的模拟期货源
struct FuturesMockProvider: QuoteProvider {
    let id: ProviderID
    let serves: Set<String>
    let log: CallLog
    var capabilities: Set<ProviderCapability> { [.quotes, .futuresQuotes, .futuresMinute] }

    func canServe(_ capability: ProviderCapability, symbol: StockSymbol?) -> Bool {
        guard capabilities.contains(capability) else { return false }
        guard let symbol, symbol.isFuture else { return true }
        return serves.contains(symbol.code)
    }

    func fetchQuotes(_ symbols: [StockSymbol]) async throws -> [Quote] {
        await log.add(id)
        return symbols.filter { serves.contains($0.code) }.map {
            Quote(symbol: $0, name: $0.code, price: 10, prevClose: 9, open: 9, high: 10, low: 9, volume: 1, amount: 1,
                  turnover: nil, bids: [], asks: [], time: nil, source: id)
        }
    }
}

struct FuturesRouterTests {
    @Test func 覆盖全部标的的数据源优先() async throws {
        let log = CallLog()
        // 东财覆盖两只;新浪只覆盖一只但延迟先验更低 → 仍应先走覆盖全的东财
        let em = FuturesMockProvider(id: .eastmoney, serves: ["113.cum", "100.N225"], log: log)
        let sina = FuturesMockProvider(id: .sina, serves: ["113.cum"], log: log)
        let router = ProviderRouter(providers: [sina, em])
        let symbols = ["fu113.cum", "fu100.N225"].compactMap(StockSymbol.init(full:))
        let result = try await router.quotes(for: symbols)
        #expect(result.provider == .eastmoney)
        #expect(result.value.count == 2)
        #expect(await log.count(of: .sina) == 0)
    }

    @Test func 首选源缺失的品种由其余源补查() async throws {
        let log = CallLog()
        // 东财覆盖全部但实际只返回部分(模拟某品种无数据);新浪能补上缺失品种
        struct PartialProvider: QuoteProvider {
            let id: ProviderID = .eastmoney
            let log: CallLog
            var capabilities: Set<ProviderCapability> { [.futuresQuotes] }
            func fetchQuotes(_ symbols: [StockSymbol]) async throws -> [Quote] {
                await log.add(id)
                return symbols.prefix(1).map {
                    Quote(symbol: $0, name: "a", price: 10, prevClose: 9, open: 9, high: 10, low: 9, volume: 1, amount: 1,
                          turnover: nil, bids: [], asks: [], time: nil, source: .eastmoney)
                }
            }
        }
        let sina = FuturesMockProvider(id: .sina, serves: ["113.cum", "114.jmm"], log: log)
        let router = ProviderRouter(providers: [PartialProvider(log: log), sina])
        let symbols = ["fu113.cum", "fu114.jmm"].compactMap(StockSymbol.init(full:))
        let result = try await router.quotes(for: symbols)
        #expect(Set(result.value.map(\.symbol.code)) == ["113.cum", "114.jmm"])
        #expect(await log.count(of: .sina) == 1)
    }

    @Test func A股与期货混合请求分别路由() async throws {
        let log = CallLog()
        let stockSource = MockProvider(id: .tencent, log: log) { [makeQuote("sh600519")] }
        let futSource = FuturesMockProvider(id: .eastmoney, serves: ["113.cum"], log: log)
        let router = ProviderRouter(providers: [stockSource, futSource])
        let symbols = ["sh600519", "fu113.cum"].compactMap(StockSymbol.init(full:))
        let result = try await router.quotes(for: symbols)
        #expect(Set(result.value.map(\.symbol.full)) == ["sh600519", "fu113.cum"])
        // 腾讯不具备期货能力,不应被请求期货
        #expect(await log.count(of: .tencent) == 1)
    }

    @Test func 期货失败不影响A股() async throws {
        let log = CallLog()
        let stockSource = MockProvider(id: .tencent, log: log) { [makeQuote("sh600519")] }
        let router = ProviderRouter(providers: [stockSource])   // 没有任何期货源
        let symbols = ["sh600519", "fu113.cum"].compactMap(StockSymbol.init(full:))
        let result = try await router.quotes(for: symbols)
        #expect(result.value.map(\.symbol.full) == ["sh600519"])
    }

    @Test func 覆盖度计算() {
        let log = CallLog()
        let p = FuturesMockProvider(id: .sina, serves: ["113.cum"], log: log)
        let a = StockSymbol(full: "fu113.cum")!, b = StockSymbol(full: "fu100.N225")!
        #expect(ProviderRouter.coverage(of: p, capability: .futuresQuotes, symbols: [a]) == .full)
        #expect(ProviderRouter.coverage(of: p, capability: .futuresQuotes, symbols: [a, b]) == .partial)
        #expect(ProviderRouter.coverage(of: p, capability: .futuresQuotes, symbols: [b]) == .none)
        #expect(ProviderRouter.coverage(of: p, capability: .search, symbols: []) == .none)
    }
}

// MARK: - 交易窗口与调度

struct FuturesScheduleTests {
    private func date(_ day: Int, _ h: Int, _ m: Int) -> Date {
        // 2026-10-12 为周一
        ChinaTime.date(year: 2026, month: 10, day: day, hour: h, minute: m)!
    }

    @Test func 期货开市窗口() {
        let clock = TradingClock()
        #expect(clock.futuresMayBeOpen(at: date(12, 5, 0)) == false)    // 周一凌晨尚未开
        #expect(clock.futuresMayBeOpen(at: date(12, 6, 30)))            // 周一 COMEX 已开
        #expect(clock.futuresMayBeOpen(at: date(14, 22, 0)))            // 周三夜盘
        #expect(clock.futuresMayBeOpen(at: date(17, 3, 0)))             // 周六凌晨仍有夜盘/外盘
        #expect(clock.futuresMayBeOpen(at: date(17, 6, 0)) == false)    // 周六 5 点后休市
        #expect(clock.futuresMayBeOpen(at: date(18, 12, 0)) == false)   // 周日
    }

    @Test func 含期货时A股休市也轮询() {
        let clock = TradingClock()
        let night = date(14, 22, 0)    // 周三夜间,A 股休市
        let off = RefreshScheduler.decide(now: night, clock: clock, suspended: false, hasConsumers: true,
                                          marketClosedToday: false, interval: 3, conserving: false)
        if case .idle = off {} else { Issue.record("无期货时夜间应空闲") }
        let on = RefreshScheduler.decide(now: night, clock: clock, suspended: false, hasConsumers: true,
                                         marketClosedToday: false, interval: 3, conserving: false, watchingFutures: true)
        #expect(on == .poll(5))     // 期货轮询不低于 5 秒
    }

    @Test func 周日含期货也不轮询() {
        let clock = TradingClock()
        let sunday = date(18, 12, 0)
        let d = RefreshScheduler.decide(now: sunday, clock: clock, suspended: false, hasConsumers: true,
                                        marketClosedToday: false, interval: 3, conserving: false, watchingFutures: true)
        if case .idle = d {} else { Issue.record("周日应空闲") }
    }

    @Test func 暂停与无界面优先于期货() {
        let clock = TradingClock()
        let d = RefreshScheduler.decide(now: date(14, 22, 0), clock: clock, suspended: true, hasConsumers: true,
                                        marketClosedToday: false, interval: 3, conserving: false, watchingFutures: true)
        #expect(d == .idle(600))
    }

    @Test func A股交易时段保持用户间隔() {
        let clock = TradingClock()
        let d = RefreshScheduler.decide(now: date(14, 10, 0), clock: clock, suspended: false, hasConsumers: true,
                                        marketClosedToday: false, interval: 10, conserving: false, watchingFutures: true)
        #expect(d == .poll(10))
    }
}
