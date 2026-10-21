//
//  FloatingViews.swift
//  StockMenuBar
//
//  悬浮迷你窗界面:胶囊 / 迷你列表 / 卡片 三种形态。
//  毛玻璃背景 + 细描边 + 圆角,走势线用 Canvas 手绘,单只更新只重绘对应行。
//  @author ixxxxoooo
//

import SwiftUI

/// 悬浮窗尺寸规则
enum FloatingLayout {
    static let cornerRadius: CGFloat = 12
    /// 悬停行展开分时图增加的高度
    static let expandedExtra: CGFloat = 96

    /// 各形态的窗口内容尺寸
    /// - Parameters:
    ///   - style: 形态
    ///   - count: 监控的标的数
    ///   - expanded: 迷你列表是否有一行因鼠标悬停展开了分时图
    static func size(style: FloatingStyle, count: Int, expanded: Bool = false) -> CGSize {
        switch style {
        case .capsule: return CGSize(width: 232, height: 34)
        case .list: return CGSize(width: 280, height: CGFloat(max(min(count, 8), 1)) * 30 + 12 + (expanded ? expandedExtra : 0))
        case .card: return CGSize(width: 206, height: 132)
        }
    }
}

struct FloatingRootView: View {
    private let env = AppEnvironment.shared
    @State private var hovered = false
    @State private var cycleIndex = 0
    @State private var categoryHovered = false
    @State private var collapseTask: Task<Void, Never>?

    /// 窗口会先于内容动画长到最大尺寸,卡片必须贴顶贴右:用 Spacer 把多出的高度留在卡片下方,
    /// 分类面板在卡片左侧展开(窗口向左加宽),展开时卡片位置不动
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: FloatingLayout.categoryGap) {
                if env.ui.floatingCategoryShown {
                    FloatingCategoryPanel { inside in
                        categoryHovered = inside
                        // 鼠标进入面板即收起卡片里展开的行
                        if inside { withAnimation(.snappy(duration: 0.22)) { env.ui.floatingHoverSymbol = nil } }
                        scheduleCollapse()
                    }
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                card
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .onChange(of: env.prefs.floatingGroupID) { _, _ in
            cycleIndex = 0
            env.ui.floatingHoverSymbol = nil
        }
    }

    /// 鼠标离开主体与分类面板 0.6 秒后自动收起面板,回到不显示分类的状态
    private func scheduleCollapse() {
        collapseTask?.cancel()
        guard env.ui.floatingCategoryOpen, !hovered, !categoryHovered else { return }
        collapseTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, !hovered, !categoryHovered else { return }
            env.ui.setFloatingCategory(false)
        }
    }

    @ViewBuilder
    private var card: some View {
        let prefs = env.prefs
        let symbols = env.floatingSymbols
        let style = prefs.floatingStyle
        let size = FloatingLayout.size(style: style, count: symbols.count,
                                       expanded: style == .list && env.ui.floatingHoverSymbol.map { h in symbols.contains(h) } == true)
        let shape = RoundedRectangle(cornerRadius: FloatingLayout.cornerRadius, style: .continuous)

        ZStack(alignment: .topTrailing) {
            Group {
                if symbols.isEmpty {
                    Text(prefs.floatingGroupID == nil ? "暂无标的,请先添加自选" : "该分类暂无标的")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    switch style {
                    case .capsule:
                        FloatingCapsuleView(symbol: symbols[cycleIndex % symbols.count], total: symbols.count, index: cycleIndex % symbols.count)
                            .onTapGesture(count: 2) { env.openDetail(of: symbols[cycleIndex % symbols.count]) }
                            .onTapGesture { cycleIndex = (cycleIndex + 1) % max(symbols.count, 1) }
                    case .list:
                        FloatingListView(symbols: Array(symbols.prefix(8)))
                    case .card:
                        FloatingCardView(symbol: symbols[cycleIndex % symbols.count], total: symbols.count)
                            .onTapGesture(count: 2) { env.openDetail(of: symbols[cycleIndex % symbols.count]) }
                            .onTapGesture { cycleIndex = (cycleIndex + 1) % max(symbols.count, 1) }
                    }
                }
            }
            .frame(width: size.width, height: size.height)

            if hovered || env.ui.floatingCategoryOpen {
                HStack(spacing: 4) {
                    FloatingCategoryButton()
                    if style != .capsule {
                        Button {
                            env.prefs.floatingVisible = false
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.secondary)
                                .frame(width: 16, height: 16)
                                .background(Circle().fill(Color.primary.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(5)
                .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height)
        .background(shape.fill(.regularMaterial).opacity(prefs.floatingOpacity))
        .overlay(shape.strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5))
        .clipShape(shape)
        .opacity(hovered || categoryHovered || !prefs.floatingFade ? 1 : 0.72)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.18)) { hovered = inside }
            scheduleCollapse()
            // 鼠标离开整个悬浮窗,收起已展开的行
            // 分类面板展开/切换期间窗口尺寸变化会让悬停瞬间判空,此时不收起已展开的行
            if !inside, !env.ui.floatingCategoryOpen { withAnimation(.snappy(duration: 0.22)) { env.ui.floatingHoverSymbol = nil } }
        }
        .contextMenu { contextMenu }
    }

    @ViewBuilder
    private var contextMenu: some View {
        let prefs = env.prefs
        Picker("形态", selection: Bindable(prefs).floatingStyle) {
            ForEach(FloatingStyle.allCases) { Text($0.title).tag($0) }
        }
        Toggle("穿透锁定 (⌥⌘L 解除)", isOn: Bindable(prefs).floatingClickThrough)
        Toggle("移出后淡化", isOn: Bindable(prefs).floatingFade)
        Divider()
        Button("打开主面板") { env.openMainWindow?(false) }
        Button("偏好设置…") { env.openMainWindow?(true) }
        Button("关闭悬浮窗") { env.prefs.floatingVisible = false }
    }
}

// MARK: - 胶囊

/// 胶囊:单行显示「名称 价格 涨跌幅」,点击轮换下一只
struct FloatingCapsuleView: View {
    let symbol: StockSymbol
    let total: Int
    let index: Int
    private let env = AppEnvironment.shared

    var body: some View {
        let ticker = env.quotes.ticker(for: symbol)
        let quote = ticker.quote
        let trend = quote?.trend ?? .flat
        let color = trend == .flat ? Color.secondary : Theme.color(trend, redUp: env.prefs.redUp)
        HStack(spacing: 8) {
            Text(quote?.name ?? env.watchlist.firstItem(for: symbol)?.name ?? symbol.displayCode)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .frame(maxWidth: 78, alignment: .leading)
            Spacer(minLength: 0)
            PriceText(quote: quote, size: 13)
            Text(quote.map { Fmt.percent($0.changePercent) } ?? "--")
                .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(color)
                .frame(width: 58, alignment: .trailing)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 12)
        .tickFlash(ticker, cornerRadius: FloatingLayout.cornerRadius)
        .help(total > 1 ? "点击切换下一只 (\(index + 1)/\(total))" : "")
    }
}

// MARK: - 迷你列表

/// 迷你列表:鼠标悬停到哪一行,哪一行就展开显示分时图(同一时间只展开一行)。
/// 悬停行由鼠标 y 坐标与当前布局直接换算,而不是依赖视图的 onHover:
/// 展开/收起造成的行位移不会让鼠标"落到别的行"而引发反复展开抖动。
struct FloatingListView: View {
    let symbols: [StockSymbol]
    private let env = AppEnvironment.shared
    @State private var hoverTask: Task<Void, Never>?

    private static let rowHeight: CGFloat = 30
    private static let topPadding: CGFloat = 6

    var body: some View {
        VStack(spacing: 0) {
            ForEach(symbols) { symbol in
                FloatingListRow(symbol: symbol, expanded: env.ui.floatingHoverSymbol == symbol)
            }
        }
        .padding(.vertical, Self.topPadding)
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): target(rowAt: point.y)
            case .ended: break  // 离开整个悬浮窗由根视图统一收起
            }
        }
    }

    /// 按当前布局(已展开行高度 = 行高 + 展开区)找到 y 坐标所在行;展开区归属于该行
    /// - Parameter y: 鼠标在列表内的纵坐标
    /// - Returns: 行对应的标的,不在任何行内返回 nil
    private func symbol(atY y: CGFloat) -> StockSymbol? {
        var top = Self.topPadding
        for symbol in symbols {
            let height = Self.rowHeight + (env.ui.floatingHoverSymbol == symbol ? FloatingLayout.expandedExtra : 0)
            if y >= top && y < top + height { return symbol }
            top += height
        }
        return nil
    }

    /// 鼠标落在某行:与当前展开行不同则延迟切换(首次 250ms,行间切换 120ms),落回当前行取消切换
    private func target(rowAt y: CGFloat) {
        let hovered = symbol(atY: y)
        if hovered == nil || hovered == env.ui.floatingHoverSymbol {
            hoverTask?.cancel()
            return
        }
        guard hoverTask == nil || hoverTask?.isCancelled == true || pendingSymbol != hovered else { return }
        hoverTask?.cancel()
        pendingSymbol = hovered
        let delay: Duration = env.ui.floatingHoverSymbol == nil ? .milliseconds(250) : .milliseconds(120)
        hoverTask = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            // 与菜单栏 Popover 一致的弹性展开动画
            withAnimation(.snappy(duration: 0.22)) { env.ui.floatingHoverSymbol = hovered }
            pendingSymbol = nil
        }
    }
    @State private var pendingSymbol: StockSymbol?
}

struct FloatingListRow: View {
    let symbol: StockSymbol
    var expanded = false
    private let env = AppEnvironment.shared
    @State private var loader = MinuteLoader(store: AppEnvironment.shared.quotes)

    var body: some View {
        let ticker = env.quotes.ticker(for: symbol)
        let quote = ticker.quote
        let trend = quote?.trend ?? .flat
        let color = trend == .flat ? Color.secondary : Theme.color(trend, redUp: env.prefs.redUp)
        VStack(spacing: 0) {
            summaryRow(quote: quote, ticker: ticker, color: color)
                .frame(height: 30)
            if expanded { expandedPanel(quote) }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { env.openDetail(of: symbol) }
        // 走势线低频刷新(20 秒),窗口不可见时 Task 随视图销毁而取消;展开时同样复用该数据
        .task(id: symbol) { await loader.run(symbol: symbol, tradingInterval: 20) }
    }

    /// 展开的分时图与关键统计
    private func expandedPanel(_ quote: Quote?) -> some View {
        VStack(spacing: 4) {
            Sparkline(series: loader.series)
                .frame(height: 58)
                .overlay {
                    if loader.series == nil {
                        Text(loader.failed ? "分时加载失败" : "加载中…").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            if let q = quote {
                HStack {
                    stat("今开", Fmt.price(q.open, decimals: q.decimals))
                    stat("最高", Fmt.price(q.high, decimals: q.decimals))
                    stat("最低", Fmt.price(q.low, decimals: q.decimals))
                    stat("成交额", Fmt.amount(q.amount))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .frame(height: FloatingLayout.expandedExtra, alignment: .top)
        .transition(.opacity)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 1) {
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 10.5, weight: .medium).monospacedDigit())
        }
        .frame(maxWidth: .infinity)
    }

    private func summaryRow(quote: Quote?, ticker: QuoteTicker, color: Color) -> some View {
        HStack(spacing: 6) {
            Text(quote?.name ?? env.watchlist.firstItem(for: symbol)?.name ?? symbol.displayCode)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .frame(width: 70, alignment: .leading)
            Sparkline(series: loader.series, lineWidth: 1, showBaseline: false, showFill: false)
                .frame(width: 38, height: 16)
            Spacer(minLength: 0)
            PriceText(quote: quote, size: 12.5)
                .frame(width: 72, alignment: .trailing)
            Text(quote.map { Fmt.percent($0.changePercent) } ?? "--")
                .font(.system(size: 11.5, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(color)
                .frame(width: 52, alignment: .trailing)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 10)
        .tickFlash(ticker, cornerRadius: 6)
        .padding(.horizontal, 2)
    }
}

// MARK: - 卡片

struct FloatingCardView: View {
    let symbol: StockSymbol
    let total: Int
    private let env = AppEnvironment.shared
    @State private var loader = MinuteLoader(store: AppEnvironment.shared.quotes)

    var body: some View {
        let ticker = env.quotes.ticker(for: symbol)
        let quote = ticker.quote
        let trend = quote?.trend ?? .flat
        let color = trend == .flat ? Color.secondary : Theme.color(trend, redUp: env.prefs.redUp)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text(quote?.name ?? env.watchlist.firstItem(for: symbol)?.name ?? symbol.displayCode)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(symbol.displayCode).font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.trailing, 18)
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                PriceText(quote: quote, size: 25, weight: .bold)
                VStack(alignment: .leading, spacing: 0) {
                    Text(quote.map { Fmt.percent($0.changePercent) } ?? "--")
                    Text(quote.map { Fmt.signed($0.change, decimals: $0.decimals) } ?? "--")
                }
                .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(color)
            }
            Sparkline(series: loader.series, lineWidth: 1.2)
                .frame(height: 40)
            if let q = quote {
                HStack {
                    Text("高 \(Fmt.price(q.high, decimals: q.decimals))")
                    Spacer()
                    Text("低 \(Fmt.price(q.low, decimals: q.decimals))")
                }
                .font(.system(size: 9.5).monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .tickFlash(ticker, cornerRadius: FloatingLayout.cornerRadius)
        .task(id: symbol) { await loader.run(symbol: symbol, tradingInterval: 15) }
        .help(total > 1 ? "点击切换下一只" : "")
    }
}
