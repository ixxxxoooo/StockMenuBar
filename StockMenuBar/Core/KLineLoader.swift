//
//  KLineLoader.swift
//  StockMenuBar
//
//  K 线加载器:界面持有,按周期加载并缓存;交易中定时刷新最新一根,休市只取一次。
//  @author ixxxxoooo
//

import Foundation

@MainActor
@Observable
final class KLineLoader {
    private(set) var series: KLineSeries?
    private(set) var isLoading = false
    private(set) var failed = false

    @ObservationIgnored private let store: QuoteStore
    /// 同一次会话内按 (证券, 周期) 缓存,切换周期时先展示旧数据再静默刷新
    @ObservationIgnored private var cache: [String: KLineSeries] = [:]

    init(store: QuoteStore) { self.store = store }

    /// 持续加载某只证券某周期的 K 线,随 Task 取消而结束
    /// - Parameters:
    ///   - symbol: 证券
    ///   - period: 周期
    ///   - tradingInterval: 交易时段刷新间隔(秒)
    func run(symbol: StockSymbol, period: KLinePeriod, tradingInterval: TimeInterval = 60) async {
        let key = "\(symbol.full)#\(period.rawValue)"
        series = cache[key]
        isLoading = series == nil
        failed = false
        var failures = 0
        while !Task.isCancelled {
            var gotFresh = true
            if !store.isSuspended {
                if let routed = try? await store.router.kline(for: symbol, period: period) {
                    cache[key] = routed.value
                    series = routed.value
                    failed = false
                    failures = 0
                } else {
                    gotFresh = false
                    failures += 1
                    if series == nil { failed = true }
                }
            }
            isLoading = false
            if !gotFresh {
                try? await Task.sleep(for: .seconds(min(Double(1 << min(failures, 4)), 20)))
                continue
            }
            // 休市:取到一次即停
            if !store.isActivelyTrading(symbol) && series != nil { return }
            try? await Task.sleep(for: .seconds(tradingInterval))
        }
    }
}
