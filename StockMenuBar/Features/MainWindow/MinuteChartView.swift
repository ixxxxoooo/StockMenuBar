//
//  MinuteChartView.swift
//  StockMenuBar
//
//  Swift Charts 原生绘制的当日分时图:昨收中轴线、分时线、面积阴影、均价线、十字光标,
//  下方对齐的成交量柱状图。
//  @author ixxxxoooo
//

import Charts
import SwiftUI

/// 让两张图共享悬停十字光标
private struct ChartHoverModifier: ViewModifier {
    @Binding var hoverIndex: Int?
    /// 横轴最大序号(A 股 240,期货按品种时段)
    let maxIndex: Int

    func body(content: Content) -> some View {
        content.chartOverlay { proxy in
            GeometryReader { geo in
                Color.clear
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let frame = proxy.plotFrame else { return }
                            let x = location.x - geo[frame].origin.x
                            if let value: Double = proxy.value(atX: x) {
                                hoverIndex = min(max(Int(value.rounded()), 0), maxIndex)
                            }
                        case .ended:
                            hoverIndex = nil
                        }
                    }
            }
        }
    }
}

struct MinuteChartView: View {
    let series: MinuteSeries?
    let isLoading: Bool
    let failed: Bool
    /// 加载失败时的手动重试(为空则不显示按钮)
    var retry: (() -> Void)?
    @State private var hoverIndex: Int?
    private let prefs = AppEnvironment.shared.prefs

    /// 左右轴标签固定宽度,保证价格图与成交量图的绘图区对齐
    private static let leftAxisWidth: CGFloat = 62
    private static let rightAxisWidth: CGFloat = 54

    var body: some View {
        if let series, !series.bars.isEmpty {
            VStack(spacing: 4) {
                priceChart(series)
                    .frame(minHeight: 260)
                // 没有成交量数据(部分指数/外盘源)时隐藏量能图,避免一块空白
                if series.bars.contains(where: { $0.volume > 0 }) {
                    volumeChart(series)
                        .frame(height: 92)
                }
            }
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04))
                if isLoading {
                    ProgressView()
                } else {
                    VStack(spacing: 10) {
                        Label(failed ? "分时数据加载失败,正在自动重试…" : "暂无分时数据", systemImage: "chart.xyaxis.line")
                            .foregroundStyle(.secondary)
                        if failed, let retry {
                            Button("立即重试", action: retry).controlSize(.small)
                        }
                    }
                }
            }
            .frame(height: 360)
        }
    }

    // MARK: - 价格图

    private func priceChart(_ series: MinuteSeries) -> some View {
        let prev = series.prevClose
        let range = MinuteScale.range(prevClose: prev, prices: series.bars.map(\.price))
        let dev = (range.hi - prev) / 1.08
        let ticks = (-2...2).map { prev + dev * Double($0) / 2 }
        let trend = Sparkline.trend(of: series)
        let color = Theme.color(trend, redUp: prefs.redUp)
        let decimals = series.decimals
        let axis = series.axis
        let hoverBar = hoverIndex.flatMap { h in series.bars.last { $0.index <= h } }

        return Chart {
            ForEach(series.bars) { bar in
                AreaMark(x: .value("时间", bar.index),
                         yStart: .value("基线", range.lo),
                         yEnd: .value("价格", bar.price))
                    .foregroundStyle(LinearGradient(colors: [color.opacity(0.30), color.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
            }
            ForEach(series.bars) { bar in
                LineMark(x: .value("时间", bar.index), y: .value("价格", bar.price), series: .value("线", "价格"))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
            ForEach(series.bars.filter { $0.avgPrice != nil }) { bar in
                LineMark(x: .value("时间", bar.index), y: .value("均价", bar.avgPrice ?? bar.price), series: .value("线", "均价"))
                    .foregroundStyle(Color.orange)
                    .lineStyle(StrokeStyle(lineWidth: 1.0))
            }
            RuleMark(y: .value("昨收", prev))
                .foregroundStyle(Color.secondary.opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            if let bar = hoverBar {
                RuleMark(x: .value("时间", bar.index))
                    .foregroundStyle(Color.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 0.8))
                    .annotation(position: .top, alignment: .center, spacing: 2,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        tooltip(bar, prev: prev, decimals: decimals, axis: axis)
                    }
                PointMark(x: .value("时间", bar.index), y: .value("价格", bar.price))
                    .foregroundStyle(color)
                    .symbolSize(40)
            }
        }
        .chartXScale(domain: 0...axis.total)
        .chartYScale(domain: range.lo...range.hi)
        .chartXAxis {
            AxisMarks(values: axis.tickIndices) { value in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.18))
                // 末尾刻度(收盘)右对齐,避免被绘图区右侧轴标签挤掉
                AxisValueLabel(anchor: value.as(Int.self) == axis.total ? .topTrailing : .top, horizontalSpacing: 0) {
                    if let i = value.as(Int.self) {
                        Text(axis.tickLabel(index: i)).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: ticks) { value in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.18))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(Fmt.price(v, decimals: decimals))
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(Theme.color(Theme.trend(of: v - prev, epsilon: 1e-9), redUp: prefs.redUp))
                            .frame(width: Self.leftAxisWidth, alignment: .trailing)
                    }
                }
            }
            AxisMarks(position: .trailing, values: ticks) { value in
                AxisValueLabel {
                    if let v = value.as(Double.self), prev > 0 {
                        let pct = (v - prev) / prev * 100
                        Text(Fmt.percent(pct))
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(Theme.color(Theme.trend(of: pct, epsilon: 1e-9), redUp: prefs.redUp))
                            .frame(width: Self.rightAxisWidth, alignment: .leading)
                    }
                }
            }
        }
        .chartPlotStyle { plot in
            plot.background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.025)))
        }
        .modifier(ChartHoverModifier(hoverIndex: $hoverIndex, maxIndex: series.axis.total))
    }

    /// 悬停提示
    private func tooltip(_ bar: MinuteBar, prev: Double, decimals: Int, axis: MinuteAxis) -> some View {
        let pct = prev > 0 ? (bar.price - prev) / prev * 100 : 0
        let trend = Theme.trend(of: bar.price - prev, epsilon: 1e-9)
        return VStack(alignment: .leading, spacing: 1) {
            Text(axis.label(index: bar.index)).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(Fmt.price(bar.price, decimals: decimals)).fontWeight(.semibold)
                Text(Fmt.percent(pct))
            }
            .foregroundStyle(Theme.color(trend, redUp: prefs.redUp))
            if let avg = bar.avgPrice {
                Text("均 \(Fmt.price(avg, decimals: decimals))").foregroundStyle(.orange)
            }
            Text("量 \(Fmt.volume(bar.volume))").foregroundStyle(.secondary)
        }
        .font(.system(size: 10.5).monospacedDigit())
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5))
    }

    // MARK: - 成交量图

    private func volumeChart(_ series: MinuteSeries) -> some View {
        let bars = series.bars
        let axis = series.axis
        // 价格不低于上一分钟记为上涨量
        let ups: [Bool] = bars.enumerated().map { i, bar in
            i == 0 ? bar.price >= series.prevClose : bar.price >= bars[i - 1].price
        }
        let maxVolume = max(bars.map(\.volume).max() ?? 1, 1)
        let upColor = Theme.color(.up, redUp: prefs.redUp)
        let downColor = Theme.color(.down, redUp: prefs.redUp)
        let hover = hoverIndex

        return Chart {
            ForEach(Array(bars.enumerated()), id: \.element.id) { i, bar in
                BarMark(x: .value("时间", bar.index), y: .value("成交量", bar.volume), width: .fixed(2))
                    .foregroundStyle(ups[i] ? upColor : downColor)
                    .opacity(hover == nil || hover == bar.index ? 1 : 0.55)
            }
            if let hover {
                RuleMark(x: .value("时间", hover))
                    .foregroundStyle(Color.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 0.8))
            }
        }
        .chartXScale(domain: 0...axis.total)
        .chartYScale(domain: 0...(maxVolume * 1.1))
        .chartXAxis {
            AxisMarks(values: axis.tickIndices) { _ in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.18))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [maxVolume]) { value in
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(Fmt.volume(v)).font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: Self.leftAxisWidth, alignment: .trailing)
                    }
                }
            }
            AxisMarks(position: .trailing, values: [0]) { _ in
                AxisValueLabel {
                    Text(" ").frame(width: Self.rightAxisWidth, alignment: .leading)
                }
            }
        }
        .chartPlotStyle { plot in
            plot.background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.025)))
        }
        .modifier(ChartHoverModifier(hoverIndex: $hoverIndex, maxIndex: series.axis.total))
    }
}
