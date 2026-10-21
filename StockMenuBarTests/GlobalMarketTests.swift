//
//  GlobalMarketTests.swift
//  StockMenuBarTests
//
//  全球指数、贵金属与多源兜底:腾讯美股指数、新浪外盘/A 股分钟线、雅虎 chart 的解析,以及目录映射与路由兜底。
//  @author ixxxxoooo
//

import Foundation
import Testing

// MARK: - 目录与映射

struct GlobalCatalogTests {
    @Test func 预置品种唯一且标识可往返() {
        let secids = FuturesCatalog.all.map(\.secid)
        #expect(Set(secids).count == secids.count)
        for preset in FuturesCatalog.all {
            #expect(StockSymbol(full: preset.symbol.full) == preset.symbol)
        }
    }

    @Test func 分组种子包含贵金属与全球指数() {
        let groups = Dictionary(uniqueKeysWithValues: FuturesCatalog.groupSeeds.map { ($0.name, $0.presets.map(\.name)) })
        #expect(groups["贵金属"] == ["纽约金", "伦敦金", "纽约银", "伦敦银", "沪金主连", "沪银主连", "现货黄金"])
        #expect(groups["全球指数"]?.contains("道琼斯") == true)
        #expect(groups["全球指数"]?.contains("韩国KOSPI") == true)
        #expect(groups["全球指数"]?.contains("韩国KOSDAQ") == true)
    }

    @Test func 各源映射() {
        #expect(FuturesCatalog.tencentCode(secid: "100.DJIA") == "usDJI")
        #expect(FuturesCatalog.sinaMapping(secid: "100.DJIA")?.code == "gb_$dji")
        #expect(FuturesCatalog.yahooCode(secid: "100.KS11") == "^KS11")
        #expect(FuturesCatalog.sinaMapping(secid: "122.XAU")?.code == "hf_XAU")
        #expect(FuturesCatalog.yahooCode(secid: "122.XAU") == nil)
        // 韩国创业板东财没有,只能靠新浪/雅虎
        #expect(!FuturesCatalog.eastmoneySupports(secid: "100.KQ11"))
        #expect(FuturesCatalog.eastmoneySupports(secid: "100.KS11"))
        #expect(FuturesCatalog.exchangeName(secid: "122.XAU") == "伦敦现货")
    }

    @Test func 指数都识别为指数类别() {
        for preset in FuturesCatalog.globalIndices {
            #expect(preset.symbol.kind == .index)
        }
        #expect(StockSymbol(full: "fu101.GC00Y")?.kind == .future)
    }

    @Test func 本地联想命中新品种() {
        #expect(FuturesCatalog.localSearch("纽约金").first?.symbol.code == "101.GC00Y")
        #expect(FuturesCatalog.localSearch("LDJ").contains { $0.symbol.code == "122.XAU" })
        #expect(FuturesCatalog.localSearch("韩国").count >= 3)
        #expect(FuturesCatalog.localSearch("DQS").contains { $0.symbol.code == "100.DJIA" })
    }
}

// MARK: - 腾讯美股指数

struct TencentGlobalParserTests {
    private func requested() -> [StockSymbol] {
        ["fu100.DJIA", "fu100.NDX", "fu100.SPX"].compactMap(StockSymbol.init(full:))
    }

    @Test func 美股指数行情() throws {
        let quotes = TencentParser.parseGlobalQuotes(try Fixture.text("tencent_us_quote.txt"), requested: requested())
        #expect(quotes.count == 3)
        let dji = try #require(quotes.first { $0.symbol.code == "100.DJIA" })
        #expect(dji.name == "道琼斯")
        #expect(dji.prevClose == 51621.48)
        #expect(dji.price > 40000 && dji.high >= dji.price && dji.low <= dji.price)
        #expect(dji.decimals == 2 && dji.source == .tencent && dji.time != nil)
        #expect(dji.isValid)
    }

    @Test func 美股指数分时() throws {
        let symbol = try #require(StockSymbol(full: "fu100.DJIA"))
        let series = try TencentParser.parseUSMinute(try Fixture.data("tencent_us_minute.json"), symbol: symbol, code: "usDJI")
        #expect(series.axis.total == 390)
        #expect(series.bars.first?.index == 0)
        #expect(series.bars.count == 45)
        #expect(series.axis.label(index: 0) == "09:30" && series.axis.label(index: 390) == "16:00")
        #expect(series.prevClose == 51621.48)
        // 累计量差分后不应出现负数
        #expect(series.bars.allSatisfy { $0.volume >= 0 })
    }
}

// MARK: - 新浪全球指数 / 外盘分时 / A 股分钟线

struct SinaGlobalParserTests {
    private func requested() -> [StockSymbol] {
        ["fu100.DJIA", "fu100.NDX", "fu100.KQ11", "fu100.KS11", "fu122.XAU", "fu101.GC00Y"].compactMap(StockSymbol.init(full:))
    }

    @Test func 美股指数与韩国指数行情() throws {
        let quotes = SinaParser.parseFuturesQuotes(try Fixture.text("sina_global_quote.txt"), requested: requested())
        let dji = try #require(quotes.first { $0.symbol.code == "100.DJIA" })
        #expect(dji.prevClose == 51621.48 && dji.name == "道琼斯" && dji.decimals == 2)
        let kosdaq = try #require(quotes.first { $0.symbol.code == "100.KQ11" })
        #expect(kosdaq.name == "韩国KOSDAQ")
        #expect(kosdaq.prevClose == 823.88 && kosdaq.open == 784.45)
        #expect(kosdaq.high == 788.69 && kosdaq.low == 745.43)
        #expect(kosdaq.changePercent < -7)
        #expect(kosdaq.time != nil)
    }

    @Test func 伦敦金与纽约金行情() throws {
        let quotes = SinaParser.parseFuturesQuotes(try Fixture.text("sina_global_quote.txt"), requested: requested())
        let xau = try #require(quotes.first { $0.symbol.code == "122.XAU" })
        #expect(xau.name == "伦敦金" && xau.prevClose == 4105.20)
        #expect(xau.high >= xau.price && xau.low <= xau.price)
        #expect(quotes.contains { $0.symbol.code == "101.GC00Y" })
    }

    @Test func 外盘期货分时() throws {
        let symbol = try #require(StockSymbol(full: "fu122.XAU"))
        let series = try SinaParser.parseGlobalFuturesMinute(try Fixture.data("sina_global_minute.txt"), symbol: symbol, scale: 1)
        #expect(series.prevClose == 4105.2)
        #expect(series.axis.segments.count == 1 && series.axis.segments[0].start == 6 * 60)
        #expect(series.axis.total == 1380)
        #expect(series.bars.first?.index == 0)
        #expect(series.bars.count >= 30)
        // 末尾几根已跨到次日凌晨,序号应大于 1000
        #expect((series.bars.last?.index ?? 0) > 1000)
        #expect(series.axis.label(index: 0) == "06:00")
    }

    @Test func A股分钟线只取最新交易日() throws {
        let symbol = try #require(StockSymbol(full: "sh600519"))
        let series = try SinaParser.parseAShareMinute(try Fixture.data("sina_kline.txt"), symbol: symbol)
        #expect(series.bars.count == 238)
        #expect(series.bars.allSatisfy { (0...240).contains($0.index) })
        #expect(series.bars.map(\.index) == series.bars.map(\.index).sorted())
        #expect(series.bars.last?.index == 240)
        #expect(series.bars.allSatisfy { ($0.avgPrice ?? 0) > 0 })
        #expect(series.prevClose > 0)
        #expect(series.date?.count == 8)
    }
}

// MARK: - 雅虎

struct YahooParserTests {
    @Test func 韩国指数分时使用本地时间() throws {
        let symbol = try #require(StockSymbol(full: "fu100.KS11"))
        let series = try YahooParser.parseMinute(try Fixture.data("yahoo_kospi_1m.json"), symbol: symbol)
        #expect(series.prevClose == 6008.81)
        // KST 09:00-15:00 的常规时段数据(样本抽样),横轴起点 09:00
        #expect(series.axis.segments.first?.start == 9 * 60)
        #expect(series.axis.total == 360)
        #expect(series.bars.first?.index == 0)
        #expect(series.axis.label(index: 0) == "09:00")
        #expect(series.decimals == 2 && series.source == .yahoo)
        #expect(series.date == "20261015")
    }

    @Test func 外盘期货分时使用北京时间() throws {
        let symbol = try #require(StockSymbol(full: "fu101.GC00Y"))
        let series = try YahooParser.parseMinute(try Fixture.data("yahoo_gold_1m.json"), symbol: symbol)
        // 美东 00:00(= 北京 12:00)起算
        #expect(series.axis.segments.first?.start == 12 * 60)
        #expect(series.prevClose == 4107.9)
        #expect(series.bars.first?.index == 0)
        #expect(series.bars.count > 100)
    }

    @Test func 行情高低在元数据为零时由分时统计() throws {
        let symbol = try #require(StockSymbol(full: "fu100.KS11"))
        let quote = try YahooParser.parseQuote(try Fixture.data("yahoo_kospi_1m.json"), symbol: symbol)
        #expect(quote.price == 5554.22 && quote.prevClose == 6008.81)
        #expect(quote.high > quote.low && quote.high >= quote.price && quote.low <= quote.price)
        #expect(quote.name == "韩国KOSPI")
        #expect(quote.changePercent < -7)
    }

    @Test func 量能集中在单一分钟的指数丢弃量能() throws {
        /// 40 根 1 分钟点,量能由调用方给定
        func json(volumes: [Int]) -> Data {
            let stamps = (0..<40).map { String(1_792_022_400 + $0 * 60) }.joined(separator: ",")
            let closes = (0..<40).map { String(100 + Double($0) / 10) }.joined(separator: ",")
            let vols = volumes.map(String.init).joined(separator: ",")
            return Data("""
            {"chart":{"result":[{"meta":{"gmtoffset":32400,"regularMarketPrice":101,"chartPreviousClose":100,
            "currentTradingPeriod":{"regular":{"start":1792108800,"end":1792130400}}},
            "timestamp":[\(stamps)],
            "indicators":{"quote":[{"close":[\(closes)],"volume":[\(vols)]}]}}],"error":null}}
            """.utf8)
        }
        let symbol = try #require(StockSymbol(full: "fu100.KS11"))
        var spikeVolumes = [Int](repeating: 0, count: 40)
        spikeVolumes[39] = 900_000
        let spike = try YahooParser.parseMinute(json(volumes: spikeVolumes), symbol: symbol)
        #expect(spike.bars.allSatisfy { $0.volume == 0 })
        let normal = try YahooParser.parseMinute(json(volumes: (0..<40).map { 100 + $0 }), symbol: symbol)
        #expect(normal.bars.map(\.volume) == (0..<40).map { Double(100 + $0) })
    }

    @Test func 空结果报错() {
        #expect(throws: ProviderError.self) {
            try YahooParser.parseChart(Data(#"{"chart":{"result":null,"error":{"code":"Not Found"}}}"#.utf8))
        }
    }
}

// MARK: - 路由兜底与完整性

/// 可编排分时返回的模拟源
struct MinuteMockProvider: QuoteProvider {
    let id: ProviderID
    let log: CallLog
    let capability: ProviderCapability
    let behavior: @Sendable () async throws -> MinuteSeries
    var capabilities: Set<ProviderCapability> { [capability] }

    func fetchQuotes(_ symbols: [StockSymbol]) async throws -> [Quote] { [] }

    func fetchMinute(symbol: StockSymbol) async throws -> MinuteSeries {
        await log.add(id)
        return try await behavior()
    }
}

private func series(_ symbol: StockSymbol, source: ProviderID, lastIndex: Int, date: String? = nil) -> MinuteSeries {
    let bars = (0...lastIndex).map { MinuteBar(index: $0, price: 10, volume: 1, avgPrice: nil) }
    return MinuteSeries(symbol: symbol, prevClose: 9.5, date: date, bars: bars, source: source)
}

struct MinuteFallbackTests {
    @Test func 前序数据源失败时由后序数据源提供分时() async throws {
        let log = CallLog()
        let symbol = try #require(StockSymbol(full: "fu100.KS11"))
        let bad = MinuteMockProvider(id: .eastmoney, log: log, capability: .futuresMinute) { throw MockError() }
        let good = MinuteMockProvider(id: .yahoo, log: log, capability: .futuresMinute) {
            series(symbol, source: .yahoo, lastIndex: 5)
        }
        let router = ProviderRouter(providers: [bad, good])
        let result = try await router.minute(for: symbol)
        #expect(result.provider == .yahoo)
        #expect(await log.count(of: .eastmoney) == 1)
    }

    @Test func 排除数据源后换源重试() async throws {
        let log = CallLog()
        let symbol = try #require(StockSymbol(full: "sh600519"))
        let a = MinuteMockProvider(id: .tencent, log: log, capability: .minute) { series(symbol, source: .tencent, lastIndex: 3) }
        let b = MinuteMockProvider(id: .sina, log: log, capability: .minute) { series(symbol, source: .sina, lastIndex: 200) }
        let router = ProviderRouter(providers: [a, b])
        let result = try await router.minute(for: symbol, excluding: [.tencent])
        #expect(result.provider == .sina)
    }

    @Test func 分时完整性判断() throws {
        let stock = try #require(StockSymbol(full: "sh600519"))
        let future = try #require(StockSymbol(full: "fu113.cum"))
        // 2026-10-15(周四)14:00 北京时间 → 期望序号约 180
        let now = try #require(ChinaTime.date(year: 2026, month: 10, day: 15, hour: 14, minute: 0))
        #expect(series(stock, source: .tencent, lastIndex: 180, date: "20261015").isComplete(now: now))
        #expect(series(stock, source: .tencent, lastIndex: 175, date: "20261015").isComplete(now: now))
        #expect(!series(stock, source: .tencent, lastIndex: 120, date: "20261015").isComplete(now: now))
        // 非当日数据与期货不做校验
        #expect(series(stock, source: .tencent, lastIndex: 10, date: "20261014").isComplete(now: now))
        #expect(series(future, source: .eastmoney, lastIndex: 10, date: "20261015").isComplete(now: now))
        // 盘后:应到 240
        let after = try #require(ChinaTime.date(year: 2026, month: 10, day: 15, hour: 16, minute: 0))
        #expect(!series(stock, source: .tencent, lastIndex: 200, date: "20261015").isComplete(now: after))
        #expect(series(stock, source: .tencent, lastIndex: 240, date: "20261015").isComplete(now: after))
    }

    @Test func 行情覆盖按各源能力选择() throws {
        let tencent = TencentProvider(http: URLSessionHTTPClient())
        let yahoo = YahooProvider(http: URLSessionHTTPClient())
        let eastmoney = EastmoneyProvider(http: URLSessionHTTPClient())
        let dji = try #require(StockSymbol(full: "fu100.DJIA"))
        let kospi = try #require(StockSymbol(full: "fu100.KS11"))
        let kosdaq = try #require(StockSymbol(full: "fu100.KQ11"))
        let xau = try #require(StockSymbol(full: "fu122.XAU"))
        // 腾讯只有美股指数;雅虎没有伦敦金;东财没有韩国创业板
        #expect(tencent.canServe(.futuresMinute, symbol: dji))
        #expect(!tencent.canServe(.futuresMinute, symbol: kospi))
        #expect(yahoo.canServe(.futuresMinute, symbol: kospi))
        #expect(!yahoo.canServe(.futuresMinute, symbol: xau))
        #expect(!eastmoney.canServe(.futuresQuotes, symbol: kosdaq))
        #expect(eastmoney.canServe(.futuresQuotes, symbol: xau))
        // 新浪:外盘期货有分时,指数没有
        let sina = SinaProvider(http: URLSessionHTTPClient())
        #expect(sina.canServe(.futuresMinute, symbol: xau))
        #expect(!sina.canServe(.futuresMinute, symbol: dji))
        #expect(sina.canServe(.futuresQuotes, symbol: dji))
    }
}
