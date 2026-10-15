//
//  main.swift
//  StockMenuBar
//
//  应用入口:accessory 策略(无 Dock 图标、不进入 Cmd+Tab),仅在菜单栏常驻。
//  @author ixxxxoooo
//

import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    AppIconProvider.apply()
    app.run()
}
