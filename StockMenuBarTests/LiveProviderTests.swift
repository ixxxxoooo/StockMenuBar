//
//  LiveProviderTests.swift
//  StockMenuBarTests
//
//  真实网络联调测试(默认跳过)。运行方式:
//  TEST_RUNNER_LIVE_TESTS=1 xcodebuild test -scheme StockMenuBar -destination 'platform=macOS'
//  @author ixxxxoooo
//

import Foundation
import Testing

private let liveEnabled = ProcessInfo.processInfo.environment["LIVE_TESTS"] == "1"
private let liveSymbols = ["sh600519", "sz000001", "sh000001", "sz159915", "bj830799"].compactMap(StockSymbol.init(full:))

struct LiveProviderTests {
    private func providers() -> [any QuoteProvider] {
        let http = URLSessionHTTPClient(timeout: 6)
        return [TencentProvider(http: http), SinaProvider(http: http), EastmoneyProvider(http: http)]
    }

    @Test(.enabled(if: liveEnabled)) func 三源实时行情均可用() async throws {
        for provider in providers() {
            let quotes = try await provider.fetchQuotes(liveSymbols)
            #expect(quotes.count >= 4, "\(provider.id) 返回 \(quotes.count) 条")
            let moutai = try #require(quotes.first { $0.symbol.full == "sh600519" })
            #expect(moutai.name == "贵州茅台")
            #expect(moutai.isValid)
            let index = try #require(quotes.first { $0.symbol.full == "sh000001" })
            #expect(index.name.contains("上证"))
            #expect(index.price > 1000)
        }
    }

    @Test(.enabled(if: liveEnabled)) func 分时源可用() async throws {
        for provider in providers() where provider.capabilities.contains(.minute) {
            let series = try await provider.fetchMinute(symbol: StockSymbol(full: "sh600519")!)
            #expect(series.bars.count > 100, "\(provider.id)")
            #expect(series.prevClose > 0)
        }
    }

    @Test(.enabled(if: liveEnabled)) func 搜索支持拼音中文与代码() async throws {
        for provider in providers() {
            for key in ["gzmt", "贵州茅台", "600519"] {
                let results = try await provider.search(keyword: key)
                #expect(results.contains { $0.symbol.full == "sh600519" }, "\(provider.id) 搜索 \(key)")
            }
        }
    }

    @Test(.enabled(if: liveEnabled)) func 路由端到端() async throws {
        let router = ProviderRouter.makeDefault()
        let quotes = try await router.quotes(for: liveSymbols)
        #expect(quotes.value.count >= 4)
        let minute = try await router.minute(for: StockSymbol(full: "sz000001")!)
        #expect(!minute.value.bars.isEmpty)
        let search = try await router.search("pingan")
        #expect(!search.value.isEmpty)
    }
}
