//
//  StockDetailView.swift
//  StockMenuBar
//
//  主面板右侧详情:大字号行情区、统计网格、分时图与成交量、五档盘口。
//  @author ixxxxoooo
//

import SwiftUI

struct StockDetailView: View {
    let item: WatchItem
    private let env = AppEnvironment.shared
    @State private var loader = MinuteLoader(store: AppEnvironment.shared.quotes)
    @State private var klineLoader = KLineLoader(store: AppEnvironment.shared.quotes)
    /// 图表模式:分时 / 日K / 周K / 月K
    @State private var chartMode: ChartMode = .minute
    /// 手动重试计数:变化时重启分时加载任务
    @State private var retryToken = 0

    var body: some View {
        let ticker = env.quotes.ticker(for: item.symbol)
        let quote = ticker.quote
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(quote)
                priceRow(quote, ticker: ticker)
                statsGrid(quote)
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            modePicker
                            Spacer()
                            if chartMode == .minute { legend }
                        }
                        if case .kline(let period) = chartMode {
                            KLineChartView(series: klineLoader.series, isLoading: klineLoader.isLoading, failed: klineLoader.failed) {
                                retryToken += 1
                            }
                            .id(period)
                        } else {
                            MinuteChartView(series: loader.series, isLoading: loader.isLoading, failed: loader.failed) {
                                retryToken += 1
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    if item.symbol.kind == .index {
                        IndexInfoView(symbol: item.symbol, quote: quote, series: loader.series)
                            .frame(width: 236)
                    } else if item.symbol.isFuture {
                        FuturesInfoView(symbol: item.symbol, quote: quote, series: loader.series)
                            .frame(width: 236)
                    } else {
                        OrderBookView(quote: quote)
                            .frame(width: 236)
                    }
                }
            }
            .padding(24)
        }
        .task(id: "\(item.symbol.full)#\(retryToken)") {
            await loader.run(symbol: item.symbol, tradingInterval: 10)
        }
        .task(id: "\(item.symbol.full)#\(chartMode.id)#\(retryToken)") {
            guard case .kline(let period) = chartMode else { return }
            await klineLoader.run(symbol: item.symbol, period: period)
        }
        .onChange(of: item.symbol) { chartMode = .minute }
    }

    /// 分时 / 日K / 周K / 月K 切换
    private var modePicker: some View {
        Picker("图表", selection: $chartMode) {
            ForEach(ChartMode.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    // MARK: - 头部

    private func header(_ quote: Quote?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(quote?.name ?? item.name).font(.system(size: 22, weight: .bold))
            Text("\(item.symbol.marketTag) \(item.symbol.displayCode)")
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(.secondary)
            KindTag(kind: item.symbol.kind)
            Spacer()
            toggleButton(env.prefs.isPinned(item.symbol), on: "pin.fill", off: "pin", help: "固定到菜单栏显示") {
                env.prefs.togglePinned(item.symbol)
                env.consumersChanged()
            }
            toggleButton(env.prefs.isInFloating(item.symbol), on: "rectangle.on.rectangle.fill", off: "rectangle.on.rectangle", help: "加入悬浮迷你窗") {
                env.prefs.toggleFloating(item.symbol)
            }
        }
    }

    private func toggleButton(_ active: Bool, on: String, off: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: active ? on : off)
                .font(.system(size: 14))
                .foregroundStyle(active ? Color.accentColor : Color.secondary)
                .frame(width: 30, height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(active ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(help)
    }

    // MARK: - 价格行

    private func priceRow(_ quote: Quote?, ticker: QuoteTicker) -> some View {
        let trend = quote?.trend ?? .flat
        let color = trend == .flat ? Color.primary : Theme.color(trend, redUp: env.prefs.redUp)
        return HStack(alignment: .lastTextBaseline, spacing: 16) {
            PriceText(quote: quote, size: 46, weight: .bold)
                .padding(.horizontal, 6)
                .tickFlash(ticker, cornerRadius: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(quote.map { Fmt.signed($0.change, decimals: $0.decimals) } ?? "--")
                    .font(.system(size: 18, weight: .semibold, design: .rounded).monospacedDigit())
                Text(quote.map { Fmt.percent($0.changePercent) } ?? "--")
                    .font(.system(size: 18, weight: .semibold, design: .rounded).monospacedDigit())
            }
            .foregroundStyle(color)
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(timeText(quote)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                if let source = quote?.source {
                    Label(source.displayName, systemImage: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func timeText(_ quote: Quote?) -> String {
        if let t = quote?.time {
            let day = ChinaTime.isSameDay(t, Date()) ? "" : ChinaTime.dayString(t) + " "
            return "行情时间 \(day)\(Fmt.clock(t))"
        }
        if let t = env.quotes.lastUpdate { return "更新于 \(Fmt.clock(t))" }
        return "等待行情"
    }

    // MARK: - 统计

    /// 统计格:只展示有数据的字段(指数无成交量/换手率、期货无换手率时直接隐藏,不显示 --)
    private func statsGrid(_ quote: Quote?) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)
        let isFuture = item.symbol.kind == .future
        let prevTitle = isFuture ? "昨结" : "昨收"
        return LazyVGrid(columns: columns, spacing: 12) {
            if let q = quote {
                if q.open > 0 { stat("今开", Fmt.price(q.open, decimals: q.decimals), reference: q) }
                stat(prevTitle, Fmt.price(q.prevClose, decimals: q.decimals), reference: nil)
                stat("最高", Fmt.price(q.high, decimals: q.decimals), reference: q, value: q.high)
                stat("最低", Fmt.price(q.low, decimals: q.decimals), reference: q, value: q.low)
                if q.volume > 0 { stat("成交量", volumeText(q), reference: nil) }
                if q.amount > 0 { stat("成交额", Fmt.amount(q.amount), reference: nil) }
                if isFuture, let oi = q.openInterest, oi > 0 { stat("持仓量", Fmt.volume(oi), reference: nil) }
                if !isFuture, let turnover = q.turnover { stat("换手率", Fmt.plainPercent(turnover), reference: nil) }
                if q.prevClose > 0, q.high > q.low {
                    stat("振幅", Fmt.plainPercent((q.high - q.low) / q.prevClose * 100), reference: nil)
                }
            } else {
                ForEach(["今开", prevTitle, "最高", "最低"], id: \.self) { stat($0, "--", reference: nil) }
            }
        }
    }

    /// 成交量文本:全球指数(美股指数等)以股计,其余以手计
    private func volumeText(_ q: Quote) -> String {
        guard q.symbol.isFuture, q.symbol.kind == .index else { return Fmt.volume(q.volume) }
        return q.volume >= 100_000_000 ? String(format: "%.2f亿股", q.volume / 100_000_000)
            : (q.volume >= 10_000 ? String(format: "%.2f万股", q.volume / 10_000) : String(format: "%.0f股", q.volume))
    }

    /// 单个统计格;传入 reference 时按相对昨收着色
    private func stat(_ title: String, _ text: String, reference: Quote?, value: Double? = nil) -> some View {
        var color = Color.primary
        if let q = reference {
            let v = value ?? q.open
            color = Theme.color(Theme.trend(of: v - q.prevClose, epsilon: 1e-9), redUp: env.prefs.redUp)
            if abs(v - q.prevClose) < 1e-9 { color = .primary }
        }
        return VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(text).font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    private var legend: some View {
        HStack(spacing: 10) {
            legendItem("分时", color: Theme.color(.up, redUp: env.prefs.redUp))
            legendItem("均价", color: .orange)
            legendItem(item.symbol.kind == .future ? "昨结" : "昨收", color: .secondary)
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
    }

    private func legendItem(_ text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Capsule().fill(color).frame(width: 12, height: 2)
            Text(text)
        }
    }
}

/// 期货合约信息面板:替代 A 股的五档盘口(期货免费源不提供五档)
struct FuturesInfoView: View {
    let symbol: StockSymbol
    let quote: Quote?
    let series: MinuteSeries?
    private let prefs = AppEnvironment.shared.prefs

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("合约信息").font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            if symbol.kind == .index {
                info("市场", "全球指数")
                info("代码", symbol.displayCode)
            } else {
                info("交易所", symbol.marketTag)
                info("合约", symbol.displayCode)
                info("昨结算", quote.map { Fmt.price($0.prevClose, decimals: $0.decimals) } ?? "--")
                if let oi = quote?.openInterest, oi > 0 { info("持仓量", Fmt.volume(oi)) }
            }
            if let series {
                Divider()
                Text("交易时段").font(.system(size: 11)).foregroundStyle(.secondary)
                ForEach(series.axis.sessionTexts, id: \.self) { text in
                    Text(text).font(.system(size: 12).monospacedDigit())
                }
            }
            Divider()
            Text(note).font(.system(size: 10.5)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 280, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    private var note: String {
        symbol.kind == .index
            ? "涨跌幅按前收盘价计算。"
            : "涨跌幅按昨结算价计算;没有数据的字段已隐藏。免费数据源不提供期货五档盘口。"
    }

    private func info(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(size: 12.5, weight: .medium).monospacedDigit())
        }
    }
}

/// 详情图表模式
enum ChartMode: Hashable, Identifiable {
    case minute
    case kline(KLinePeriod)

    static let allCases: [ChartMode] = [.minute] + KLinePeriod.allCases.map { .kline($0) }

    var id: String {
        switch self {
        case .minute: return "minute"
        case .kline(let p): return p.rawValue
        }
    }

    var title: String {
        switch self {
        case .minute: return "分时"
        case .kline(let p): return p.title
        }
    }
}
