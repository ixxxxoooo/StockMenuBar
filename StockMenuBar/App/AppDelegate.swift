//
//  AppDelegate.swift
//  StockMenuBar
//
//  应用生命周期:装配菜单栏、主面板、悬浮窗、全局快捷键与调度器。
//  应用以 accessory 策略运行:不占 Dock、不进 Cmd+Tab。
//  @author ixxxxoooo
//

import AppKit
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let env = AppEnvironment.shared
    private var statusController: StatusItemController?
    private let mainWindow = MainWindowController()
    private let floating = FloatingPanelController()
    private var mainWasVisibleBeforeBoss = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        env.power.start()

        let status = StatusItemController()
        status.setup()
        statusController = status
        floating.setup()

        env.openMainWindow = { [weak self] settings in
            self?.statusController?.closePopover()
            self?.mainWindow.show(settings: settings)
        }
        env.toggleFloatingWindow = { [weak self] in
            self?.statusController?.closePopover()
            self?.env.prefs.floatingVisible.toggle()
            self?.env.ui.bossHidden = false
        }

        registerHotKeys()
        env.scheduler.start()
        env.updates.terminate = { NSApp.terminate(nil) }
        env.updates.startAutoCheck()
        handleLaunchArguments()
    }

    /// 启动参数(便于调试与截图验证):--show-main / --show-settings / --show-popover / --show-floating
    private func handleLaunchArguments() {
        let args = CommandLine.arguments
        // 无界面的备份导入/导出(脚本迁移用):完成后直接退出
        if BackupActions.handleLaunchArguments(args) {
            fflush(stdout)
            NSApp.terminate(nil)
            return
        }
        if args.contains("--show-main") { mainWindow.show(settings: false) }
        if args.contains("--show-settings") { mainWindow.show(settings: true) }
        if let pin = args.first(where: { $0.hasPrefix("--pin=") }) {
            env.prefs.pinnedSymbols = pin.dropFirst(6).split(separator: ",").map(String.init)
        }
        if args.contains("--show-floating") { env.prefs.floatingVisible = true }
        if args.contains("--update-now") { runUpdateNow() }
        if args.contains("--show-popover") {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(800))
                self?.statusController?.togglePopover()
            }
        }
    }

    /// 调试/自动化测试:启动后立即检查,发现新版本就下载、安装并重启(--update-now)
    private func runUpdateNow() {
        mainWindow.show(settings: true)
        Task { @MainActor [weak self] in
            guard let updates = self?.env.updates else { return }
            await updates.check(userInitiated: true)
            updates.installAvailableUpdate()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mainWindow.show(settings: false)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        HotKeyCenter.shared.unregisterAll()
    }

    // MARK: - 全局快捷键

    private func registerHotKeys() {
        let mods = optionKey | cmdKey
        HotKeyCenter.shared.register(keyCode: kVK_ANSI_F, modifiers: mods, id: 1) { [weak self] in
            self?.env.toggleFloatingWindow?()
        }
        HotKeyCenter.shared.register(keyCode: kVK_ANSI_L, modifiers: mods, id: 2) { [weak self] in
            self?.env.prefs.floatingClickThrough.toggle()
        }
        HotKeyCenter.shared.register(keyCode: kVK_ANSI_H, modifiers: mods, id: 3) { [weak self] in
            self?.toggleBossKey()
        }
    }

    /// 老板键:一键隐藏 Popover、主面板与悬浮窗;再按一次恢复
    private func toggleBossKey() {
        if env.ui.bossHidden {
            env.ui.bossHidden = false
            if mainWasVisibleBeforeBoss { mainWindow.show(settings: false) }
        } else {
            mainWasVisibleBeforeBoss = mainWindow.isVisible
            statusController?.closePopover()
            mainWindow.hide()
            env.ui.bossHidden = true
        }
    }

    /// 菜单「偏好设置…」(⌘,):打开主面板并跳转到设置页
    @objc private func openPreferences() {
        mainWindow.show(settings: true)
    }

    /// 菜单「检查更新…」
    @objc private func checkForUpdates() { env.checkForUpdates() }

    // MARK: - 主菜单(accessory 应用没有菜单栏,但需要 Edit 菜单让 ⌘C/⌘V/⌘A 在搜索框中可用)

    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let prefs = NSMenuItem(title: "偏好设置…", action: #selector(openPreferences), keyEquivalent: ",")
        prefs.target = self
        appMenu.addItem(prefs)
        let update = NSMenuItem(title: "检查更新…", action: #selector(checkForUpdates), keyEquivalent: "")
        update.target = self
        appMenu.addItem(update)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 StockMenuBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "窗口")
        window.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = window
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }
}
