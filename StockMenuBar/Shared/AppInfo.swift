//
//  AppInfo.swift
//  StockMenuBar
//
//  应用元信息:作者、项目地址、简介与版本号,供「关于」页与文档共用。
//  @author ixxxxoooo
//

import Foundation

enum AppInfo {
    /// 作者(GitHub 账号)
    static let author = "ixxxxoooo"
    /// 项目主页
    static let repositoryURL = URL(string: "https://github.com/ixxxxoooo/StockMenuBar")!
    /// 项目一句话简介
    static let summary = "原生 macOS A 股与全球行情监控:菜单栏、Popover、主面板与悬浮迷你窗,支持期货、贵金属与全球指数,多数据源高可用自动切换。"
    /// 技术栈说明
    static let techStack = "Swift 6 · SwiftUI · AppKit · Swift Charts · 无第三方依赖"

    /// 版本号(取自 Info.plist,缺失时为 dev)
    static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "\(short) (\($0))" } ?? short
    }
}
