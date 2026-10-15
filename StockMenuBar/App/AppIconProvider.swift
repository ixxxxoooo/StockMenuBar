//
//  AppIconProvider.swift
//  StockMenuBar
//
//  显式设置应用图标。
//  应用以 LSUIElement 启动、主面板打开时才切换为 regular 策略;只依赖资源目录里的图标时,
//  Dock 与 ⌘Tab 会显示通用占位图标,因此切换策略后需要主动把图标交给 Dock。
//  @author ixxxxoooo
//

import AppKit

@MainActor
enum AppIconProvider {
    /// 把应用图标显式设置为 Dock / 应用切换器使用的图标
    static func apply() {
        if let image = NSImage(named: "AppIcon") {
            NSApp.applicationIconImage = image
        } else {
            NSApp.applicationIconImage = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        }
    }
}
