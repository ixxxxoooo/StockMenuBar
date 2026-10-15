//
//  MainView.swift
//  StockMenuBar
//
//  沉浸式主面板:NavigationSplitView 两栏布局。
//  左侧自选分组(拖拽排序、快速过滤、分组管理),右侧详情或偏好设置。
//  @author ixxxxoooo
//

import SwiftUI

struct MainView: View {
    private let env = AppEnvironment.shared
    @Bindable private var nav = AppEnvironment.shared.nav
    @State private var filter = ""
    @State private var showAdd = false
    @State private var showGroupManager = false
    @State private var renameTarget: WatchGroup?
    @State private var renameText = ""
    @FocusState private var addFocus: Bool

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 340)
        } detail: {
            detail
        }
        .onAppear {
            if nav.selection == nil, let first = env.watchlist.groups.flatMap(\.items).first {
                nav.selection = .item(first.id)
            }
        }
        .alert("重命名分组", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("分组名称", text: $renameText)
            Button("确定") {
                if let target = renameTarget { env.watchlist.renameGroup(id: target.id, to: renameText) }
                renameTarget = nil
            }
            Button("取消", role: .cancel) { renameTarget = nil }
        }
        .sheet(isPresented: $showGroupManager) { GroupManagerView() }
    }

    // MARK: - 侧边栏

    private var sidebar: some View {
        let key = filter.trimmingCharacters(in: .whitespaces)
        let groups = env.watchlist.groups
        return List(selection: $nav.selection) {
            ForEach(groups) { group in
                let items = key.isEmpty ? group.items : group.items.filter {
                    Pinyin.matches(keyword: key, name: $0.name, code: $0.symbol.displayCode)
                }
                if key.isEmpty || !items.isEmpty {
                    Section {
                        ForEach(items) { item in
                            SidebarRow(item: item)
                                .tag(MainSelection.item(item.id))
                                .contextMenu { itemMenu(item, in: group) }
                        }
                        .onMove { source, destination in
                            if key.isEmpty { env.watchlist.moveItems(in: group.id, from: source, to: destination) }
                        }
                        .onDelete { offsets in
                            for index in offsets where index < items.count { env.removeFromWatchlist(items[index]) }
                        }
                    } header: {
                        groupHeader(group)
                    }
                }
            }
            Section {
                Label("偏好设置", systemImage: "gearshape").tag(MainSelection.settings)
            }
        }
        .listStyle(.sidebar)
        // 过滤框与操作按钮放在侧栏内部(而不是 .searchable / .toolbar):
        // 避免折叠/展开侧栏时系统把工具栏项在侧栏与标题栏之间迁移,造成卡顿闪烁
        .safeAreaInset(edge: .top, spacing: 0) { filterBar }
        .safeAreaInset(edge: .bottom, spacing: 0) { sidebarActions }
    }

    /// 侧栏顶部过滤框(支持名称/代码/拼音首字母)
    private var filterBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
            TextField("过滤:名称 / 代码 / 拼音", text: $filter)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
            if !filter.isEmpty {
                Button { filter = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    /// 侧栏底部操作:添加自选、管理分组
    private var sidebarActions: some View {
        HStack(spacing: 4) {
            Button { showAdd = true } label: { Label("添加自选", systemImage: "plus") }
                .help("搜索并添加自选")
                .popover(isPresented: $showAdd, arrowEdge: .top) { AddStockView() }
            Spacer()
            Button { showGroupManager = true } label: { Image(systemName: "folder.badge.gearshape") }
                .help("管理分组")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(.bar)
    }

    private func groupHeader(_ group: WatchGroup) -> some View {
        HStack(spacing: 4) {
            Text(group.name)
            Text("\(group.items.count)").foregroundStyle(.tertiary)
            Spacer()
        }
        .contextMenu {
            Button("重命名…") {
                renameText = group.name
                renameTarget = group
            }
            Button("设为当前添加分组") { env.watchlist.selectedGroupID = group.id }
            Divider()
            Button("删除分组", role: .destructive) { env.watchlist.deleteGroup(id: group.id) }
                .disabled(env.watchlist.groups.count <= 1)
        }
    }

    @ViewBuilder
    private func itemMenu(_ item: WatchItem, in group: WatchGroup) -> some View {
        let prefs = env.prefs
        Button(prefs.isPinned(item.symbol) ? "取消固定到菜单栏" : "固定到菜单栏") {
            prefs.togglePinned(item.symbol)
            env.consumersChanged()
        }
        Button(prefs.isInFloating(item.symbol) ? "移出悬浮窗" : "加入悬浮窗") { prefs.toggleFloating(item.symbol) }
        Menu("移动到分组") {
            ForEach(env.watchlist.groups.filter { $0.id != group.id }) { target in
                Button(target.name) { env.watchlist.moveItem(itemID: item.id, toGroup: target.id) }
            }
        }
        Divider()
        Button("删除自选", role: .destructive) { env.removeFromWatchlist(item) }
    }

    // MARK: - 详情

    @ViewBuilder
    private var detail: some View {
        switch nav.selection {
        case .settings:
            SettingsView()
        case .item(let id):
            if let item = env.watchlist.item(id: id) {
                StockDetailView(item: item).id(item.id)
            } else {
                placeholder
            }
        case nil:
            placeholder
        }
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.line.uptrend.xyaxis").font(.system(size: 38)).foregroundStyle(.tertiary)
            Text("在左侧选择一只自选股").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 侧边栏行:名称、代码与实时涨跌幅
struct SidebarRow: View {
    let item: WatchItem
    private let env = AppEnvironment.shared

    var body: some View {
        let ticker = env.quotes.ticker(for: item.symbol)
        let quote = ticker.quote
        let trend = quote?.trend ?? .flat
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(quote?.name ?? item.name).font(.system(size: 13)).lineLimit(1)
                    if env.prefs.isPinned(item.symbol) {
                        Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(.secondary)
                    }
                }
                Text(item.symbol.displayCode).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 1) {
                Text(quote.map { Fmt.price($0.price, decimals: $0.decimals) } ?? "--")
                    .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                Text(quote.map { Fmt.percent($0.changePercent) } ?? "--")
                    .font(.system(size: 10.5).monospacedDigit())
            }
            .foregroundStyle(trend == .flat ? Color.secondary : Theme.color(trend, redUp: env.prefs.redUp))
        }
        .padding(.vertical, 1)
        .tickFlash(ticker, cornerRadius: 4)
    }
}

/// 添加自选弹层:选择分组并搜索
struct AddStockView: View {
    private let env = AppEnvironment.shared
    @FocusState private var focus: Bool

    var body: some View {
        let watchlist = env.watchlist
        VStack(spacing: 0) {
            HStack {
                Text("加入分组").font(.system(size: 12)).foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { watchlist.selectedGroup?.id ?? UUID() },
                    set: { watchlist.selectedGroupID = $0 }
                )) {
                    ForEach(watchlist.groups) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .frame(width: 130)
                Spacer()
            }
            .padding(10)
            SearchField(vm: env.search, focus: $focus)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            Divider()
            ScrollView {
                if env.search.isActive {
                    SearchResultsView(vm: env.search)
                } else {
                    Text("输入拼音首字母(如 GZMT)、中文名称(如 贵州茅台)或 6 位代码(如 600519),自动识别沪/深/北交所与创业板、科创板。")
                        .font(.system(size: 12)).foregroundStyle(.secondary).padding(14)
                }
            }
            .frame(height: 300)
        }
        .frame(width: 340)
        .onAppear { focus = true }
        .onDisappear { env.search.reset() }
    }
}

/// 分组管理:新建、重命名、删除、拖拽排序
struct GroupManagerView: View {
    private let env = AppEnvironment.shared
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("管理分组").font(.headline)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(14)
            Divider()
            List {
                ForEach(env.watchlist.groups) { group in
                    HStack {
                        Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                        TextField("分组名称", text: Binding(
                            get: { env.watchlist.groups.first { $0.id == group.id }?.name ?? "" },
                            set: { env.watchlist.renameGroup(id: group.id, to: $0) }
                        ))
                        .textFieldStyle(.plain)
                        Text("\(group.items.count) 只").foregroundStyle(.secondary).font(.caption)
                        Button(role: .destructive) { env.watchlist.deleteGroup(id: group.id) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .disabled(env.watchlist.groups.count <= 1)
                    }
                }
                .onMove { env.watchlist.moveGroups(from: $0, to: $1) }
            }
            Divider()
            HStack {
                TextField("新建分组名称", text: $newName).onSubmit(addGroup)
                Button("添加", action: addGroup).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
        .frame(width: 380, height: 420)
    }

    private func addGroup() {
        if env.watchlist.addGroup(name: newName) != nil { newName = "" }
    }
}
