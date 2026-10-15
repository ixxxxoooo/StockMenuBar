//
//  RouterTests.swift
//  StockMenuBarTests
//
//  高可用路由:故障转移、对冲请求、数据校验、熔断统计、失败放行;
//  以及搜索防抖、自选存储。
//  @author ixxxxoooo
//

import Foundation
import Testing

private let sample = [StockSymbol(full: "sh600519")!]

private func makeRouter(_ providers: [MockProvider], hedge: TimeInterval = 0.15) -> ProviderRouter {
    var config = RouterConfig()
    config.hedgeDelay = hedge
    return ProviderRouter(providers: providers, config: config)
}

struct RouterTests {
    @Test func 主源失败自动转移到备源() async throws {
        let log = CallLog()
        let router = makeRouter([
            MockProvider(id: .tencent, log: log, behavior: { throw MockError() }),
            MockProvider(id: .sina, log: log, behavior: { [makeQuote(source: .sina)] })
        ])
        let result = try await router.quotes(for: sample)
        #expect(result.provider == .sina)
        #expect(await log.count(of: .tencent) == 1)
        #expect(await log.count(of: .sina) == 1)
    }

    @Test func 主源超时未返回时对冲请求备源() async throws {
        let log = CallLog()
        let router = makeRouter([
            MockProvider(id: .tencent, log: log, behavior: {
                try await Task.sleep(for: .seconds(5))
                return [makeQuote(source: .tencent)]
            }),
            MockProvider(id: .sina, log: log, behavior: { [makeQuote(source: .sina)] })
        ])
        let start = Date()
        let result = try await router.quotes(for: sample)
        #expect(result.provider == .sina)
        #expect(Date().timeIntervalSince(start) < 2)
    }

    @Test func 脏数据视为失败并转移() async throws {
        let log = CallLog()
        let router = makeRouter([
            MockProvider(id: .tencent, log: log, behavior: { [makeQuote(price: 10, prev: 0)] }),
            MockProvider(id: .sina, log: log, behavior: { [makeQuote(source: .sina)] })
        ])
        let result = try await router.quotes(for: sample)
        #expect(result.provider == .sina)
        #expect(result.value.allSatisfy { $0.isValid })
    }

    @Test func 全部失败抛出聚合错误() async throws {
        let log = CallLog()
        let router = makeRouter([
            MockProvider(id: .tencent, log: log, behavior: { throw MockError() }),
            MockProvider(id: .sina, log: log, behavior: { throw MockError() }),
            MockProvider(id: .eastmoney, log: log, behavior: { throw MockError() })
        ])
        await #expect(throws: ProviderError.self) { try await router.quotes(for: sample) }
        #expect(await log.calls.count == 3)
    }

    @Test func 连续失败后熔断且全部熔断时仍失败放行() async throws {
        let log = CallLog()
        let router = makeRouter([MockProvider(id: .tencent, log: log, behavior: { throw MockError() })])
        for _ in 0..<3 { _ = try? await router.quotes(for: sample) }
        let status = await router.statuses().first
        if case .open = status?.breaker {} else { Issue.record("应已熔断") }
        // 全部熔断时仍会尝试(fail-open),保证恢复后第一时间可用
        _ = try? await router.quotes(for: sample)
        #expect(await log.count(of: .tencent) == 4)
    }

    @Test func 失败源被降权_健康源优先() async throws {
        let log = CallLog()
        let router = makeRouter([
            MockProvider(id: .tencent, log: log, behavior: { throw MockError() }),
            MockProvider(id: .sina, log: log, behavior: { [makeQuote(source: .sina)] })
        ])
        _ = try await router.quotes(for: sample)   // 腾讯失败一次,降权
        _ = try await router.quotes(for: sample)
        _ = try await router.quotes(for: sample)
        // 之后新浪成为首选,腾讯不再每次都被先请求
        #expect(await log.count(of: .tencent) < 3)
        #expect(await log.count(of: .sina) == 3)
    }

    @Test func 请求为空列表直接成功() async throws {
        let log = CallLog()
        let router = makeRouter([MockProvider(id: .tencent, log: log, behavior: { [] })])
        let result = try await router.quotes(for: [])
        #expect(result.value.isEmpty)
    }

    @Test func 搜索空结果不触发转移() async throws {
        let log = CallLog()
        let router = makeRouter([
            MockProvider(id: .tencent, log: log, behavior: { [] }),
            MockProvider(id: .sina, log: log, behavior: { [makeQuote(source: .sina)] })
        ])
        let result = try await router.search("zzz")
        #expect(result.value.isEmpty)
        #expect(await log.count(of: .sina) == 0)
    }
}

@MainActor
struct SearchViewModelTests {
    @Test func 连续输入只发出一次请求() async throws {
        let log = CallLog()
        let router = makeRouter([MockProvider(id: .tencent, log: log, behavior: { [makeQuote("sh600519")] })])
        let vm = SearchViewModel(router: router)
        for text in ["g", "gz", "gzm", "gzmt"] {
            vm.query = text
            vm.queryChanged()
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(vm.isSearching)
        #expect(await log.calls.isEmpty)       // 未到 300ms 不请求
        try await Task.sleep(for: .milliseconds(700))
        #expect(await log.calls.count == 1)
        #expect(vm.results.count == 1)
        #expect(!vm.isSearching)
        #expect(vm.resultsQuery == "gzmt")
    }

    @Test func 清空输入立即清除结果() async throws {
        let log = CallLog()
        let router = makeRouter([MockProvider(id: .tencent, log: log, behavior: { [makeQuote("sh600519")] })])
        let vm = SearchViewModel(router: router)
        vm.query = "gzmt"
        vm.queryChanged()
        try await Task.sleep(for: .milliseconds(600))
        #expect(!vm.results.isEmpty)
        vm.query = ""
        vm.queryChanged()
        #expect(vm.results.isEmpty && !vm.isSearching)
    }

    @Test func 相同关键字命中缓存() async throws {
        let log = CallLog()
        let router = makeRouter([MockProvider(id: .tencent, log: log, behavior: { [makeQuote("sh600519")] })])
        let vm = SearchViewModel(router: router)
        vm.query = "gzmt"
        vm.queryChanged()
        try await Task.sleep(for: .milliseconds(600))
        vm.query = "x"
        vm.queryChanged()
        vm.query = "gzmt"
        vm.queryChanged()
        #expect(!vm.results.isEmpty)
        #expect(await log.calls.count == 1)
    }

    @Test func 排序_代码完全匹配优先且去重() {
        let a = SearchResult(symbol: StockSymbol(full: "sz000001")!, name: "平安银行", pinyin: "PAYH")
        let b = SearchResult(symbol: StockSymbol(full: "sh000001")!, name: "上证指数", pinyin: "SZZS")
        let c = SearchResult(symbol: StockSymbol(full: "sz000001")!, name: "平安银行", pinyin: "PAYH")
        let ranked = SearchViewModel.rank([a, b, c], query: "000001")
        #expect(ranked.count == 2)
        let ranked2 = SearchViewModel.rank([
            SearchResult(symbol: StockSymbol(full: "sz000589")!, name: "贵州轮胎", pinyin: "GZLT"),
            SearchResult(symbol: StockSymbol(full: "sh600519")!, name: "贵州茅台", pinyin: "GZMT")
        ], query: "gzmt")
        #expect(ranked2.first?.symbol.full == "sh600519")
    }
}

@MainActor
struct WatchlistStoreTests {
    @Test func 首次启动写入默认分组() {
        let store = WatchlistStore(inMemory: true)
        #expect(store.groups.map(\.name) == ["大盘", "自选A", "自选B", "ETF", "期货"])
        #expect(store.groups[0].items.count == 4)
        #expect(store.selectedGroup?.name == "大盘")
        #expect(store.allSymbols.contains(StockSymbol(full: "sh600519")!))
    }

    @Test func 加入自选并去重() throws {
        let store = WatchlistStore(inMemory: true)
        let b = try #require(store.groups.first { $0.name == "自选B" })
        let s = StockSymbol(full: "sh601318")!
        #expect(store.add(symbol: s, name: "中国平安", to: b.id))
        #expect(!store.add(symbol: s, name: "中国平安", to: b.id))
        #expect(store.contains(s, in: b.id))
        #expect(store.groups.first { $0.id == b.id }?.items.count == 1)
    }

    @Test func 拖拽排序与删除() throws {
        let store = WatchlistStore(inMemory: true)
        let a = try #require(store.groups.first { $0.name == "自选A" })
        #expect(a.items.map(\.symbol.full) == ["sh600519", "sz000001", "sz300750"])
        store.moveItems(in: a.id, from: IndexSet(integer: 2), to: 0)
        let moved = try #require(store.groups.first { $0.id == a.id })
        #expect(moved.items.map(\.symbol.full) == ["sz300750", "sh600519", "sz000001"])
        store.remove(itemID: moved.items[0].id)
        #expect(store.groups.first { $0.id == a.id }?.items.count == 2)
    }

    @Test func 分组增删改与排序() throws {
        let store = WatchlistStore(inMemory: true)
        let newID = try #require(store.addGroup(name: "港股通"))
        #expect(store.groups.last?.name == "港股通")
        store.renameGroup(id: newID, to: "科技")
        #expect(store.groups.last?.name == "科技")
        store.moveGroups(from: IndexSet(integer: 5), to: 0)
        #expect(store.groups.first?.name == "科技")
        store.deleteGroup(id: newID)
        #expect(store.groups.count == 5)
        #expect(store.addGroup(name: "  ") == nil)
    }

    @Test func 跨分组移动条目() throws {
        let store = WatchlistStore(inMemory: true)
        let a = try #require(store.groups.first { $0.name == "自选A" })
        let b = try #require(store.groups.first { $0.name == "自选B" })
        store.moveItem(itemID: a.items[0].id, toGroup: b.id)
        #expect(store.groups.first { $0.id == b.id }?.items.count == 1)
        #expect(store.groups.first { $0.id == a.id }?.items.count == 2)
    }
}

@MainActor
struct PreferencesTests {
    @Test func 菜单栏固定上限为两只() {
        let defaults = UserDefaults(suiteName: "test.prefs.\(UUID().uuidString)")!
        let prefs = Preferences(defaults: defaults)
        let a = StockSymbol(full: "sh600519")!, b = StockSymbol(full: "sz000001")!, c = StockSymbol(full: "sz300750")!
        prefs.togglePinned(a); prefs.togglePinned(b); prefs.togglePinned(c)
        #expect(prefs.pinnedSymbols == ["sz000001", "sz300750"])
        prefs.togglePinned(b)
        #expect(!prefs.isPinned(b))
        prefs.forget(c)
        #expect(prefs.pinnedSymbols.isEmpty)
    }

    @Test func 偏好持久化与默认值() {
        let name = "test.prefs.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let prefs = Preferences(defaults: defaults)
        #expect(prefs.refreshInterval == 3 && prefs.redUp && prefs.floatingStyle == .list)
        prefs.refreshInterval = 10
        prefs.redUp = false
        prefs.floatingStyle = .capsule
        let again = Preferences(defaults: UserDefaults(suiteName: name)!)
        #expect(again.refreshInterval == 10 && !again.redUp && again.floatingStyle == .capsule)
    }
}
