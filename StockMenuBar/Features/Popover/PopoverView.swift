//
//  PopoverView.swift
//  StockMenuBar
//
//  菜单栏点击弹出的卡片:搜索、分组切换、自选简表(极简/分时缩略图)、底部状态栏。
//  @author ixxxxoooo
//

import SwiftUI

struct PopoverView: View {
    private let env = AppEnvironment.shared
    @State private var expandedID: UUID?
    @State private var hoverTask: Task<Void, Never>?
    @FocusState private var searchFocused: Bool

    private static let width: CGFloat = 344

    var body: some View {
        let search = env.search
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.4)
            if search.isActive {
                ScrollView {
                    SearchResultsView(vm: search, localMatches: localMatches)
                }
                .frame(height: 344)
            } else {
                groupChips
                listArea
            }
            Divider().opacity(0.4)
            PopoverFooter()
        }
        .frame(width: Self.width)
    }

    // MARK: - 顶部工具栏

    private var toolbar: some View {
        HStack(spacing: 8) {
            SearchField(vm: env.search, prompt: "搜索 代码 / 名称 / 拼音", focus: $searchFocused)
            toolbarButton("macwindow", help: "打开主面板") { env.openMainWindow?(false) }
            toolbarButton("rectangle.on.rectangle", help: "悬浮迷你窗 (⌥⌘F)") { env.toggleFloatingWindow?() }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func toolbarButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.07)))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - 分组与列表

    private var groupChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(env.watchlist.groups) { group in
                    let selected = group.id == env.watchlist.selectedGroup?.id
                    Button {
                        env.watchlist.selectedGroupID = group.id
                        expandedID = nil
                    } label: {
                        Text(group.name)
                            .font(.system(size: 11, weight: selected ? .semibold : .regular))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(selected ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.06)))
                            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var listArea: some View {
        let items = env.watchlist.selectedGroup?.items ?? []
        let minimal = env.prefs.popoverMinimal
        if items.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "star").font(.system(size: 22)).foregroundStyle(.tertiary)
                Text("该分组还没有自选,在上方搜索并点击 + 添加")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 120)
        } else {
            let rowHeight: CGFloat = minimal ? 30 : 46
            let expandedExtra: CGFloat = expandedID == nil ? 0 : 92
            let height = min(max(CGFloat(items.count) * rowHeight + expandedExtra + 4, 90), 372)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        PopoverRow(item: item, minimal: minimal, expanded: expandedID == item.id)
                            .onHover { inside in handleHover(item.id, inside: inside) }
                            .onTapGesture {
                                hoverTask?.cancel()
                                withAnimation(.snappy(duration: 0.22)) {
                                    expandedID = expandedID == item.id ? nil : item.id
                                }
                            }
                            .contextMenu { rowMenu(item) }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: height)
        }
    }

    /// 悬停 350ms 后展开分时缩略图(避免鼠标划过时列表抖动)
    private func handleHover(_ id: UUID, inside: Bool) {
        hoverTask?.cancel()
        guard inside, expandedID != id else { return }
        hoverTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy(duration: 0.22)) { expandedID = id }
        }
    }

    @ViewBuilder
    private func rowMenu(_ item: WatchItem) -> some View {
        let prefs = env.prefs
        Button(prefs.isPinned(item.symbol) ? "取消固定到菜单栏" : "固定到菜单栏") {
            prefs.togglePinned(item.symbol)
            env.consumersChanged()
        }
        Button(prefs.isInFloating(item.symbol) ? "移出悬浮窗" : "加入悬浮窗") { prefs.toggleFloating(item.symbol) }
        Button("在主面板中查看") {
            env.nav.selection = .item(item.id)
            env.openMainWindow?(false)
        }
        Divider()
        Button("删除自选", role: .destructive) { env.removeFromWatchlist(item) }
    }

    /// 本地自选即时匹配(拼音首字母/名称/代码)
    private var localMatches: [WatchItem] {
        let key = env.search.query
        var seen = Set<StockSymbol>()
        var result: [WatchItem] = []
        for group in env.watchlist.groups {
            for item in group.items where Pinyin.matches(keyword: key, name: item.name, code: item.symbol.code) {
                if seen.insert(item.symbol).inserted { result.append(item) }
            }
        }
        return Array(result.prefix(4))
    }
}

/// Popover 列表行
struct PopoverRow: View {
    let item: WatchItem
    let minimal: Bool
    let expanded: Bool
    private let env = AppEnvironment.shared
    @State private var loader = MinuteLoader(store: AppEnvironment.shared.quotes)

    var body: some View {
        let ticker = env.quotes.ticker(for: item.symbol)
        let quote = ticker.quote
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(quote?.name ?? item.name)
                            .font(.system(size: minimal ? 12.5 : 13, weight: .medium))
                            .lineLimit(1)
                        if env.prefs.isPinned(item.symbol) {
                            Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(.secondary)
                        }
                    }
                    if !minimal {
                        HStack(spacing: 4) {
                            Text(item.symbol.code).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary)
                            KindTag(kind: item.symbol.kind)
                        }
                    }
                }
                Spacer(minLength: 4)
                if !minimal {
                    PriceText(quote: quote, size: 14)
                        .frame(width: 78, alignment: .trailing)
                }
                ChangeBadge(quote: quote)
            }
            .padding(.horizontal, 12)
            .frame(height: minimal ? 30 : 46)
            .tickFlash(ticker)
            .padding(.horizontal, 4)

            if expanded { expandedPanel(quote) }
        }
        .background(expanded ? Color.primary.opacity(0.04) : Color.clear)
        .contentShape(Rectangle())
        .task(id: expanded) {
            if expanded { await loader.run(symbol: item.symbol, tradingInterval: 10) }
        }
    }

    /// 展开的分时缩略图
    private func expandedPanel(_ quote: Quote?) -> some View {
        VStack(spacing: 4) {
            ZStack {
                Sparkline(series: loader.series)
                if loader.series == nil {
                    Text(loader.failed ? "分时加载失败" : "加载中…")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            .frame(height: 58)
            if let q = quote {
                HStack {
                    stat("今开", Fmt.price(q.open, decimals: q.decimals))
                    stat("最高", Fmt.price(q.high, decimals: q.decimals))
                    stat("最低", Fmt.price(q.low, decimals: q.decimals))
                    stat("成交额", Fmt.amount(q.amount))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 1) {
            Text(title).font(.system(size: 9)).foregroundStyle(.tertiary)
            Text(value).font(.system(size: 10.5, weight: .medium).monospacedDigit())
        }
        .frame(maxWidth: .infinity)
    }
}

/// 底部状态栏:上次刷新时间、刷新间隔、数据源、退出
struct PopoverFooter: View {
    private let env = AppEnvironment.shared

    var body: some View {
        let store = env.quotes
        HStack(spacing: 6) {
            HealthDot(health: store.health, suspended: store.isSuspended)
            Text(store.lastUpdate.map { "更新 \(Fmt.clock($0))" } ?? "尚未更新")
                .font(.system(size: 10.5).monospacedDigit())
            Text("· \(store.intervalLabel)")
                .font(.system(size: 10.5))
            if let source = store.activeSource {
                Text("· \(source.displayName)").font(.system(size: 10.5))
            }
            Spacer()
            Button {
                env.openMainWindow?(true)
            } label: {
                Image(systemName: "gearshape").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help("偏好设置")
            Button("退出程序") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 30)
    }
}
