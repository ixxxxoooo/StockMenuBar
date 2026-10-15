//
//  FaultInjection.swift
//  StockMenuBar
//
//  故障注入(调试用):通过启动参数 `--fail-source=tencent,sina` 让指定数据源恒定失败,
//  用于在真实运行环境里验证故障转移、熔断与恢复。生产使用时不会带该参数。
//  @author ixxxxoooo
//

import Foundation

/// 恒定失败的数据源包装
struct FaultInjectedProvider: QuoteProvider {
    let base: any QuoteProvider
    var id: ProviderID { base.id }
    var capabilities: Set<ProviderCapability> { base.capabilities }

    func canServe(_ capability: ProviderCapability, symbol: StockSymbol?) -> Bool {
        base.canServe(capability, symbol: symbol)
    }
    func fetchQuotes(_ symbols: [StockSymbol]) async throws -> [Quote] { throw ProviderError.httpStatus(503) }
    func searchFutures(keyword: String) async throws -> [SearchResult] { throw ProviderError.httpStatus(503) }
    func fetchMinute(symbol: StockSymbol) async throws -> MinuteSeries { throw ProviderError.httpStatus(503) }
    func search(keyword: String) async throws -> [SearchResult] { throw ProviderError.httpStatus(503) }
}

enum FaultInjection {
    /// 解析启动参数中需要注入故障的数据源
    static func failingSources(arguments: [String] = CommandLine.arguments) -> Set<ProviderID> {
        var result = Set<ProviderID>()
        for arg in arguments where arg.hasPrefix("--fail-source=") {
            for name in arg.dropFirst("--fail-source=".count).split(separator: ",") {
                if let id = ProviderID(rawValue: String(name)) { result.insert(id) }
            }
        }
        return result
    }

    /// 对需要注入故障的数据源做包装
    static func apply(to providers: [any QuoteProvider]) -> [any QuoteProvider] {
        let failing = failingSources()
        guard !failing.isEmpty else { return providers }
        return providers.map { failing.contains($0.id) ? FaultInjectedProvider(base: $0) : $0 }
    }
}
