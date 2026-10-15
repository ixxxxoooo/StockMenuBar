//
//  TestSupport.swift
//  StockMenuBarTests
//
//  测试公共工具:样本读取、模拟数据源。
//  @author ixxxxoooo
//

import Foundation


/// 读取 Fixtures 目录下的样本文件
enum Fixture {
    static func data(_ name: String, file: String = #filePath) throws -> Data {
        let url = URL(fileURLWithPath: file).deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent(name)
        return try Data(contentsOf: url)
    }

    static func text(_ name: String, file: String = #filePath) throws -> String {
        String(decoding: try data(name, file: file), as: UTF8.self)
    }
}

/// 构造测试行情
func makeQuote(_ full: String = "sh600519", price: Double = 10, prev: Double = 9.5, source: ProviderID = .tencent) -> Quote {
    Quote(symbol: StockSymbol(full: full)!, name: "测试", price: price, prevClose: prev, open: prev, high: price, low: prev,
          volume: 100, amount: 1000, turnover: 1, bids: [], asks: [], time: nil, source: source)
}

/// 调用记录
actor CallLog {
    private(set) var calls: [ProviderID] = []
    func add(_ id: ProviderID) { calls.append(id) }
    func count(of id: ProviderID) -> Int { calls.filter { $0 == id }.count }
}

/// 可编排行为的模拟数据源
struct MockProvider: QuoteProvider {
    let id: ProviderID
    var capabilities: Set<ProviderCapability> = [.quotes, .minute, .search]
    let log: CallLog
    let behavior: @Sendable () async throws -> [Quote]

    func fetchQuotes(_ symbols: [StockSymbol]) async throws -> [Quote] {
        await log.add(id)
        return try await behavior()
    }

    func search(keyword: String) async throws -> [SearchResult] {
        await log.add(id)
        let quotes = try await behavior()
        return quotes.map { SearchResult(symbol: $0.symbol, name: $0.name, pinyin: "") }
    }
}

struct MockError: Error {}
