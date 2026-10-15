//
//  QuoteStore.swift
//  StockMenuBar
//
//  行情单一数据源:一次批量轮询同时驱动菜单栏、Popover、主面板与悬浮窗。
//  每只证券对应一个独立的 QuoteTicker,界面只订阅自己关心的那一只,单只更新只重绘对应行。
//  @author ixxxxoooo
//

import Foundation
import Observation

/// 数据健康状态
enum DataHealth: Sendable, Equatable {
    /// 数据新鲜
    case ok
    /// 请求失败,展示的是上一次有效数据
    case stale
    /// 尚无任何有效数据
    case offline
}

/// 刷新原因
enum RefreshReason: Sendable {
    case launch, timer, manual, wake
}

/// 单只证券的行情容器(细粒度观察)
@MainActor
@Observable
final class QuoteTicker {
    let symbol: StockSymbol
    private(set) var quote: Quote?
    /// 每次价格变化自增,界面据此触发闪色动画
    private(set) var flashToken = 0
    /// 最近一次价格变化方向
    private(set) var flashTrend: Trend = .flat

    init(symbol: StockSymbol) { self.symbol = symbol }

    /// 应用新行情;价格变化时更新闪色标记
    func apply(_ new: Quote) {
        if let old = quote, old.price != new.price {
            flashTrend = new.price > old.price ? .up : .down
            flashToken += 1
        }
        if quote != new { quote = new }
    }
}

@MainActor
@Observable
final class QuoteStore {
    private(set) var lastUpdate: Date?
    private(set) var health: DataHealth = .offline
    private(set) var activeSource: ProviderID?
    private(set) var isRefreshing = false
    private(set) var lastError: String?
    /// 刷新间隔文案(如 3s / 1min / 休市),由调度器写入
    private(set) var intervalLabel = "—"
    /// 数据兜底:交易时段内行情时间戳不是今天,则记为当天休市(处理节假日表缺失)
    private(set) var marketClosedDay: String?

    @ObservationIgnored let router: ProviderRouter
    @ObservationIgnored let clock: TradingClock
    @ObservationIgnored let power: PowerStateMonitor
    @ObservationIgnored var symbolsProvider: @MainActor () -> [StockSymbol] = { [] }

    @ObservationIgnored private var tickers: [StockSymbol: QuoteTicker] = [:]
    @ObservationIgnored private var lastAttempt: Date = .distantPast
    @ObservationIgnored private var refreshInflight: Task<Void, Never>?
    @ObservationIgnored private var minuteCache: [StockSymbol: (series: MinuteSeries, fetchedAt: Date)] = [:]
    @ObservationIgnored private var minuteInflight: [StockSymbol: Task<MinuteSeries?, Never>] = [:]

    /// - Parameters:
    ///   - router: 高可用路由
    ///   - clock: 交易时钟
    ///   - power: 休眠感知
    init(router: ProviderRouter, clock: TradingClock, power: PowerStateMonitor) {
        self.router = router
        self.clock = clock
        self.power = power
    }

    // MARK: - 状态查询

    /// 当前是否被系统状态暂停
    var isSuspended: Bool { power.isSuspended }

    /// 当前市场阶段
    var currentPhase: MarketPhase { clock.phase(at: Date()) }

    /// 今天是否已被判定为休市(数据兜底)
    var isMarketClosedToday: Bool { marketClosedDay == ChinaTime.dayString(Date()) }

    /// 获取(必要时创建)某只证券的行情容器
    func ticker(for symbol: StockSymbol) -> QuoteTicker {
        if let t = tickers[symbol] { return t }
        let t = QuoteTicker(symbol: symbol)
        tickers[symbol] = t
        return t
    }

    /// 便捷读取最新行情
    func quote(for symbol: StockSymbol) -> Quote? { ticker(for: symbol).quote }

    /// 更新刷新间隔文案(调度器调用)
    func setIntervalLabel(_ label: String) {
        if intervalLabel != label { intervalLabel = label }
    }

    // MARK: - 实时行情刷新

    /// 刷新全部关注证券的行情(单次批量请求)
    /// - Parameter reason: 刷新原因;手动刷新带 1.5 秒节流
    func refresh(reason: RefreshReason) async {
        guard !power.isSuspended else { return }
        // 已有请求在途:复用它,不重复发请求
        if let running = refreshInflight {
            await running.value
            return
        }
        let now = Date()
        if reason == .manual, now.timeIntervalSince(lastAttempt) < 1.5 { return }
        let symbols = symbolsProvider()
        guard !symbols.isEmpty else { return }

        isRefreshing = true
        lastAttempt = now
        // 请求放进独立 Task:调度循环被 reschedule 取消时,不会连带取消在途请求
        let task = Task<Void, Never> { @MainActor [weak self] in
            if let self { await self.performRefresh(symbols) }
        }
        refreshInflight = task
        await task.value
        refreshInflight = nil
        isRefreshing = false
    }

    /// 实际发起一次批量请求并写入结果
    private func performRefresh(_ symbols: [StockSymbol]) async {
        do {
            let result = try await router.quotes(for: symbols)
            apply(result.value, from: result.provider)
        } catch {
            if error is CancellationError { return }
            lastError = error.localizedDescription
            health = lastUpdate == nil ? .offline : .stale
        }
    }

    /// 写入行情并更新健康状态
    private func apply(_ quotes: [Quote], from provider: ProviderID) {
        for q in quotes { ticker(for: q.symbol).apply(q) }
        lastUpdate = Date()
        activeSource = provider
        health = .ok
        lastError = nil
        detectClosedDay(quotes)
    }

    /// 休市日兜底识别:交易时段内(9:35 后)全部行情时间戳都不是今天 → 判定今天休市
    private func detectClosedDay(_ quotes: [Quote]) {
        let now = Date()
        guard clock.phase(at: now) != .closed, ChinaTime.minuteOfDay(now) >= 9 * 60 + 35 else { return }
        let times = quotes.compactMap(\.time)
        guard !times.isEmpty else { return }
        let today = ChinaTime.dayString(now)
        if times.allSatisfy({ !ChinaTime.isSameDay($0, now) }) {
            marketClosedDay = today
        } else if marketClosedDay == today {
            marketClosedDay = nil
        }
    }

    // MARK: - 分时数据

    /// 获取当日分时(带缓存与并发去重)
    /// - Parameters:
    ///   - symbol: 证券
    ///   - maxAge: 缓存有效期(秒);默认交易时段 8 秒,休市 10 分钟
    /// - Returns: 分时序列;失败时返回旧缓存(可能为 nil)
    func minuteSeries(for symbol: StockSymbol, maxAge: TimeInterval? = nil) async -> MinuteSeries? {
        let ttl = maxAge ?? (currentPhase == .closed ? 600 : 8)
        let cached = minuteCache[symbol]
        if let cached, Date().timeIntervalSince(cached.fetchedAt) < ttl { return cached.series }
        if power.isSuspended { return cached?.series }
        if let running = minuteInflight[symbol] { return await running.value ?? cached?.series }

        let router = self.router
        let task = Task<MinuteSeries?, Never> {
            try? await router.minute(for: symbol).value
        }
        minuteInflight[symbol] = task
        let series = await task.value
        minuteInflight[symbol] = nil
        if let series {
            minuteCache[symbol] = (series, Date())
            return series
        }
        return cached?.series
    }
}

/// 分时数据加载器:界面持有,按市场阶段自动轮询(交易中 10 秒、午休 1 分钟、休市只取一次)
@MainActor
@Observable
final class MinuteLoader {
    private(set) var series: MinuteSeries?
    private(set) var isLoading = false
    private(set) var failed = false

    @ObservationIgnored private let store: QuoteStore

    init(store: QuoteStore) { self.store = store }

    /// 持续加载某只证券的分时,随 Task 取消而结束
    /// - Parameters:
    ///   - symbol: 证券
    ///   - tradingInterval: 交易时段刷新间隔(秒)
    func run(symbol: StockSymbol, tradingInterval: TimeInterval = 10) async {
        if series?.symbol != symbol { series = nil }
        isLoading = series == nil
        failed = false
        while !Task.isCancelled {
            if !store.isSuspended {
                if let s = await store.minuteSeries(for: symbol) {
                    series = s
                    failed = false
                } else if series == nil {
                    failed = true
                }
            }
            isLoading = false
            let phase = store.currentPhase
            if phase == .closed && series != nil { return }
            let wait: TimeInterval = phase == .trading ? tradingInterval : (phase == .lunch ? 60 : 30)
            try? await Task.sleep(for: .seconds(wait))
        }
    }
}
