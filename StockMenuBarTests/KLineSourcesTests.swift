//
//  KLineSourcesTests.swift
//  StockMenuBarTests
//
//  K 线多源:新浪解析与聚合、雅虎空值跳过、TradingView 帧解析与路由。
//  @author ixxxxoooo
//

import Foundation
import Testing

struct KLineSourcesTests {
    private let gold = FuturesCatalog.spotGold.symbol
    private let moutai = StockSymbol(market: .sh, code: "600519")

    @Test func sinaAShareVolumeConvertedToLots() throws {
        let json = #"/*x*/var t=([{"day":"2026-10-20","open":"10","high":"11","low":"9","close":"10.5","volume":"123400"}]);"#
        let s = try SinaKLineParser.parse(Data(json.utf8), symbol: moutai, period: .day, layout: .aShare)
        #expect(s.bars.count == 1)
        #expect(s.bars[0].volume == 1234)
        #expect(s.source == .sina)
    }

    @Test func aggregatesDailyIntoWeeksAndMonths() {
        func bar(_ d: String, _ o: Double, _ c: Double, _ h: Double, _ l: Double) -> KLineBar {
            KLineBar(date: d, open: o, close: c, high: h, low: l, volume: 1, amount: 0)
        }
        let days = [bar("2026-10-05", 1, 2, 3, 0.5), bar("2026-10-06", 2, 3, 5, 1), bar("2026-10-13", 3, 4, 4, 2), bar("2026-11-02", 4, 5, 6, 3)]
        let weeks = KLineAggregator.aggregate(days, period: .week)
        #expect(weeks.count == 3)
        #expect(weeks[0].open == 1 && weeks[0].close == 3 && weeks[0].high == 5 && weeks[0].low == 0.5 && weeks[0].volume == 2)
        let months = KLineAggregator.aggregate(days, period: .month)
        #expect(months.count == 2)
        #expect(months[0].date == "2026-10-13")
    }

    @Test func sinaDomesticFuturesAggregatesWeekly() throws {
        let json = #"[{"d":"2026-10-05","o":"1","h":"3","l":"1","c":"2","v":"5","p":"0"},{"d":"2026-10-06","o":"2","h":"4","l":"2","c":"3","v":"5","p":"0"}]"#
        let symbol = StockSymbol(market: .future, code: "113.cum")
        let s = try SinaKLineParser.parse(Data(json.utf8), symbol: symbol, period: .week, layout: .domesticFutures)
        #expect(s.bars.count == 1)
        #expect(s.bars[0].high == 4 && s.bars[0].volume == 10)
    }

    @Test func yahooKLineSkipsNullBars() throws {
        let json = #"{"chart":{"result":[{"meta":{"gmtoffset":32400},"timestamp":[1760000000,1760086400,1760172800],"indicators":{"quote":[{"open":[100,null,102],"high":[101,null,103],"low":[99,null,101],"close":[100.5,null,102.5],"volume":[0,null,0]}]}}]}}"#
        let symbol = StockSymbol(market: .future, code: "100.N225")
        let s = try YahooParser.parseKLine(Data(json.utf8), symbol: symbol, period: .day)
        #expect(s.bars.count == 2)
        #expect(s.source == .yahoo)
    }

    private func frame(_ json: String) -> String { "~m~\(json.utf8.count)~m~\(json)" }

    @Test func tradingViewParsesBarsDedupedAndSorted() throws {
        let a = #"{"m":"timescale_update","p":["cs",{"sds_1":{"s":[{"i":1,"v":[1760000000,10,12,9,11,5]},{"i":0,"v":[1759900000,8,10,7,9,3]}]}}]}"#
        let b = #"{"m":"du","p":["cs",{"sds_1":{"s":[{"i":1,"v":[1760000000,10,13,9,12,6]}]}}]}"#
        let bars = try TradingViewParser.parseBars(frame(a) + "~m~4~m~~h~1" + frame(b))
        #expect(bars.count == 2)
        #expect(bars[0].time < bars[1].time)
        #expect(bars[1].close == 12)
    }

    @Test func tradingViewQuoteUsesChangeForPrevClose() throws {
        let q = try TradingViewParser.parseQuote(Data(#"{"close":4123.975,"change_abs":-1.49,"open":4120,"high":4130,"low":4110}"#.utf8), symbol: gold)
        #expect(abs(q.prevClose - 4125.465) < 1e-6)
        #expect(q.source == .tradingview)
    }

    @Test func tradingViewDailyBarLabelledByTradingDay() throws {
        // 2026-10-19 21:00 UTC = 纽约 17:00(夏令时)→ 交易日 10-20
        let raw = [TradingViewParser.RawBar(time: 1_792_443_600, open: 1, high: 2, low: 1, close: 2, volume: 1)]
        let s = try TradingViewParser.parseKLine(raw, symbol: gold, period: .day)
        #expect(s.bars[0].date == "2026-10-20")
    }

    @Test func onlyTradingViewServesSpotGold() {
        #expect(TradingViewProvider(http: URLSessionHTTPClient()).canServe(.kline, symbol: gold))
        #expect(!SinaProvider(http: URLSessionHTTPClient()).canServe(.futuresQuotes, symbol: gold))
        #expect(!YahooProvider(http: URLSessionHTTPClient()).canServe(.kline, symbol: gold))
    }
}
