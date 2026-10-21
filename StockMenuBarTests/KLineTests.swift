//
//  KLineTests.swift
//  StockMenuBarTests
//
//  K 线:腾讯解析、均线计算、路由。
//  @author ixxxxoooo
//

import Foundation
import Testing

/// 可编排 K 线行为的模拟数据源
private struct KLineMock: QuoteProvider {
    let id: ProviderID
    let capabilities: Set<ProviderCapability> = [.kline]
    let log: CallLog
    let result: @Sendable () throws -> KLineSeries

    func fetchQuotes(_ symbols: [StockSymbol]) async throws -> [Quote] { throw ProviderError.unsupported }
    func fetchKLine(symbol: StockSymbol, period: KLinePeriod) async throws -> KLineSeries {
        await log.add(id)
        return try result()
    }
}

private func makeSeries(source: ProviderID, closes: [Double] = [1, 2, 3]) -> KLineSeries {
    let bars = closes.enumerated().map {
        KLineBar(date: "2026-01-0\($0.offset + 1)", open: $0.element - 0.5, close: $0.element,
                 high: $0.element + 1, low: $0.element - 1, volume: 100, amount: 1000)
    }
    return KLineSeries(symbol: StockSymbol(full: "sh600519")!, period: .day, bars: bars, source: source, decimals: 2)
}

struct KLineTests {
    @Test func 腾讯K线解析个股与指数() throws {
        let s = try TencentParser.parseKLine(try Fixture.data("tx_kline.json"),
                                             symbol: StockSymbol(full: "sh600519")!, period: .week)
        #expect(s.bars.count == 3)
        #expect(s.bars.allSatisfy { $0.volume > 0 })
        // 指数成交量单位不一致,统一记 0
        let json = #"{"data":{"sh000001":{"day":[["2026-10-21","3838.98","3716.27","3864.12","3674.82","4476251780"]]}}}"#
        let idx = try TencentParser.parseKLine(Data(json.utf8), symbol: StockSymbol(full: "sh000001")!, period: .day)
        #expect(idx.bars.first?.volume == 0)
        #expect(idx.bars.first?.close == 3716.27)
    }

    @Test func 均线计算() {
        let s = makeSeries(source: .tencent, closes: [1, 2, 3, 4, 5])
        let ma3 = s.movingAverage(3)
        #expect(ma3.count == 5)
        #expect(ma3[0] == nil && ma3[1] == nil)
        #expect(ma3[2] == 2 && ma3[3] == 3 && ma3[4] == 4)
        #expect(s.movingAverage(0).allSatisfy { $0 == nil })
    }

    @Test func K线只走具备能力的数据源() async throws {
        let log = CallLog()
        let router = ProviderRouter(providers: [
            MockProvider(id: .eastmoney, log: log, behavior: { [] }),
            KLineMock(id: .tencent, log: log, result: { makeSeries(source: .tencent) })
        ], config: RouterConfig())
        let r = try await router.kline(for: StockSymbol(full: "sh600519")!, period: .day)
        #expect(r.provider == .tencent)
        #expect(await log.count(of: .eastmoney) == 0)
    }

    @Test func 腾讯不承接期货K线() {
        let tencent = TencentProvider(http: URLSessionHTTPClient())
        let future = StockSymbol(full: "fu113.cum")!
        #expect(!tencent.canServe(.kline, symbol: future))
        #expect(tencent.canServe(.kline, symbol: StockSymbol(full: "sh600519")!))
    }
}
