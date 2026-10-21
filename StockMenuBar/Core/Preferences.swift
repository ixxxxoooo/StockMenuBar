//
//  Preferences.swift
//  StockMenuBar
//
//  用户偏好设置:基于 UserDefaults 持久化,@Observable 驱动界面刷新。
//  @author ixxxxoooo
//

import Foundation
import Observation
import ServiceManagement

/// 悬浮窗形态
enum FloatingStyle: String, CaseIterable, Sendable, Identifiable {
    case capsule, list, card

    var id: String { rawValue }
    var title: String {
        switch self {
        case .capsule: return "胶囊"
        case .list: return "迷你列表"
        case .card: return "卡片"
        }
    }
}

/// 菜单栏标识显示方式
enum MenuBarLabelMode: String, CaseIterable, Sendable, Identifiable {
    case name, code

    var id: String { rawValue }
    var title: String { self == .name ? "股票名称" : "股票代码" }
}

@MainActor
@Observable
final class Preferences {
    /// 允许的刷新间隔(秒)
    nonisolated static let allowedIntervals = [3, 5, 10]
    /// 菜单栏最多固定的标的数
    nonisolated static let maxPinned = 2

    @ObservationIgnored private let defaults: UserDefaults

    /// 交易时段刷新间隔(秒):3/5/10
    var refreshInterval: Int { didSet { defaults.set(refreshInterval, forKey: "refreshInterval") } }
    /// 红涨绿跌(true)或绿涨红跌(false)
    var redUp: Bool { didSet { defaults.set(redUp, forKey: "redUp") } }
    /// 摸鱼模式:低饱和配色、关闭价格闪色(与机器/场景相关,不进入备份)
    var stealthMode: Bool { didSet { defaults.set(stealthMode, forKey: "stealthMode"); Theme.stealth = stealthMode } }
    /// 菜单栏标识:名称/代码
    var menuBarLabel: MenuBarLabelMode { didSet { defaults.set(menuBarLabel.rawValue, forKey: "menuBarLabel") } }
    /// 菜单栏紧凑模式:只显示价格与涨跌幅
    var menuBarCompact: Bool { didSet { defaults.set(menuBarCompact, forKey: "menuBarCompact") } }
    /// 菜单栏轮播:固定多只时每 5 秒轮换显示一只
    var menuBarRotate: Bool { didSet { defaults.set(menuBarRotate, forKey: "menuBarRotate") } }
    /// 菜单栏固定的标的(完整代码)
    var pinnedSymbols: [String] { didSet { defaults.set(pinnedSymbols, forKey: "pinnedSymbols") } }
    /// Popover 极简模式:只显示文字与涨跌幅块
    var popoverMinimal: Bool { didSet { defaults.set(popoverMinimal, forKey: "popoverMinimal") } }

    /// 悬浮窗是否显示
    var floatingVisible: Bool { didSet { defaults.set(floatingVisible, forKey: "floatingVisible") } }
    /// 悬浮窗形态
    var floatingStyle: FloatingStyle { didSet { defaults.set(floatingStyle.rawValue, forKey: "floatingStyle") } }
    /// 悬浮窗监控的标的(完整代码)
    var floatingSymbols: [String] { didSet { defaults.set(floatingSymbols, forKey: "floatingSymbols") } }
    /// 悬浮窗当前分类:nil = 默认(手动勾选,否则跟随主面板分组);"all" = 全部自选;其余为分组 UUID 字符串
    var floatingGroupID: String? { didSet { defaults.set(floatingGroupID, forKey: "floatingGroupID") } }
    /// 悬浮窗背景不透明度 0.3~1.0
    var floatingOpacity: Double { didSet { defaults.set(floatingOpacity, forKey: "floatingOpacity") } }
    /// 鼠标移出后窗口淡化
    var floatingFade: Bool { didSet { defaults.set(floatingFade, forKey: "floatingFade") } }
    /// 穿透锁定:点击穿过悬浮窗
    var floatingClickThrough: Bool { didSet { defaults.set(floatingClickThrough, forKey: "floatingClickThrough") } }

    /// 是否自动检查更新
    var autoCheckUpdates: Bool { didSet { defaults.set(autoCheckUpdates, forKey: "autoCheckUpdates") } }
    /// 上次检查更新的时间
    var lastUpdateCheck: Date? { didSet { defaults.set(lastUpdateCheck, forKey: "lastUpdateCheck") } }
    /// 用户选择跳过的版本号
    var skippedUpdateVersion: String? { didSet { defaults.set(skippedUpdateVersion, forKey: "skippedUpdateVersion") } }

    /// 开机自启状态(来自系统登录项)
    private(set) var launchAtLogin: Bool
    /// 开机自启最近一次错误
    private(set) var launchError: String?

    /// - Parameter defaults: 存储,测试可注入
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let interval = defaults.integer(forKey: "refreshInterval")
        refreshInterval = Preferences.allowedIntervals.contains(interval) ? interval : 3
        redUp = defaults.object(forKey: "redUp") as? Bool ?? true
        stealthMode = defaults.bool(forKey: "stealthMode")
        menuBarLabel = MenuBarLabelMode(rawValue: defaults.string(forKey: "menuBarLabel") ?? "") ?? .name
        menuBarCompact = defaults.bool(forKey: "menuBarCompact")
        menuBarRotate = defaults.bool(forKey: "menuBarRotate")
        // 首次启动默认把上证指数固定在菜单栏,安装后立刻能看到行情
        pinnedSymbols = defaults.stringArray(forKey: "pinnedSymbols") ?? ["sh000001"]
        popoverMinimal = defaults.bool(forKey: "popoverMinimal")
        floatingVisible = defaults.bool(forKey: "floatingVisible")
        floatingStyle = FloatingStyle(rawValue: defaults.string(forKey: "floatingStyle") ?? "") ?? .list
        floatingSymbols = defaults.stringArray(forKey: "floatingSymbols") ?? []
        floatingGroupID = defaults.string(forKey: "floatingGroupID")
        let opacity = defaults.object(forKey: "floatingOpacity") as? Double ?? 0.85
        floatingOpacity = min(max(opacity, 0.3), 1.0)
        floatingFade = defaults.object(forKey: "floatingFade") as? Bool ?? true
        floatingClickThrough = defaults.bool(forKey: "floatingClickThrough")
        autoCheckUpdates = defaults.object(forKey: "autoCheckUpdates") as? Bool ?? true
        lastUpdateCheck = defaults.object(forKey: "lastUpdateCheck") as? Date
        skippedUpdateVersion = defaults.string(forKey: "skippedUpdateVersion")
        launchAtLogin = SMAppService.mainApp.status == .enabled
        Theme.stealth = stealthMode
    }

    // MARK: - 开机自启

    /// 设置开机自启,通过 SMAppService 注册/注销登录项
    /// - Parameter enabled: 是否启用
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchError = nil
        } catch {
            launchError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - 菜单栏固定 / 悬浮窗标的

    /// 是否已固定在菜单栏
    func isPinned(_ symbol: StockSymbol) -> Bool { pinnedSymbols.contains(symbol.full) }

    /// 切换菜单栏固定状态;超过上限时挤掉最早固定的标的
    func togglePinned(_ symbol: StockSymbol) {
        if let idx = pinnedSymbols.firstIndex(of: symbol.full) {
            pinnedSymbols.remove(at: idx)
        } else {
            pinnedSymbols.append(symbol.full)
            while pinnedSymbols.count > Self.maxPinned { pinnedSymbols.removeFirst() }
        }
    }

    /// 是否在悬浮窗监控列表中
    func isInFloating(_ symbol: StockSymbol) -> Bool { floatingSymbols.contains(symbol.full) }

    /// 切换悬浮窗监控状态
    func toggleFloating(_ symbol: StockSymbol) {
        if let idx = floatingSymbols.firstIndex(of: symbol.full) {
            floatingSymbols.remove(at: idx)
        } else {
            floatingSymbols.append(symbol.full)
        }
    }

    /// 从固定与悬浮列表中移除某只证券(自选被删除时调用)
    func forget(_ symbol: StockSymbol) {
        pinnedSymbols.removeAll { $0 == symbol.full }
        floatingSymbols.removeAll { $0 == symbol.full }
    }

    // MARK: - 悬浮窗位置

    /// 读取悬浮窗上次位置(左上角锚点)
    func loadFloatingOrigin() -> (x: Double, y: Double)? {
        guard let x = defaults.object(forKey: "floatingOriginX") as? Double,
              let y = defaults.object(forKey: "floatingOriginY") as? Double else { return nil }
        return (x, y)
    }

    /// 保存悬浮窗位置
    func saveFloatingOrigin(x: Double, y: Double) {
        defaults.set(x, forKey: "floatingOriginX")
        defaults.set(y, forKey: "floatingOriginY")
    }
}
