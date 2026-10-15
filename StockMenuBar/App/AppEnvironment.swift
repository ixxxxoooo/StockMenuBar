//
//  AppEnvironment.swift
//  StockMenuBar
//
//  应用级依赖装配与全局状态:所有界面共享同一套数据源、自选与偏好。
//  @author ixxxxoooo
//

import Foundation
import Observation

/// 主面板侧边栏选择
enum MainSelection: Hashable {
    case item(UUID)
    case settings
}

/// 主面板导航状态(外部可通过它直接跳转到设置页或某只股票)
@MainActor
@Observable
final class MainNavigationModel {
    var selection: MainSelection?
}

/// 可观察的界面级临时状态
@MainActor
@Observable
final class UIState {
    /// 老板键:一键隐藏所有界面
    var bossHidden = false
}

@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    let ui = UIState()
    let prefs: Preferences
    let watchlist: WatchlistStore
    let router: ProviderRouter
    let power: PowerStateMonitor
    let clock: TradingClock
    let quotes: QuoteStore
    let search: SearchViewModel
    let updates: UpdateManager
    let nav = MainNavigationModel()
    private(set) var scheduler: RefreshScheduler!

    /// Popover 是否可见
    var popoverVisible = false
    /// 主面板是否可见
    var mainWindowVisible = false

    // 由 AppDelegate 注入的界面动作
    var openMainWindow: (@MainActor (_ settings: Bool) -> Void)?
    var showPopoverClose: (@MainActor () -> Void)?
    var toggleFloatingWindow: (@MainActor () -> Void)?

    private init() {
        let prefs = Preferences()
        let watchlist = WatchlistStore()
        let router = ProviderRouter.makeDefault()
        let power = PowerStateMonitor()
        let clock = TradingClock()
        let quotes = QuoteStore(router: router, clock: clock, power: power)
        self.prefs = prefs
        self.watchlist = watchlist
        self.router = router
        self.power = power
        self.clock = clock
        self.quotes = quotes
        self.search = SearchViewModel(router: router)
        self.updates = UpdateManager(prefs: prefs)

        quotes.symbolsProvider = { [weak self] in self?.trackedSymbols() ?? [] }
        scheduler = RefreshScheduler(store: quotes, prefs: prefs, hasConsumers: { [weak self] in self?.hasConsumers ?? false })
        power.onChange = { [weak self] suspended in
            // 恢复时立即重新调度并补一次刷新;暂停时调度循环会进入空闲
            self?.scheduler.reschedule()
            _ = suspended
        }
    }

    // MARK: - 派生状态

    /// 菜单栏固定的标的(过滤掉已不在自选中的)
    var pinnedSymbols: [StockSymbol] {
        prefs.pinnedSymbols.compactMap(StockSymbol.init(full:)).filter { watchlist.containsAnywhere($0) }
    }

    /// 悬浮窗监控的标的;未显式选择时取当前分组前 6 只
    var floatingSymbols: [StockSymbol] {
        let chosen = prefs.floatingSymbols.compactMap(StockSymbol.init(full:)).filter { watchlist.containsAnywhere($0) }
        if !chosen.isEmpty { return chosen }
        return (watchlist.selectedGroup?.items.prefix(6).map(\.symbol)) ?? []
    }

    /// 全部需要轮询的证券(去重)
    func trackedSymbols() -> [StockSymbol] { watchlist.allSymbols }

    /// 当前是否有界面需要行情;全部隐藏且菜单栏没有固定标的时暂停请求
    var hasConsumers: Bool {
        prefs.floatingVisible || popoverVisible || mainWindowVisible || !pinnedSymbols.isEmpty
    }

    // MARK: - 动作

    /// 菜单「检查更新…」:打开设置页并立即检查;已发现新版本时只展示结果
    func checkForUpdates() {
        openMainWindow?(true)
        if updates.availableRelease == nil && !updates.isBusy {
            Task { await updates.check(userInitiated: true) }
        }
    }

    /// 更新菜单项标题:发现新版本时直接提示版本号
    var updateMenuTitle: String {
        if let release = updates.availableRelease { return "发现新版本 \(release.version)…" }
        return "检查更新…"
    }

    /// 界面显隐变化后重新评估调度
    func consumersChanged() { scheduler.reschedule() }

    /// 加入自选并立即补一次行情
    /// - Returns: 是否新增成功
    @discardableResult
    func addToWatchlist(_ result: SearchResult, groupID: UUID? = nil) -> Bool {
        let added = watchlist.add(result, to: groupID)
        if added { scheduler.refreshOnDemand() }
        return added
    }

    /// 移除自选;若该证券已不在任何分组,同步清理菜单栏固定与悬浮窗列表
    func removeFromWatchlist(_ item: WatchItem) {
        watchlist.remove(itemID: item.id)
        if !watchlist.containsAnywhere(item.symbol) { prefs.forget(item.symbol) }
        scheduler.reschedule()
    }
}
