//
//  ProviderRouter.swift
//  StockMenuBar
//
//  高可用路由:多源故障转移 + 熔断 + 健康排序 + 对冲请求 + 数据校验。
//  @author ixxxxoooo
//

import Foundation

/// 路由结果:带数据源与耗时信息
struct RoutedResult<T: Sendable>: Sendable {
    let value: T
    let provider: ProviderID
    let latency: TimeInterval
}

/// 数据源运行状态(用于设置页展示)
struct ProviderStatus: Sendable, Identifiable {
    let id: ProviderID
    let ewmaLatency: TimeInterval
    let successRate: Double
    let breaker: CircuitBreaker.State
    let lastError: String?
    let lastSuccess: Date?
    let totalRequests: Int
}

/// 路由配置
struct RouterConfig: Sendable {
    /// 对冲延迟:首选源超过该时间未返回,并发请求下一个源
    var hedgeDelay: TimeInterval = 1.2
    var failureThreshold: Int = 3
    var openDuration: TimeInterval = 30
    /// 各源初始延迟先验(秒),决定冷启动时的优先顺序
    var latencyPrior: [ProviderID: TimeInterval] = [.tencent: 0.30, .sina: 0.40, .eastmoney: 0.50]

    static let `default` = RouterConfig()
}

actor ProviderRouter {
    private struct Stats {
        var ewmaLatency: TimeInterval
        var successRate: Double = 1.0
        var breaker: CircuitBreaker
        var lastError: String?
        var lastSuccess: Date?
        var total = 0
    }

    private enum Event<T: Sendable>: Sendable {
        case hedgeTimer
        case finished(ProviderID, Result<T, Error>, TimeInterval)
    }

    private let providers: [ProviderID: any QuoteProvider]
    private let order: [ProviderID]
    private let config: RouterConfig
    private let clock: @Sendable () -> Date
    private var stats: [ProviderID: Stats] = [:]

    /// - Parameters:
    ///   - providers: 数据源列表(顺序即默认优先级)
    ///   - config: 路由配置
    ///   - clock: 时间源,测试可注入
    init(providers: [any QuoteProvider], config: RouterConfig = .default, clock: @escaping @Sendable () -> Date = { Date() }) {
        var map: [ProviderID: any QuoteProvider] = [:]
        var ids: [ProviderID] = []
        for p in providers {
            map[p.id] = p
            ids.append(p.id)
        }
        self.providers = map
        self.order = ids
        self.config = config
        self.clock = clock
        for id in ids {
            stats[id] = Stats(
                ewmaLatency: config.latencyPrior[id] ?? 0.5,
                breaker: CircuitBreaker(failureThreshold: config.failureThreshold, openDuration: config.openDuration)
            )
        }
    }

    /// 默认装配:腾讯、新浪、东财三源
    static func makeDefault() -> ProviderRouter {
        let http = URLSessionHTTPClient()
        let providers: [any QuoteProvider] = [
            TencentProvider(http: http),
            SinaProvider(http: http),
            EastmoneyProvider(http: http)
        ]
        return ProviderRouter(providers: FaultInjection.apply(to: providers))
    }

    // MARK: - 对外接口

    /// 批量获取行情。A 股与期货分别路由(各自有不同的可用数据源集合),再合并结果。
    /// 结果会过滤无效行情;请求了证券却一条有效数据都没有时视为该源失败。
    /// 任一类别成功即返回成功(另一类别失败时保留旧数据),全部失败才抛错。
    func quotes(for symbols: [StockSymbol]) async throws -> RoutedResult<[Quote]> {
        let stocks = symbols.filter { !$0.isFuture }
        let futures = symbols.filter(\.isFuture)
        if futures.isEmpty { return try await routeQuotes(stocks, futures: false) }
        if stocks.isEmpty { return try await routeQuotes(futures, futures: true) }

        async let stockTask = Self.capture { try await self.routeQuotes(stocks, futures: false) }
        async let futureTask = Self.capture { try await self.routeQuotes(futures, futures: true) }
        let (stockResult, futureResult) = await (stockTask, futureTask)
        switch (stockResult, futureResult) {
        case (.success(let a), .success(let b)):
            return RoutedResult(value: a.value + b.value, provider: a.provider, latency: max(a.latency, b.latency))
        case (.success(let a), .failure):
            return a
        case (.failure, .success(let b)):
            return b
        case (.failure(let error), .failure):
            throw error
        }
    }

    /// 把抛错的异步操作包装为 Result
    private static func capture<T: Sendable>(_ work: @Sendable () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await work()) } catch { return .failure(error) }
    }

    /// 单一类别(A 股或期货)的行情路由
    private func routeQuotes(_ symbols: [StockSymbol], futures: Bool) async throws -> RoutedResult<[Quote]> {
        var result = try await routeQuoteBatch(symbols, futures: futures, excluding: [])
        // 期货各数据源覆盖的品种不同:首选源缺失的品种,交给其余数据源补一次(尽力而为,失败忽略)
        if futures {
            let got = Set(result.value.map(\.symbol))
            let missing = symbols.filter { !got.contains($0) }
            if !missing.isEmpty,
               let extra = try? await routeQuoteBatch(missing, futures: true, excluding: [result.provider]) {
                result = RoutedResult(value: result.value + extra.value, provider: result.provider, latency: result.latency)
            }
        }
        return result
    }

    /// 一批行情的单次路由
    private func routeQuoteBatch(_ symbols: [StockSymbol], futures: Bool, excluding: Set<ProviderID>) async throws -> RoutedResult<[Quote]> {
        let requestCount = symbols.count
        let capability: ProviderCapability = futures ? .futuresQuotes : .quotes
        return try await execute(capability: capability,
                                 excluding: excluding,
                                 coverage: { provider in Self.coverage(of: provider, capability: capability, symbols: symbols) },
                                 validate: { (quotes: [Quote]) in requestCount == 0 || quotes.contains(where: { $0.isValid }) },
                                 operation: { provider in
            try await provider.fetchQuotes(symbols).filter { $0.isValid }
        })
    }

    /// 获取当日分时
    func minute(for symbol: StockSymbol) async throws -> RoutedResult<MinuteSeries> {
        let capability: ProviderCapability = symbol.isFuture ? .futuresMinute : .minute
        return try await execute(capability: capability,
                                 coverage: { provider in Self.coverage(of: provider, capability: capability, symbols: [symbol]) },
                                 validate: { (s: MinuteSeries) in !s.bars.isEmpty && s.prevClose > 0 },
                                 operation: { provider in try await provider.fetchMinute(symbol: symbol) })
    }

    /// 搜索联想(空结果也视为成功,不触发转移)
    func search(_ keyword: String) async throws -> RoutedResult<[SearchResult]> {
        try await execute(capability: .search,
                          coverage: { Self.coverage(of: $0, capability: .search, symbols: []) },
                          validate: { (_: [SearchResult]) in true },
                          operation: { provider in try await provider.search(keyword: keyword) })
    }

    /// 搜索期货与全球指数
    func searchFutures(_ keyword: String) async throws -> RoutedResult<[SearchResult]> {
        try await execute(capability: .futuresSearch,
                          coverage: { Self.coverage(of: $0, capability: .futuresSearch, symbols: []) },
                          validate: { (_: [SearchResult]) in true },
                          operation: { provider in try await provider.searchFutures(keyword: keyword) })
    }

    /// 数据源对一组标的的覆盖程度
    enum Coverage: Int, Sendable { case none = 0, partial = 1, full = 2 }

    /// 计算覆盖度:不具备能力为 none;能服务全部标的为 full;只能服务其中一部分为 partial
    nonisolated static func coverage(of provider: any QuoteProvider, capability: ProviderCapability, symbols: [StockSymbol]) -> Coverage {
        guard provider.capabilities.contains(capability) else { return .none }
        guard !symbols.isEmpty else { return .full }
        let served = symbols.filter { provider.canServe(capability, symbol: $0) }.count
        if served == symbols.count { return .full }
        return served == 0 ? .none : .partial
    }

    /// 各数据源当前状态快照
    func statuses() -> [ProviderStatus] {
        order.compactMap { id in
            guard let s = stats[id] else { return nil }
            return ProviderStatus(id: id, ewmaLatency: s.ewmaLatency, successRate: s.successRate, breaker: s.breaker.state,
                                  lastError: s.lastError, lastSuccess: s.lastSuccess, totalRequests: s.total)
        }
    }

    // MARK: - 核心调度

    /// 候选源排序:先按熔断可用性筛选,再按 延迟 × (1 + 5 × 失败率) 升序。
    /// 全部熔断时「失败放行」(fail-open),仍按评分尝试,保证最大可用性。
    /// 覆盖全部标的的数据源优先于只覆盖部分标的的数据源(后者仅作兜底)
    private func rankedCandidates(excluding: Set<ProviderID> = [], coverage: @Sendable (any QuoteProvider) -> Coverage) -> [ProviderID] {
        let now = clock()
        var level: [ProviderID: Coverage] = [:]
        for id in order where !excluding.contains(id) { if let p = providers[id] { level[id] = coverage(p) } }
        let capable = order.filter { (level[$0] ?? .none) != .none }
        let available = capable.filter { stats[$0]?.breaker.isAvailable(now: now) == true }
        let pool = available.isEmpty ? capable : available
        return pool.sorted { a, b in
            let la = level[a]?.rawValue ?? 0, lb = level[b]?.rawValue ?? 0
            if la != lb { return la > lb }
            return score(a) < score(b)
        }
    }

    private func score(_ id: ProviderID) -> Double {
        guard let s = stats[id] else { return .greatestFiniteMagnitude }
        return s.ewmaLatency * (1 + 5 * (1 - s.successRate))
    }

    private func execute<T: Sendable>(
        capability: ProviderCapability,
        excluding: Set<ProviderID> = [],
        coverage: @Sendable (any QuoteProvider) -> Coverage,
        validate: @escaping @Sendable (T) -> Bool,
        operation: @escaping @Sendable (any QuoteProvider) async throws -> T
    ) async throws -> RoutedResult<T> {
        let candidates = rankedCandidates(excluding: excluding, coverage: coverage)
        guard !candidates.isEmpty else { throw ProviderError.unsupported }
        let hedge = config.hedgeDelay
        let providerMap = providers

        var nextIndex = 0
        var running = 0
        var launchNext = true
        var lastError: Error = ProviderError.allSourcesFailed("无可用数据源")

        return try await withThrowingTaskGroup(of: Event<T>.self) { group in
            while true {
                try Task.checkCancellation()
                if launchNext && nextIndex < candidates.count {
                    let id = candidates[nextIndex]
                    nextIndex += 1
                    launchNext = false
                    if let provider = providerMap[id] {
                        stats[id]?.breaker.beginAttempt(now: clock())
                        running += 1
                        group.addTask { await Self.timed(provider, validate: validate, operation: operation) }
                        if nextIndex < candidates.count {
                            group.addTask {
                                try? await Task.sleep(for: .seconds(hedge))
                                return .hedgeTimer
                            }
                        }
                    } else {
                        launchNext = true
                        continue
                    }
                }

                guard let event = try await group.next() else { break }
                switch event {
                case .hedgeTimer:
                    if !Task.isCancelled { launchNext = true }
                case .finished(let id, let result, let latency):
                    running -= 1
                    switch result {
                    case .success(let value):
                        recordSuccess(id, latency: latency)
                        group.cancelAll()
                        return RoutedResult(value: value, provider: id, latency: latency)
                    case .failure(let error):
                        if error is CancellationError { break }
                        recordFailure(id, error: error)
                        lastError = error
                        launchNext = true
                    }
                }
                if running == 0 && nextIndex >= candidates.count { break }
            }
            group.cancelAll()
            throw ProviderError.allSourcesFailed(lastError.localizedDescription)
        }
    }

    /// 执行单个数据源请求并计时、校验(静态方法,避免捕获 actor 自身)
    private static func timed<T: Sendable>(
        _ provider: any QuoteProvider,
        validate: @Sendable (T) -> Bool,
        operation: @Sendable (any QuoteProvider) async throws -> T
    ) async -> Event<T> {
        let start = Date()
        do {
            let value = try await operation(provider)
            let latency = Date().timeIntervalSince(start)
            guard validate(value) else {
                return .finished(provider.id, .failure(ProviderError.invalidData("校验未通过")), latency)
            }
            return .finished(provider.id, .success(value), latency)
        } catch {
            return .finished(provider.id, .failure(error), Date().timeIntervalSince(start))
        }
    }

    // MARK: - 统计

    private func recordSuccess(_ id: ProviderID, latency: TimeInterval) {
        guard var s = stats[id] else { return }
        s.ewmaLatency = s.ewmaLatency * 0.7 + latency * 0.3
        s.successRate = s.successRate * 0.9 + 0.1
        s.breaker.recordSuccess()
        s.lastSuccess = clock()
        s.total += 1
        stats[id] = s
    }

    private func recordFailure(_ id: ProviderID, error: Error) {
        guard var s = stats[id] else { return }
        s.successRate = s.successRate * 0.9
        s.breaker.recordFailure(now: clock())
        s.lastError = error.localizedDescription
        s.total += 1
        stats[id] = s
    }
}
