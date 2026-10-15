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

    /// 东财被限流时返回 nil(跳过),其余数据源的错误照常抛出
    private func tolerant<T>(_ provider: any QuoteProvider, _ work: (any QuoteProvider) async throws -> T) async throws -> T? {
        do { return try await work(provider) } catch {
            if provider.id == .eastmoney { return nil }
            throw error
        }
    }

    @Test(.enabled(if: liveEnabled)) func 三源实时行情均可用() async throws {
        for provider in providers() {
            // 东财会对短时间内的高频请求限流(空响应/连接中断),这属于外部限制,不视为失败
            guard let quotes = try await tolerant(provider, { try await $0.fetchQuotes(liveSymbols) }) else { continue }
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
            guard let series = try await tolerant(provider, { try await $0.fetchMinute(symbol: StockSymbol(full: "sh600519")!) }) else { continue }
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

    // MARK: - 全球指数与贵金属

    private var globalSymbols: [StockSymbol] {
        (FuturesCatalog.globalIndices + FuturesCatalog.preciousMetals).map(\.symbol)
    }

    @Test(.enabled(if: liveEnabled)) func 全球品种行情路由端到端() async throws {
        let router = ProviderRouter.makeDefault()
        let result = try await router.quotes(for: globalSymbols)
        let got = Set(result.value.map(\.symbol))
        let missing = globalSymbols.filter { !got.contains($0) }.map(\.code)
        #expect(missing.isEmpty, "缺失行情: \(missing)")
        #expect(result.value.allSatisfy { $0.isValid })
    }

    @Test(.enabled(if: liveEnabled)) func 全球品种分时路由端到端() async throws {
        let router = ProviderRouter.makeDefault()
        for symbol in globalSymbols {
            let minute = try await router.minute(for: symbol)
            #expect(minute.value.bars.count > 10, "\(symbol.code) 来自 \(minute.provider)")
            #expect(minute.value.prevClose > 0)
        }
    }

    @Test(.enabled(if: liveEnabled)) func 雅虎与腾讯与新浪各自可用() async throws {
        let http = URLSessionHTTPClient(timeout: 8)
        let kospi = try #require(StockSymbol(full: "fu100.KS11"))
        let dji = try #require(StockSymbol(full: "fu100.DJIA"))
        let yahooQuotes = try await YahooProvider(http: http).fetchQuotes([kospi, dji])
        #expect(yahooQuotes.count == 2)
        let tencent = TencentProvider(http: http)
        #expect(try await tencent.fetchQuotes([dji]).count == 1)
        #expect(try await tencent.fetchMinute(symbol: dji).bars.count > 10)
        let sina = SinaProvider(http: http)
        let xau = try #require(StockSymbol(full: "fu122.XAU"))
        #expect(try await sina.fetchMinute(symbol: xau).bars.count > 100)
        #expect(try await sina.fetchQuotes([kospi, dji, xau]).count == 3)
    }
}
