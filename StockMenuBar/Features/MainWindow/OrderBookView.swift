//
//  OrderBookView.swift
//  StockMenuBar
//
//  五档盘口(A 股特色):卖五至卖一、买一至买五,挂单量用比例条可视化。
//  @author ixxxxoooo
//

import SwiftUI

struct OrderBookView: View {
    let quote: Quote?
    private let prefs = AppEnvironment.shared.prefs

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("五档盘口").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("价格 / 手").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .padding(.bottom, 8)

            if let quote, !quote.asks.isEmpty || !quote.bids.isEmpty {
                let maxVolume = max((quote.asks + quote.bids).map(\.volume).max() ?? 1, 1)
                ForEach((1...5).reversed(), id: \.self) { n in
                    row("卖\(n)", level: n <= quote.asks.count ? quote.asks[n - 1] : nil, quote: quote, maxVolume: maxVolume, isAsk: true)
                }
                Divider().padding(.vertical, 5)
                ForEach(1...5, id: \.self) { n in
                    row("买\(n)", level: n <= quote.bids.count ? quote.bids[n - 1] : nil, quote: quote, maxVolume: maxVolume, isAsk: false)
                }
                buyerSellerRatio(quote)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "list.number").font(.system(size: 20)).foregroundStyle(.tertiary)
                    Text(emptyHint).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    private var emptyHint: String {
        guard let quote else { return "等待行情…" }
        if quote.symbol.kind == .index { return "指数没有盘口数据" }
        if quote.source == .eastmoney { return "当前数据源(东财)不含五档\n待腾讯/新浪恢复后自动显示" }
        return "暂无盘口数据"
    }

    private func row(_ title: String, level: PriceLevel?, quote: Quote, maxVolume: Double, isAsk: Bool) -> some View {
        let barColor = Theme.color(isAsk ? .down : .up, redUp: prefs.redUp)
        let trend = level.map { Theme.trend(of: $0.price - quote.prevClose, epsilon: 1e-9) } ?? .flat
        return HStack(spacing: 6) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 24, alignment: .leading)
            Text(level.map { Fmt.price($0.price, decimals: quote.decimals) } ?? "--")
                .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                .foregroundStyle(trend == .flat ? Color.primary : Theme.color(trend, redUp: prefs.redUp))
            Spacer(minLength: 4)
            Text(level.map { Fmt.depthVolume($0.volume) } ?? "--")
                .font(.system(size: 11.5).monospacedDigit())
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 2)
        .background(alignment: .trailing) {
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 3)
                    .fill(barColor.opacity(0.14))
                    .frame(width: geo.size.width * CGFloat((level?.volume ?? 0) / maxVolume))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    /// 委比条:买盘量占比
    private func buyerSellerRatio(_ quote: Quote) -> some View {
        let buy = quote.bids.reduce(0) { $0 + $1.volume }
        let sell = quote.asks.reduce(0) { $0 + $1.volume }
        let total = max(buy + sell, 1)
        let ratio = buy / total
        return VStack(spacing: 4) {
            HStack {
                Text("买盘 \(Int(ratio * 100))%").foregroundStyle(Theme.color(.up, redUp: prefs.redUp))
                Spacer()
                Text("卖盘 \(Int((1 - ratio) * 100))%").foregroundStyle(Theme.color(.down, redUp: prefs.redUp))
            }
            .font(.system(size: 10))
            GeometryReader { geo in
                HStack(spacing: 1) {
                    Rectangle().fill(Theme.color(.up, redUp: prefs.redUp)).frame(width: geo.size.width * ratio)
                    Rectangle().fill(Theme.color(.down, redUp: prefs.redUp))
                }
                .clipShape(Capsule())
            }
            .frame(height: 4)
        }
        .padding(.top, 10)
    }
}
