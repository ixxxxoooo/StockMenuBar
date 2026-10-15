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

    /// 各形态的窗口内容尺寸
    /// - Parameters:
    ///   - style: 形态
    ///   - count: 监控的标的数
    static func size(style: FloatingStyle, count: Int) -> CGSize {
        switch style {
        case .capsule: return CGSize(width: 232, height: 34)
        case .list: return CGSize(width: 280, height: CGFloat(max(min(count, 8), 1)) * 30 + 12)
        case .card: return CGSize(width: 206, height: 132)
        }
    }
}

struct FloatingRootView: View {
    private let env = AppEnvironment.shared
    @State private var hovered = false
    @State private var cycleIndex = 0

    var body: some View {
        let prefs = env.prefs
        let symbols = env.floatingSymbols
        let style = prefs.floatingStyle
        let size = FloatingLayout.size(style: style, count: symbols.count)
        let shape = RoundedRectangle(cornerRadius: FloatingLayout.cornerRadius, style: .continuous)

        ZStack(alignment: .topTrailing) {
            Group {
                if symbols.isEmpty {
                    Text("暂无标的,请先添加自选")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    switch style {
                    case .capsule:
                        FloatingCapsuleView(symbol: symbols[cycleIndex % symbols.count], total: symbols.count, index: cycleIndex % symbols.count)
                            .onTapGesture { cycleIndex = (cycleIndex + 1) % max(symbols.count, 1) }
                    case .list:
                        FloatingListView(symbols: Array(symbols.prefix(8)))
                    case .card:
                        FloatingCardView(symbol: symbols[cycleIndex % symbols.count], total: symbols.count)
                            .onTapGesture { cycleIndex = (cycleIndex + 1) % max(symbols.count, 1) }
                    }
                }
            }
            .frame(width: size.width, height: size.height)

            if hovered && style != .capsule {
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
                .padding(5)
                .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height)
        .background(shape.fill(.regularMaterial).opacity(prefs.floatingOpacity))
        .overlay(shape.strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5))
        .clipShape(shape)
        .opacity(hovered || !prefs.floatingFade ? 1 : 0.72)
        .onHover { inside in withAnimation(.easeOut(duration: 0.18)) { hovered = inside } }
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
            Text(quote?.name ?? env.watchlist.firstItem(for: symbol)?.name ?? symbol.code)
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

struct FloatingListView: View {
    let symbols: [StockSymbol]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(symbols) { symbol in
                FloatingListRow(symbol: symbol)
                    .frame(height: 30)
            }
        }
        .padding(.vertical, 6)
    }
}

struct FloatingListRow: View {
    let symbol: StockSymbol
    private let env = AppEnvironment.shared
    @State private var loader = MinuteLoader(store: AppEnvironment.shared.quotes)

    var body: some View {
        let ticker = env.quotes.ticker(for: symbol)
        let quote = ticker.quote
        let trend = quote?.trend ?? .flat
        let color = trend == .flat ? Color.secondary : Theme.color(trend, redUp: env.prefs.redUp)
        HStack(spacing: 6) {
            Text(quote?.name ?? env.watchlist.firstItem(for: symbol)?.name ?? symbol.code)
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
        // 走势线低频刷新(20 秒),窗口不可见时 Task 随视图销毁而取消
        .task(id: symbol) { await loader.run(symbol: symbol, tradingInterval: 20) }
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
                Text(quote?.name ?? env.watchlist.firstItem(for: symbol)?.name ?? symbol.code)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(symbol.code).font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
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
