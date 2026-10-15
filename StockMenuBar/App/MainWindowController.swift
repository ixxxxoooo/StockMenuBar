//
//  MainWindowController.swift
//  StockMenuBar
//
//  主面板窗口生命周期:独立 NSWindow 承载 SwiftUI 的 NavigationSplitView。
//  @author ixxxxoooo
//

import AppKit
import SwiftUI

@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private let env = AppEnvironment.shared
    private var window: NSWindow?

    /// 主面板当前是否可见
    var isVisible: Bool { window?.isVisible ?? false }

    /// 显示主面板
    /// - Parameter settings: 为 true 时直接跳转到偏好设置
    func show(settings: Bool) {
        if settings { env.nav.selection = .settings }
        let window = ensureWindow()
        // 主面板打开期间转为常规应用:Dock 显示图标、可 Cmd+Tab 切换
        NSApp.setActivationPolicy(.regular)
        AppIconProvider.apply()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        env.mainWindowVisible = true
        env.consumersChanged()
    }

    /// 隐藏主面板(老板键)
    func hide() {
        window?.orderOut(nil)
        env.mainWindowVisible = false
        env.consumersChanged()
        restoreAccessoryPolicy()
    }

    /// 主面板不可见时恢复为菜单栏应用(隐藏 Dock 图标)
    /// 最小化的窗口仍视为"打开",保留 Dock 图标以便还原
    private func restoreAccessoryPolicy() {
        guard !(window?.isVisible ?? false), !(window?.isMiniaturized ?? false) else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    private func ensureWindow() -> NSWindow {
        if let window { return window }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "StockMenuBar"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        let hosting = NSHostingController(rootView: MainView())
        // 窗口尺寸完全由 NSWindow 管理,避免 SwiftUI 内容尺寸变化(折叠侧栏)反向驱动窗口重算布局
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 1080, height: 800))
        window.minSize = NSSize(width: 940, height: 620)
        window.setFrameAutosaveName("StockMenuBarMainWindow")
        if !window.setFrameUsingName("StockMenuBarMainWindow") { window.center() }
        window.delegate = self
        self.window = window
        return window
    }

    func windowWillClose(_ notification: Notification) {
        env.mainWindowVisible = false
        env.consumersChanged()
        // 关闭回调发生在窗口隐藏之前,延后一轮再判断并恢复菜单栏模式
        Task { @MainActor [weak self] in self?.restoreAccessoryPolicy() }
    }

    func windowDidMiniaturize(_ notification: Notification) {
        env.mainWindowVisible = false
        env.consumersChanged()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        env.mainWindowVisible = true
        env.consumersChanged()
    }
}
