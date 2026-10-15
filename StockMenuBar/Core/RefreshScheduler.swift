//
//  RefreshScheduler.swift
//  StockMenuBar
//
//  智能刷新调度:
//  - 交易时间(9:15-11:30、13:00-15:05)按用户设定秒级轮询
//  - 午休(11:30-13:00)每分钟一次
//  - 盘后与夜间不轮询,仅在界面唤起时单次请求
//  - 睡眠/锁屏/屏保/无界面可见时暂停全部请求
//  @author ixxxxoooo
//

import Foundation

/// 调度决策
enum RefreshDecision: Equatable, Sendable {
    /// 立即刷新,并在 n 秒后再次决策
    case poll(TimeInterval)
    /// 不发请求,n 秒后(或被 reschedule 唤醒时)再次决策
    case idle(TimeInterval)
}

@MainActor
final class RefreshScheduler {
    private let store: QuoteStore
    private let prefs: Preferences
    private let hasConsumers: @MainActor () -> Bool
    private var loopTask: Task<Void, Never>?

    /// - Parameters:
    ///   - store: 行情数据源
    ///   - prefs: 偏好设置(刷新间隔)
    ///   - hasConsumers: 当前是否有界面需要行情(菜单栏固定了标的、Popover/主面板/悬浮窗可见)
    init(store: QuoteStore, prefs: Preferences, hasConsumers: @escaping @MainActor () -> Bool) {
        self.store = store
        self.prefs = prefs
        self.hasConsumers = hasConsumers
    }

    /// 纯函数决策,便于单元测试
    /// - Parameters:
    ///   - now: 当前时间
    ///   - clock: 交易时钟
    ///   - suspended: 是否被系统状态暂停
    ///   - hasConsumers: 是否有界面需要行情
    ///   - marketClosedToday: 是否被数据兜底判定今日休市
    ///   - interval: 用户设定的交易时段间隔
    ///   - conserving: 低电量/高热,间隔翻倍
    nonisolated static func decide(now: Date, clock: TradingClock, suspended: Bool, hasConsumers: Bool,
                       marketClosedToday: Bool, interval: Int, conserving: Bool) -> RefreshDecision {
        if suspended || !hasConsumers { return .idle(600) }
        switch clock.phase(at: now) {
        case .trading:
            if marketClosedToday { return .poll(300) }
            return .poll(Double(interval) * (conserving ? 2 : 1))
        case .lunch:
            if marketClosedToday { return .idle(min(clock.secondsToNextBoundary(from: now) + 1, 1800)) }
            return .poll(60)
        case .closed:
            return .idle(min(max(clock.secondsToNextBoundary(from: now) + 1, 1), 1800))
        }
    }

    /// 启动调度:先立即取一次最新数据(盘后也展示收盘价),再进入循环
    func start() {
        reschedule(initialRefresh: true)
    }

    /// 停止调度
    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    /// 状态变化(休眠恢复、界面显隐、偏好变更)后重新调度
    /// - Parameter initialRefresh: 是否先无条件刷新一次(用于启动)
    func reschedule(initialRefresh: Bool = false) {
        loopTask?.cancel()
        loopTask = Task { @MainActor [weak self] in
            if initialRefresh { await self?.store.refresh(reason: .launch) }
            await self?.runLoop()
        }
    }

    /// 界面唤起时的单次刷新(盘后唯一的请求来源),带节流
    func refreshOnDemand() {
        Task { @MainActor [weak self] in await self?.store.refresh(reason: .manual) }
    }

    private func runLoop() async {
        while !Task.isCancelled {
            let decision = Self.decide(
                now: Date(), clock: store.clock, suspended: store.isSuspended, hasConsumers: hasConsumers(),
                marketClosedToday: store.isMarketClosedToday, interval: prefs.refreshInterval,
                conserving: store.power.isConserving
            )
            switch decision {
            case .poll(let seconds):
                store.setIntervalLabel(seconds >= 60 ? "\(Int(seconds / 60))min" : "\(Int(seconds))s")
                await store.refresh(reason: .timer)
                if Task.isCancelled { return }
                try? await Task.sleep(for: .seconds(seconds), tolerance: .milliseconds(Int(seconds * 100)))
            case .idle(let seconds):
                store.setIntervalLabel(store.isSuspended ? "已暂停" : (store.currentPhase == .closed || store.isMarketClosedToday ? "休市" : "待命"))
                try? await Task.sleep(for: .seconds(seconds), tolerance: .seconds(1))
            }
        }
    }
}
