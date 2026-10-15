//
//  SettingsView.swift
//  StockMenuBar
//
//  偏好设置:刷新频率、红绿反转、开机自启、菜单栏、悬浮窗、数据源状态。
//  @author ixxxxoooo
//

import SwiftUI

struct SettingsView: View {
    private let env = AppEnvironment.shared
    @State private var statuses: [ProviderStatus] = []

    var body: some View {
        @Bindable var prefs = env.prefs
        Form {
            Section("刷新") {
                Picker("交易时段刷新间隔", selection: $prefs.refreshInterval) {
                    ForEach(Preferences.allowedIntervals, id: \.self) { Text("\($0) 秒").tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: prefs.refreshInterval) { _, _ in env.scheduler.reschedule() }
                Text("交易时间(9:15-11:30、13:00-15:05)按此间隔刷新;午休每 1 分钟;盘后与夜间不后台轮询,仅在打开界面时请求一次。系统睡眠、锁屏、屏保时自动暂停。")
                    .font(.footnote).foregroundStyle(.secondary)
                LabeledContent("当前状态") {
                    Text("\(env.quotes.intervalLabel)  ·  \(env.quotes.lastUpdate.map { "更新于 \(Fmt.clock($0))" } ?? "尚未更新")")
                        .monospacedDigit()
                }
            }

            Section("外观") {
                Toggle("红涨绿跌(A 股习惯)", isOn: $prefs.redUp)
                Text(prefs.redUp ? "上涨显示红色,下跌显示绿色" : "已反转:上涨显示绿色,下跌显示红色")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("菜单栏") {
                Picker("标识显示", selection: $prefs.menuBarLabel) {
                    ForEach(MenuBarLabelMode.allCases) { Text($0.title).tag($0) }
                }
                Toggle("紧凑模式(只显示价格与涨跌幅)", isOn: $prefs.menuBarCompact)
                Toggle("多只固定时轮播(每 5 秒切换)", isOn: $prefs.menuBarRotate)
                pinnedList(title: "固定在菜单栏(最多 \(Preferences.maxPinned) 只)", symbols: env.pinnedSymbols) { symbol in
                    env.prefs.togglePinned(symbol)
                    env.consumersChanged()
                }
                Toggle("Popover 极简模式(仅名称与涨跌幅)", isOn: $prefs.popoverMinimal)
            }

            Section("悬浮迷你窗") {
                Toggle("显示悬浮窗", isOn: $prefs.floatingVisible)
                Picker("形态", selection: $prefs.floatingStyle) {
                    ForEach(FloatingStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledContent("背景不透明度") {
                    HStack {
                        Slider(value: $prefs.floatingOpacity, in: 0.3...1.0)
                        Text("\(Int(prefs.floatingOpacity * 100))%").monospacedDigit().frame(width: 40)
                    }
                    .frame(width: 240)
                }
                Toggle("鼠标移出后淡化", isOn: $prefs.floatingFade)
                Toggle("穿透锁定(点击穿过悬浮窗,⌥⌘L 解除)", isOn: $prefs.floatingClickThrough)
                pinnedList(title: "悬浮窗监控的标的(为空则取当前分组前 6 只)",
                           symbols: prefs.floatingSymbols.compactMap(StockSymbol.init(full:))) { symbol in
                    env.prefs.toggleFloating(symbol)
                }
            }

            Section("通用") {
                Toggle("开机自启", isOn: Binding(get: { env.prefs.launchAtLogin }, set: { env.prefs.setLaunchAtLogin($0) }))
                if let error = env.prefs.launchError {
                    Text("设置失败:\(error)").font(.footnote).foregroundStyle(.red)
                }
                LabeledContent("全局快捷键") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("⌥⌘F  显示/隐藏悬浮窗")
                        Text("⌥⌘L  悬浮窗穿透锁定开关")
                        Text("⌥⌘H  老板键:一键隐藏/恢复所有窗口")
                    }
                    .font(.footnote).foregroundStyle(.secondary)
                }
            }

            Section("行情数据源(高可用)") {
                ForEach(statuses) { status in
                    statusRow(status)
                }
                Text("多个数据源(腾讯、新浪、东财、雅虎)按延迟与成功率自动排序,各自覆盖的品种不同;主源失败/超时会自动切换并对冲请求;连续失败 3 次熔断 30 秒后探测恢复。数据来自公开接口,可能存在延迟,仅供个人参考,不构成投资建议。")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            aboutSection
        }
        .formStyle(.grouped)
        .navigationTitle("偏好设置")
        .task {
            while !Task.isCancelled {
                statuses = await env.router.statuses()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// 关于:作者、项目简介与 GitHub 链接(位于页面最底部)
    private var aboutSection: some View {
        Section("关于") {
            LabeledContent("应用") { Text("StockMenuBar  \(AppInfo.version)") }
            LabeledContent("作者") {
                Link(AppInfo.author, destination: URL(string: "https://github.com/\(AppInfo.author)")!)
            }
            LabeledContent("简介") {
                Text(AppInfo.summary).multilineTextAlignment(.trailing).foregroundStyle(.secondary)
            }
            LabeledContent("技术栈") { Text(AppInfo.techStack).foregroundStyle(.secondary) }
            LabeledContent("开源协议") { Text("MIT License").foregroundStyle(.secondary) }
            LabeledContent("项目地址") {
                Link(destination: AppInfo.repositoryURL) {
                    Label(AppInfo.repositoryURL.absoluteString, systemImage: "link")
                }
            }
        }
    }

    @ViewBuilder
    private func pinnedList(title: String, symbols: [StockSymbol], remove: @escaping (StockSymbol) -> Void) -> some View {
        LabeledContent(title) {
            if symbols.isEmpty {
                Text("未设置").foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .trailing, spacing: 4) {
                    ForEach(symbols) { symbol in
                        HStack(spacing: 6) {
                            Text(env.quotes.quote(for: symbol)?.name ?? env.watchlist.firstItem(for: symbol)?.name ?? symbol.displayCode)
                            Text(symbol.displayCode).foregroundStyle(.secondary).monospacedDigit()
                            Button { remove(symbol) } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func statusRow(_ s: ProviderStatus) -> some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 2) {
                Text("延迟 \(Int(s.ewmaLatency * 1000)) ms · 成功率 \(Int(s.successRate * 100))% · 请求 \(s.totalRequests) 次")
                    .monospacedDigit()
                if let err = s.lastError, s.successRate < 0.99 {
                    Text("最近错误:\(err)").font(.caption).foregroundStyle(.orange).lineLimit(1)
                }
            }
            .font(.callout)
        } label: {
            HStack(spacing: 6) {
                Circle().fill(color(for: s)).frame(width: 8, height: 8)
                Text(s.id.displayName)
                if env.quotes.activeSource == s.id {
                    Text("当前").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.2))).foregroundStyle(Color.accentColor)
                }
                if case .open = s.breaker {
                    Text("熔断中").font(.caption2).foregroundStyle(.red)
                }
            }
        }
    }

    private func color(for s: ProviderStatus) -> Color {
        if case .open = s.breaker { return .red }
        if s.successRate < 0.8 { return .orange }
        return s.totalRequests == 0 ? .gray : .green
    }
}
