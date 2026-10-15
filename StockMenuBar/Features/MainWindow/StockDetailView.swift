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
                            Text("当日分时").font(.system(size: 13, weight: .semibold))
                            Spacer()
                            legend
                        }
                        MinuteChartView(series: loader.series, isLoading: loader.isLoading, failed: loader.failed)
                    }
                    .frame(maxWidth: .infinity)
                    OrderBookView(quote: quote)
                        .frame(width: 236)
                }
            }
            .padding(24)
        }
        .task(id: item.symbol) {
            await loader.run(symbol: item.symbol, tradingInterval: 10)
        }
    }

    // MARK: - 头部

    private func header(_ quote: Quote?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(quote?.name ?? item.name).font(.system(size: 22, weight: .bold))
            Text("\(item.symbol.market.rawValue.uppercased()) \(item.symbol.code)")
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

    private func statsGrid(_ quote: Quote?) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)
        return LazyVGrid(columns: columns, spacing: 12) {
            if let q = quote {
                stat("今开", Fmt.price(q.open, decimals: q.decimals), reference: q)
                stat("昨收", Fmt.price(q.prevClose, decimals: q.decimals), reference: nil)
                stat("最高", Fmt.price(q.high, decimals: q.decimals), reference: q, value: q.high)
                stat("最低", Fmt.price(q.low, decimals: q.decimals), reference: q, value: q.low)
                stat("成交量", Fmt.volume(q.volume), reference: nil)
                stat("成交额", Fmt.amount(q.amount), reference: nil)
                stat("换手率", q.turnover.map(Fmt.plainPercent) ?? "--", reference: nil)
                stat("振幅", q.prevClose > 0 ? Fmt.plainPercent((q.high - q.low) / q.prevClose * 100) : "--", reference: nil)
            } else {
                ForEach(["今开", "昨收", "最高", "最低", "成交量", "成交额", "换手率", "振幅"], id: \.self) { stat($0, "--", reference: nil) }
            }
        }
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
            legendItem("昨收", color: .secondary)
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
