//
//  PowerStateMonitor.swift
//  StockMenuBar
//
//  休眠感知:系统睡眠/合盖、屏幕睡眠、屏保、锁屏、切换用户时暂停网络请求;
//  低电量模式与高热状态时放大刷新间隔。
//  @author ixxxxoooo
//

import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class PowerStateMonitor {
    /// 导致暂停的原因集合
    enum Reason: Hashable, Sendable {
        case systemSleep, screenSleep, screensaver, screenLocked, sessionInactive
    }

    private(set) var reasons: Set<Reason> = []

    /// 是否应暂停所有网络请求
    var isSuspended: Bool { !reasons.isEmpty }

    /// 是否处于节能状态(低电量模式或高热),此时刷新间隔放大一倍
    var isConserving: Bool {
        let info = ProcessInfo.processInfo
        return info.isLowPowerModeEnabled || info.thermalState == .serious || info.thermalState == .critical
    }

    /// 暂停状态变化回调(恢复时用于立即补一次刷新)
    @ObservationIgnored var onChange: (@MainActor (_ suspended: Bool) -> Void)?

    @ObservationIgnored private var tokens: [(NotificationCenter, NSObjectProtocol)] = []

    init() {}

    /// 开始监听系统状态通知
    func start() {
        guard tokens.isEmpty else { return }
        let ws = NSWorkspace.shared.notificationCenter
        let dist = DistributedNotificationCenter.default()

        observe(ws, NSWorkspace.willSleepNotification, .systemSleep, active: true)
        observe(ws, NSWorkspace.didWakeNotification, .systemSleep, active: false)
        observe(ws, NSWorkspace.screensDidSleepNotification, .screenSleep, active: true)
        observe(ws, NSWorkspace.screensDidWakeNotification, .screenSleep, active: false)
        observe(ws, NSWorkspace.sessionDidResignActiveNotification, .sessionInactive, active: true)
        observe(ws, NSWorkspace.sessionDidBecomeActiveNotification, .sessionInactive, active: false)
        observe(dist, Notification.Name("com.apple.screensaver.didstart"), .screensaver, active: true)
        observe(dist, Notification.Name("com.apple.screensaver.didstop"), .screensaver, active: false)
        observe(dist, Notification.Name("com.apple.screenIsLocked"), .screenLocked, active: true)
        observe(dist, Notification.Name("com.apple.screenIsUnlocked"), .screenLocked, active: false)
    }

    /// 手动设置某个暂停原因(便于测试)
    func set(_ reason: Reason, active: Bool) {
        let before = isSuspended
        if active { reasons.insert(reason) } else { reasons.remove(reason) }
        if before != isSuspended { onChange?(isSuspended) }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ reason: Reason, active: Bool) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.set(reason, active: active) }
        }
        tokens.append((center, token))
    }
}
