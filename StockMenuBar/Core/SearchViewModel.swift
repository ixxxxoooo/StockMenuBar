//
//  SearchViewModel.swift
//  StockMenuBar
//
//  搜索联想:300ms 防抖、取消过期请求、多源回退、结果缓存与排序。
//  @author ixxxxoooo
//

import Foundation
import Observation

@MainActor
@Observable
final class SearchViewModel {
    /// 防抖时长(毫秒)
    static let debounceMilliseconds = 300

    var query: String = ""
    private(set) var results: [SearchResult] = []
    private(set) var isSearching = false
    private(set) var errorText: String?
    /// 当前 results 所对应的关键字
    private(set) var resultsQuery: String = ""

    @ObservationIgnored private let router: ProviderRouter
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var cache: [String: [SearchResult]] = [:]

    /// - Parameter router: 高可用路由
    init(router: ProviderRouter) { self.router = router }

    /// 是否处于搜索状态(有输入)
    var isActive: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// 输入变化时调用:取消上一次请求并重新防抖
    func queryChanged() {
        task?.cancel()
        let key = query.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else {
            results = []
            resultsQuery = ""
            isSearching = false
            errorText = nil
            return
        }
        if let cached = cache[key.lowercased()] {
            results = cached
            resultsQuery = key
            isSearching = false
            errorText = nil
            return
        }
        isSearching = true
        errorText = nil
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.debounceMilliseconds))
            guard !Task.isCancelled else { return }
            await self?.perform(key)
        }
    }

    /// 清空搜索
    func reset() {
        task?.cancel()
        query = ""
        results = []
        resultsQuery = ""
        isSearching = false
        errorText = nil
    }

    /// 执行一次联想请求:A 股/ETF 与期货/全球指数并行搜索,再合并。
    /// 单一来源失败不影响另一来源;预置期货(铜、煤、日经…)本地即时匹配,离线也可用。
    private func perform(_ key: String) async {
        let router = self.router
        // 纯数字代码(5 位以上)只可能是 A 股,不查期货
        let skipFutures = key.count >= 5 && key.allSatisfy { $0.isASCII && $0.isNumber }
        async let stockTask: Result<[SearchResult], Error> = {
            do { return .success(try await router.search(key).value) } catch { return .failure(error) }
        }()
        async let futureTask: Result<[SearchResult], Error> = {
            if skipFutures { return .success([]) }
            do { return .success(try await router.searchFutures(key).value) } catch { return .failure(error) }
        }()
        let (stockResult, futureResult) = await (stockTask, futureTask)
        guard !Task.isCancelled else { return }

        let local = skipFutures ? [] : FuturesCatalog.localSearch(key)
        var stocks: [SearchResult] = []
        var remoteFutures: [SearchResult] = []
        var failures = 0
        switch stockResult { case .success(let r): stocks = r; case .failure: failures += 1 }
        switch futureResult { case .success(let r): remoteFutures = r; case .failure: failures += 1 }

        if failures == 2 && local.isEmpty {
            results = []
            errorText = "搜索失败,请稍后重试"
        } else {
            // 命中预置期货关键词(如"铜")时期货优先,否则 A 股优先
            let futures = Self.rank(local + remoteFutures, query: key)
            let merged = local.isEmpty ? Self.rank(stocks, query: key) + futures : futures + Self.rank(stocks, query: key)
            var seen = Set<StockSymbol>()
            let unique = merged.filter { seen.insert($0.symbol).inserted }
            cache[key.lowercased()] = unique
            results = unique
            resultsQuery = key
            errorText = nil
        }
        isSearching = false
    }

    /// 结果去重与排序:代码完全匹配 > 名称/拼音前缀 > 其他,同级保持数据源顺序
    /// - Parameters:
    ///   - results: 原始结果
    ///   - query: 关键字
    nonisolated static func rank(_ results: [SearchResult], query: String) -> [SearchResult] {
        let key = query.trimmingCharacters(in: .whitespaces)
        let upper = key.uppercased()
        var seen = Set<StockSymbol>()
        let unique = results.filter { seen.insert($0.symbol).inserted }
        func weight(_ r: SearchResult) -> Int {
            if r.symbol.displayCode.caseInsensitiveCompare(key) == .orderedSame { return 0 }
            if r.name.hasPrefix(key) || r.pinyin.hasPrefix(upper) { return 1 }
            if r.symbol.displayCode.lowercased().hasPrefix(key.lowercased()) { return 2 }
            return 3
        }
        return unique.enumerated()
            .sorted { (weight($0.element), $0.offset) < (weight($1.element), $1.offset) }
            .map(\.element)
    }
}
