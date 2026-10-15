//
//  ParserTests.swift
//  StockMenuBarTests
//
//  三源数据解析测试(使用真实接口抓取的样本)。
//  @author ixxxxoooo
//

import Foundation
import Testing

struct ParserTests {
    // MARK: 腾讯

    @Test func 腾讯行情解析个股() throws {
        let quotes = TencentParser.parseQuotes(try Fixture.text("tencent_quote.txt"))
        #expect(quotes.count == 3)
        let moutai = try #require(quotes.first { $0.symbol.full == "sh600519" })
        #expect(moutai.name == "贵州茅台")
        #expect(moutai.price == 1312.97)
        #expect(moutai.prevClose == 1286.00)
        #expect(moutai.high == 1317.76)
        #expect(moutai.low == 1282.00)
        #expect(moutai.volume == 57677)
        #expect(abs(moutai.amount - 7_537_710_000) < 10_000_000)
        #expect(moutai.turnover == 0.46)
        #expect(moutai.bids.count == 5 && moutai.asks.count == 5)
        #expect(moutai.bids[0] == PriceLevel(price: 1312.31, volume: 3))
        #expect(moutai.asks[4] == PriceLevel(price: 1313.02, volume: 1))
        #expect(moutai.trend == .up)
        #expect(abs(moutai.changePercent - 2.097) < 0.01)
        #expect(moutai.time != nil)
        #expect(moutai.source == .tencent)
    }

    @Test func 腾讯行情区分沪深同号() throws {
        let quotes = TencentParser.parseQuotes(try Fixture.text("tencent_quote.txt"))
        let sh = try #require(quotes.first { $0.symbol.full == "sh000001" })
        let sz = try #require(quotes.first { $0.symbol.full == "sz000001" })
        #expect(sh.name == "上证指数" && sh.symbol.kind == .index)
        #expect(sz.name == "平安银行" && sz.symbol.kind == .main)
        #expect(sh.bids.isEmpty)
    }

    @Test func 腾讯分时解析() throws {
        let series = try TencentParser.parseMinute(try Fixture.data("tencent_minute.json"), symbol: StockSymbol(full: "sh600519")!)
        #expect(series.prevClose == 1286.00)
        #expect(series.date == "20261015")
        #expect(series.bars.first?.index == 0)
        #expect(series.bars.first?.price == 1286.00)
        #expect(series.bars.first?.volume == 357)
        #expect(abs((series.bars.first?.avgPrice ?? 0) - 1286.0) < 0.01)
        #expect(series.bars.last?.price == 1312.97)
        // 分钟序号单调递增
        let indexes = series.bars.map(\.index)
        #expect(indexes == indexes.sorted())
    }

    @Test func 腾讯搜索解析并过滤基金() throws {
        let results = TencentParser.parseSearch(try Fixture.text("tencent_search.txt"))
        #expect(results.count == 1)
        #expect(results[0].symbol.full == "sh600519")
        #expect(results[0].name == "贵州茅台")
        #expect(results[0].pinyin == "GZMT")
        // 含指数、个股、开放式基金(应被过滤)
        let mixed = "v_hint=\"sh~000001~\\u4e0a\\u8bc1\\u6307\\u6570~szzs~ZS^sz~000001~\\u5e73\\u5b89\\u94f6\\u884c~payh~GP-A^jj~000001~\\u534e\\u590f~hx~KJ\""
        let r = TencentParser.parseSearch(mixed)
        #expect(r.map(\.symbol.full) == ["sh000001", "sz000001"])
        #expect(TencentParser.parseSearch("v_hint=\"N\";").isEmpty)
    }

    // MARK: 新浪

    @Test func 新浪行情解析() throws {
        let quotes = SinaParser.parseQuotes(try Fixture.text("sina_quote.txt"))
        #expect(quotes.count == 2)
        let moutai = try #require(quotes.first { $0.symbol.full == "sh600519" })
        #expect(moutai.name == "贵州茅台")
        #expect(moutai.price == 1312.97)
        #expect(moutai.prevClose == 1286.0)
        // 股 → 手
        #expect(abs(moutai.volume - 57677.22) < 0.01)
        #expect(moutai.bids.count == 5 && moutai.asks.count == 5)
        #expect(moutai.bids[0] == PriceLevel(price: 1312.31, volume: 3))
        #expect(moutai.turnover == nil)
        #expect(moutai.time != nil)
        let index = try #require(quotes.first { $0.symbol.full == "sh000001" })
        #expect(index.bids.isEmpty)
        #expect(index.price == 3707.476)
    }

    @Test func 新浪搜索解析并过滤债券权证() throws {
        let results = SinaParser.parseSearch(try Fixture.text("sina_search.txt"))
        #expect(results.first?.symbol.full == "sh600519")
        #expect(results.contains { $0.symbol.full == "sz399436" })
        let text = "var suggestvalue=\"某债,15,110001,sh110001,某债,,某债,99,1,,,;某ETF,14,510300,sh510300,某ETF,,某ETF,99,1,,,;某基金,14,184801,sz184801,某,,某,99,1,,,\""
        let r = SinaParser.parseSearch(text)
        #expect(r.map(\.symbol.full) == ["sh510300"])
    }

    // MARK: 东财

    @Test func 东财行情解析并映射市场() throws {
        let requested = [StockSymbol(full: "sh600519")!, StockSymbol(full: "sz000001")!]
        let quotes = try EastmoneyParser.parseQuotes(try Fixture.data("em_quote.json"), requested: requested)
        #expect(quotes.count == 2)
        let ping = try #require(quotes.first { $0.symbol.full == "sz000001" })
        #expect(ping.name == "平安银行")
        #expect(ping.price == 11.41)
        #expect(ping.prevClose == 11.5)
        #expect(ping.turnover == 0.78)
        #expect(ping.source == .eastmoney)
    }

    @Test func 东财行情停牌价格回退昨收() throws {
        let json = #"{"data":{"diff":[{"f2":"-","f12":"830799","f13":0,"f14":"某北交所","f18":34.28}]}}"#
        let q = try EastmoneyParser.parseQuotes(Data(json.utf8), requested: [StockSymbol(full: "bj830799")!])
        #expect(q.first?.price == 34.28)
    }

    @Test func 东财分时解析() throws {
        let series = try EastmoneyParser.parseMinute(try Fixture.data("em_trends.json"), symbol: StockSymbol(full: "sh600519")!)
        #expect(series.prevClose == 1286.0)
        #expect(series.date == "20261015")
        #expect(series.bars.first?.index == 0)
        #expect(series.bars.first?.volume == 357)
        #expect(series.bars.count > 200)
    }

    @Test func 东财搜索解析() throws {
        let results = try EastmoneyParser.parseSearch(try Fixture.data("em_search.json"))
        #expect(results.count == 1)
        #expect(results[0].symbol.full == "sh600519")
        #expect(results[0].pinyin == "GZMT")
    }

    // MARK: 分时序号

    @Test func 分时序号映射() {
        #expect(MinuteBar.index(hour: 9, minute: 29) == nil)
        #expect(MinuteBar.index(hour: 9, minute: 30) == 0)
        #expect(MinuteBar.index(hour: 11, minute: 30) == 120)
        #expect(MinuteBar.index(hour: 12, minute: 0) == nil)
        #expect(MinuteBar.index(hour: 13, minute: 1) == 121)
        #expect(MinuteBar.index(hour: 15, minute: 0) == 240)
    }
}
