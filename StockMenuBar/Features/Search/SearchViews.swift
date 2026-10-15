//
//  SearchViews.swift
//  StockMenuBar
//
//  搜索框与联想结果列表(Popover 与主面板「添加自选」共用)。
//  @author ixxxxoooo
//

import SwiftUI

/// 搜索输入框
struct SearchField: View {
    @Bindable var vm: SearchViewModel
    var prompt = "代码 / 名称 / 拼音首字母,如 GZMT"
    var focus: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField(prompt, text: $vm.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused(focus)
                .onChange(of: vm.query) { _, _ in vm.queryChanged() }
            if vm.isSearching {
                ProgressView().controlSize(.mini)
            } else if vm.isActive {
                Button {
                    vm.reset()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.07)))
    }
}

/// 联想结果列表
struct SearchResultsView: View {
    var vm: SearchViewModel
    /// 本地自选匹配(拼音即时匹配,不等待网络)
    var localMatches: [WatchItem] = []
    private let env = AppEnvironment.shared

    var body: some View {
        let watchlist = env.watchlist
        VStack(alignment: .leading, spacing: 0) {
            if !localMatches.isEmpty {
                sectionTitle("自选中匹配")
                ForEach(localMatches) { item in
                    HStack(spacing: 8) {
                        Text(item.name).font(.system(size: 13, weight: .medium))
                        Text(item.symbol.code).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                        KindTag(kind: item.symbol.kind)
                        Spacer()
                        Image(systemName: "star.fill").foregroundStyle(.yellow).font(.system(size: 11))
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                }
            }
            sectionTitle(targetTitle)
            if let error = vm.errorText {
                hint(error, symbol: "exclamationmark.triangle")
            } else if vm.results.isEmpty {
                if vm.isSearching {
                    hint("搜索中…", symbol: "ellipsis")
                } else if !vm.resultsQuery.isEmpty {
                    hint("没有找到「\(vm.resultsQuery)」相关结果", symbol: "questionmark.circle")
                }
            } else {
                ForEach(vm.results) { result in
                    resultRow(result, watchlist: watchlist)
                }
            }
        }
    }

    private var targetTitle: String {
        "搜索结果 · 加入「\(env.watchlist.selectedGroup?.name ?? "自选")」"
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private func hint(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(12)
    }

    private func resultRow(_ result: SearchResult, watchlist: WatchlistStore) -> some View {
        let added = watchlist.contains(result.symbol, in: watchlist.selectedGroup?.id)
        return HStack(spacing: 8) {
            Text(result.symbol.market.title)
                .font(.system(size: 9, weight: .bold))
                .frame(width: 16, height: 16)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.2)))
            VStack(alignment: .leading, spacing: 1) {
                Text(result.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(result.symbol.code).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            }
            KindTag(kind: result.kind)
            Spacer()
            Button {
                if !added { env.addToWatchlist(result) }
            } label: {
                Image(systemName: added ? "checkmark.circle.fill" : "plus.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(added ? Color.green : Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(added)
            .help(added ? "已在当前分组" : "加入当前分组")
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .contentShape(Rectangle())
    }
}
