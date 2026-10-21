//
//  StatusItemController.swift
//  StockMenuBar
//
//  菜单栏常驻项:红绿着色的实时行情标题、左键 Popover、右键菜单。
//  @author ixxxxoooo
//

import AppKit
import SwiftUI

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let env = AppEnvironment.shared
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var rotateIndex = 0
    private var rotateTimer: Timer?

    /// 初始化菜单栏按钮与 Popover,并开始观察行情刷新标题
    func setup() {
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
        }
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let hosting = NSHostingController(rootView: PopoverView().refreshOnStealthChange())
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting

        autoUpdate { [weak self] in self?.updateTitle() }
    }

    // MARK: - 标题

    /// 构造菜单栏标题:`[名称] 价格 涨跌幅`,价格与涨跌幅按红涨绿跌着色
    private func updateTitle() {
        guard let button = statusItem.button else { return }
        let prefs = env.prefs
        let symbols = env.pinnedSymbols
        let redUp = prefs.redUp
        _ = prefs.stealthMode  // 建立观察:切换摸鱼模式时重绘菜单栏标题
        let useName = prefs.menuBarLabel == .name
        let compact = prefs.menuBarCompact
        let rotate = prefs.menuBarRotate && symbols.count > 1
        configureRotation(rotate)

        guard !symbols.isEmpty else {
            let image = NSImage(systemSymbolName: "chart.line.uptrend.xyaxis", accessibilityDescription: "StockMenuBar")
            image?.isTemplate = true
            button.image = image
            button.attributedTitle = NSAttributedString(string: "")
            return
        }

        let visible = rotate ? [symbols[rotateIndex % symbols.count]] : symbols
        let result = NSMutableAttributedString()
        let labelFont = NSFont.systemFont(ofSize: 12, weight: .regular)
        let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)

        for (i, symbol) in visible.enumerated() {
            if i > 0 {
                result.append(NSAttributedString(string: "  ", attributes: [.font: labelFont]))
            }
            let quote = env.quotes.ticker(for: symbol).quote
            let color = Theme.nsColor(quote?.trend ?? .flat, redUp: redUp)
            if !compact {
                let name = quote?.name ?? env.watchlist.firstItem(for: symbol)?.name ?? symbol.displayCode
                let label = useName ? name : symbol.displayCode
                result.append(NSAttributedString(string: label + " ", attributes: [.font: labelFont, .foregroundColor: NSColor.labelColor]))
            }
            let price = quote.map { Fmt.price($0.price, decimals: $0.decimals) } ?? "--"
            let pct = quote.map { Fmt.percent($0.changePercent) } ?? "--"
            result.append(NSAttributedString(string: price + " " + pct, attributes: [.font: numberFont, .foregroundColor: color]))
        }
        button.image = nil
        button.attributedTitle = result
    }

    /// 轮播定时器:仅在启用轮播且固定多只时运行
    private func configureRotation(_ needed: Bool) {
        if needed, rotateTimer == nil {
            rotateTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.rotateIndex += 1
                    self.updateTitle()
                }
            }
            rotateTimer?.tolerance = 1
        } else if !needed, let timer = rotateTimer {
            timer.invalidate()
            rotateTimer = nil
            rotateIndex = 0
        }
    }

    // MARK: - 点击

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            togglePopover()
        }
    }

    /// 切换 Popover;打开时补一次行情(盘后唯一的请求来源)
    func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        env.popoverVisible = true
        env.consumersChanged()
        env.scheduler.refreshOnDemand()
    }

    /// 关闭 Popover(打开其他窗口、老板键时调用)
    func closePopover() {
        if popover.isShown { popover.performClose(nil) }
    }

    func popoverDidClose(_ notification: Notification) {
        env.popoverVisible = false
        env.search.reset()
        env.consumersChanged()
    }

    // MARK: - 右键菜单

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(item("打开主面板", #selector(openMain)))
        let floatTitle = env.prefs.floatingVisible ? "隐藏悬浮窗" : "显示悬浮窗"
        let floating = item(floatTitle + "  (⌥⌘F)", #selector(toggleFloating))
        menu.addItem(floating)
        menu.addItem(item("立即刷新", #selector(refreshNow)))
        menu.addItem(item("偏好设置…", #selector(openSettings)))
        menu.addItem(item(env.updateMenuTitle, #selector(checkUpdates)))
        menu.addItem(.separator())
        menu.addItem(item("退出 StockMenuBar", #selector(quit)))
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = self
        return menuItem
    }

    @objc private func openMain() { env.openMainWindow?(false) }
    @objc private func openSettings() { env.openMainWindow?(true) }
    @objc private func checkUpdates() { env.checkForUpdates() }
    @objc private func toggleFloating() { env.toggleFloatingWindow?() }
    @objc private func refreshNow() { env.scheduler.refreshOnDemand() }
    @objc private func quit() { NSApp.terminate(nil) }
}
