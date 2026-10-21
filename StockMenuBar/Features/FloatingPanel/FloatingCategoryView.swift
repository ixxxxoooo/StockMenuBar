//
//  FloatingCategoryView.swift
//  StockMenuBar
//
//  悬浮窗分类切换:悬停时在关闭按钮旁出现分类按钮,点击后分类面板从窗口左侧展开,
//  可连续切换「默认 / 全部 / 各分组」;平时不显示任何分类信息。
//  @author ixxxxoooo
//

import SwiftUI

enum FloatingCategory {
    /// "全部自选"的特殊标识(其余分类为分组 UUID 字符串,nil 为默认)
    static let allID = "all"
}

extension FloatingLayout {
    static let categoryWidth: CGFloat = 124
    static let categoryGap: CGFloat = 8
    static let categoryRowHeight: CGFloat = 26
    /// 面板最多显示的行数,更多时可滚动
    static let categoryMaxRows = 8

    /// 分类面板高度
    /// - Parameter rows: 行数(默认 + 全部 + 分组数)
    static func categoryHeight(rows: Int) -> CGFloat {
        CGFloat(min(rows, categoryMaxRows)) * categoryRowHeight + 12
    }

    /// 含分类面板在内的窗口尺寸:面板展开时向左加宽,高度取两者较大者
    /// - Parameters:
    ///   - card: 卡片(迷你窗主体)尺寸
    ///   - categoryRows: 分类面板行数;为 nil 表示面板收起
    static func windowSize(card: CGSize, categoryRows: Int?) -> CGSize {
        guard let rows = categoryRows else { return card }
        return CGSize(width: card.width + categoryWidth + categoryGap,
                      height: max(card.height, categoryHeight(rows: rows)))
    }
}

/// 悬停时出现的分类按钮(放在关闭按钮旁)
struct FloatingCategoryButton: View {
    private let env = AppEnvironment.shared

    var body: some View {
        let open = env.ui.floatingCategoryOpen
        Button {
            env.ui.setFloatingCategory(!open)
        } label: {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(open ? Color.accentColor : .secondary)
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.primary.opacity(open ? 0.2 : 0.12)))
        }
        .buttonStyle(.plain)
        .help("切换分类")
    }
}

/// 分类面板:出现在迷你窗左侧
struct FloatingCategoryPanel: View {
    /// 鼠标进出面板(用于与主体共同决定是否保持展开)
    var onHover: (Bool) -> Void
    private let env = AppEnvironment.shared

    /// 行数据:(标识, 名称, 数量)
    private var rows: [(id: String?, name: String, count: Int)] {
        let groups = env.watchlist.groups
        return [(nil, "默认", 0), (FloatingCategory.allID, "全部", env.watchlist.allSymbols.count)]
            + groups.map { ($0.id.uuidString, $0.name, $0.items.count) }
    }

    var body: some View {
        let rows = rows
        let shape = RoundedRectangle(cornerRadius: FloatingLayout.cornerRadius, style: .continuous)
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                ForEach(rows, id: \.id) { row in
                    categoryRow(id: row.id, name: row.name, count: row.count)
                }
            }
            .padding(.vertical, 6)
        }
        .frame(width: FloatingLayout.categoryWidth, height: FloatingLayout.categoryHeight(rows: rows.count))
        .background(shape.fill(.regularMaterial).opacity(env.prefs.floatingOpacity))
        .overlay(shape.strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5))
        .clipShape(shape)
        .onHover(perform: onHover)
    }

    /// 单行分类:当前项高亮并带对勾,"默认"不显示数量
    private func categoryRow(id: String?, name: String, count: Int) -> some View {
        let selected = env.prefs.floatingGroupID == id
        return Button {
            withAnimation(.snappy(duration: 0.22)) { env.prefs.floatingGroupID = id }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(selected ? 1 : 0)
                    .frame(width: 10)
                Text(name).font(.system(size: 12, weight: selected ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 0)
                if id != nil {
                    Text("\(count)").font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: FloatingLayout.categoryRowHeight)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(selected ? 0.1 : 0)))
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
