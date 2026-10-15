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
    }

    private func ensureWindow() -> NSWindow {
        if let window { return window }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "StockMenuBar"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: MainView())
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
    }
}
