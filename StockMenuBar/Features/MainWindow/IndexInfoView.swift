//
//  IndexInfoView.swift
//  StockMenuBar
//
//  指数概览面板:指数没有五档盘口,改为展示日内区间位置、相对开盘/昨收的表现、交易时段与可用数据源。
//  @author ixxxxoooo
//

import SwiftUI

struct IndexInfoView: View {
    let symbol: StockSymbol
    let quote: Quote?
    let series: MinuteSeries?
    private let prefs = AppEnvironment.shared.prefs

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("指数概览").font(.system(size: 13, weight: .semibold))
            if let q = quote, q.high > q.low {
                rangeBar(q)
            }
            if let q = quote {
                if q.open > 0 { info("较开盘", Fmt.percent((q.price - q.open) / q.open * 100), trendOf: q.price - q.open) }
                info("较前收", Fmt.signed(q.change, decimals: q.decimals), trendOf: q.change)
                if q.prevClose > 0, q.high > q.low {
                    info("日内振幅", Fmt.plainPercent((q.high - q.low) / q.prevClose * 100))
                }
            }
            info("市场", symbol.isFuture ? "全球指数" : "A 股指数")
            info("代码", symbol.displayCode)
            if let series {
                Divider()
                Text(symbol.isFuture ? "交易时段(交易所当地时间)" : "交易时段").font(.system(size: 11)).foregroundStyle(.secondary)
                ForEach(series.axis.sessionTexts, id: \.self) { text in
                    Text(text).font(.system(size: 12).monospacedDigit())
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("数据源").font(.system(size: 11)).foregroundStyle(.secondary)
                Text(sourceNames.joined(separator: " · ")).font(.system(size: 12))
                Text("指数没有五档盘口;涨跌幅按前收盘价计算,没有数据的字段已隐藏。")
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 280, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    /// 该标的可用的数据源名称(按预置目录的映射推导)
    private var sourceNames: [String] {
        guard symbol.isFuture else { return [ProviderID.tencent, .sina, .eastmoney].map(\.displayName) }
        var names: [String] = []
        if FuturesCatalog.eastmoneySupports(secid: symbol.code) { names.append(ProviderID.eastmoney.displayName) }
        if FuturesCatalog.sinaMapping(secid: symbol.code) != nil { names.append(ProviderID.sina.displayName) }
        if FuturesCatalog.tencentCode(secid: symbol.code) != nil { names.append(ProviderID.tencent.displayName) }
        if FuturesCatalog.yahooCode(secid: symbol.code) != nil { names.append(ProviderID.yahoo.displayName) }
        return names
    }

    /// 日内区间条:当前价在最低-最高之间的位置
    private func rangeBar(_ q: Quote) -> some View {
        let ratio = min(max((q.price - q.low) / (q.high - q.low), 0), 1)
        let tint = Theme.color(q.trend == .flat ? .up : q.trend, redUp: prefs.redUp)
        return VStack(spacing: 5) {
            HStack {
                Text(Fmt.price(q.low, decimals: q.decimals))
                Spacer()
                Text("日内区间").foregroundStyle(.tertiary)
                Spacer()
                Text(Fmt.price(q.high, decimals: q.decimals))
            }
            .font(.system(size: 10.5).monospacedDigit())
            .foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.10)).frame(height: 5)
                    Circle().fill(tint).frame(width: 11, height: 11)
                        .offset(x: max(geo.size.width - 11, 0) * ratio)
                }
            }
            .frame(height: 11)
        }
    }

    private func info(_ title: String, _ value: String, trendOf change: Double? = nil) -> some View {
        var color = Color.primary
        if let change, abs(change) > 1e-9 { color = Theme.color(change > 0 ? .up : .down, redUp: prefs.redUp) }
        return HStack {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(size: 12.5, weight: .medium).monospacedDigit()).foregroundStyle(color)
        }
    }
}
