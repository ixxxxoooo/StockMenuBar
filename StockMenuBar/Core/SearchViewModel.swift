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

    /// 执行一次联想请求
    private func perform(_ key: String) async {
        do {
            let routed = try await router.search(key)
            guard !Task.isCancelled else { return }
            let ranked = Self.rank(routed.value, query: key)
            cache[key.lowercased()] = ranked
            results = ranked
            resultsQuery = key
            errorText = nil
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            results = []
            errorText = "搜索失败,请稍后重试"
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
            if r.symbol.code == key { return 0 }
            if r.name.hasPrefix(key) || r.pinyin.hasPrefix(upper) { return 1 }
            if r.symbol.code.hasPrefix(key) { return 2 }
            return 3
        }
        return unique.enumerated()
            .sorted { (weight($0.element), $0.offset) < (weight($1.element), $1.offset) }
            .map(\.element)
    }
}
