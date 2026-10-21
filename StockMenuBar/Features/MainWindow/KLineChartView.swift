//
//  KLineChartView.swift
//  StockMenuBar
//
//  Swift Charts 绘制的日/周/月 K 线:蜡烛图 + MA5/10/20 均线 + 十字光标,
//  下方对齐的成交量柱状图;顶部显示光标(或最新一根)的开高低收与涨跌。
//  @author ixxxxoooo
//

import Charts
import SwiftUI

struct KLineChartView: View {
    let series: KLineSeries?
    let isLoading: Bool
    let failed: Bool
    var retry: (() -> Void)?
    @State private var hoverIndex: Int?
    private let prefs = AppEnvironment.shared.prefs

    private static let leftAxisWidth: CGFloat = 62
    /// 均线周期与配色
    static let maLines: [(n: Int, color: Color)] = [(5, .orange), (10, .blue), (20, .purple)]

    /// 展示窗口:最近 N 根及其均线
    private struct Window {
        let bars: [KLineBar]
        let offset: Int
        let mas: [[Double?]]
    }

    /// 截取展示窗口;均线基于完整序列计算后再截取,保证窗口首根就有值
    private func window(_ series: KLineSeries) -> Window {
        let offset = max(series.bars.count - KLineConfig.visibleCount, 0)
        let mas = Self.maLines.map { Array(series.movingAverage($0.n).dropFirst(offset)) }
        return Window(bars: Array(series.bars.dropFirst(offset)), offset: offset, mas: mas)
    }

    var body: some View {
        if let series, !series.bars.isEmpty {
            let w = window(series)
            VStack(spacing: 6) {
                infoBar(series, w)
                priceChart(series, w).frame(minHeight: 260)
                if w.bars.contains(where: { $0.volume > 0 }) {
                    volumeChart(w).frame(height: 92)
                }
            }
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04))
                if isLoading {
                    ProgressView()
                } else {
                    VStack(spacing: 10) {
                        Label(failed ? "K 线加载失败,正在自动重试…" : "暂无 K 线数据", systemImage: "chart.bar.xaxis")
                            .foregroundStyle(.secondary)
                        if failed, let retry { Button("立即重试", action: retry).controlSize(.small) }
                    }
                }
            }
            .frame(height: 360)
        }
    }

    // MARK: - 信息栏

    /// 光标所在(默认最新)一根 K 线的数值与均线
    private func infoBar(_ series: KLineSeries, _ w: Window) -> some View {
        let i = min(max(hoverIndex ?? (w.bars.count - 1), 0), w.bars.count - 1)
        let bar = w.bars[i]
        let prevClose = i > 0 ? w.bars[i - 1].close : (w.offset > 0 ? series.bars[w.offset - 1].close : bar.open)
        let change = bar.close - prevClose
        let color = Theme.color(Theme.trend(of: change, epsilon: 1e-9), redUp: prefs.redUp)
        let d = series.decimals
        return HStack(spacing: 12) {
            Text(bar.date).foregroundStyle(.secondary)
            item("开", Fmt.price(bar.open, decimals: d), color)
            item("高", Fmt.price(bar.high, decimals: d), color)
            item("低", Fmt.price(bar.low, decimals: d), color)
            item("收", Fmt.price(bar.close, decimals: d), color)
            if prevClose > 0 { item("幅", Fmt.percent(change / prevClose * 100), color) }
            Spacer(minLength: 8)
            ForEach(Array(Self.maLines.enumerated()), id: \.offset) { k, line in
                if let v = w.mas[k][i] {
                    Text("MA\(line.n) \(Fmt.price(v, decimals: d))").foregroundStyle(line.color)
                }
            }
        }
        .font(.system(size: 10.5).monospacedDigit())
        .lineLimit(1)
        .padding(.leading, 4)
    }

    private func item(_ title: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Text(title).foregroundStyle(.secondary)
            Text(value).foregroundStyle(color)
        }
    }

    // MARK: - 价格图

    /// 蜡烛宽度:按根数估算,留出间隙
    private func candleWidth(count: Int) -> MarkDimension {
        .fixed(max(1.5, (CGFloat(600) / CGFloat(max(count, 1))) * 0.65))
    }

    private func priceChart(_ series: KLineSeries, _ w: Window) -> some View {
        let bars = w.bars
        let maValues = w.mas.flatMap { $0.compactMap { $0 } }
        let lo = (bars.map(\.low) + maValues).min() ?? 0
        let hi = (bars.map(\.high) + maValues).max() ?? 1
        let pad = max((hi - lo) * 0.06, 1e-6)
        let d = series.decimals
        let upColor = Theme.color(.up, redUp: prefs.redUp)
        let downColor = Theme.color(.down, redUp: prefs.redUp)
        let hover = hoverIndex

        return Chart {
            ForEach(Array(bars.enumerated()), id: \.element.id) { i, bar in
                let color = bar.isUp ? upColor : downColor
                RuleMark(x: .value("序", i), yStart: .value("低", bar.low), yEnd: .value("高", bar.high))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1))
                // 开收相等(一字/十字)时给实体一个极小厚度,避免不可见
                RectangleMark(x: .value("序", i), yStart: .value("开", bar.open),
                              yEnd: .value("收", bar.open == bar.close ? bar.close + pad * 0.02 : bar.close),
                              width: candleWidth(count: bars.count))
                    .foregroundStyle(color)
            }
            ForEach(Array(Self.maLines.enumerated()), id: \.offset) { k, line in
                ForEach(Array(w.mas[k].enumerated()), id: \.offset) { i, v in
                    if let v {
                        LineMark(x: .value("序", i), y: .value("MA", v), series: .value("线", "MA\(line.n)"))
                            .foregroundStyle(line.color)
                            .lineStyle(StrokeStyle(lineWidth: 1))
                    }
                }
            }
            if let hover, hover < bars.count {
                RuleMark(x: .value("序", hover))
                    .foregroundStyle(Color.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 0.8))
            }
        }
        .chartXScale(domain: -1...bars.count)
        .chartYScale(domain: (lo - pad)...(hi + pad))
        .chartXAxis {
            AxisMarks(values: Self.tickIndices(count: bars.count)) { value in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.18))
                AxisValueLabel {
                    if let i = value.as(Int.self), i < bars.count {
                        Text(Self.dateLabel(bars[i].date, period: series.period))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.18))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(Fmt.price(v, decimals: d)).font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: Self.leftAxisWidth, alignment: .trailing)
                    }
                }
            }
        }
        .chartPlotStyle { $0.background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.025))) }
        .modifier(ChartHoverModifier(hoverIndex: $hoverIndex, maxIndex: max(bars.count - 1, 0)))
    }

    // MARK: - 成交量图

    private func volumeChart(_ w: Window) -> some View {
        let bars = w.bars
        let maxVolume = max(bars.map(\.volume).max() ?? 1, 1)
        let upColor = Theme.color(.up, redUp: prefs.redUp)
        let downColor = Theme.color(.down, redUp: prefs.redUp)
        let hover = hoverIndex
        return Chart {
            ForEach(Array(bars.enumerated()), id: \.element.id) { i, bar in
                BarMark(x: .value("序", i), y: .value("量", bar.volume), width: candleWidth(count: bars.count))
                    .foregroundStyle(bar.isUp ? upColor : downColor)
                    .opacity(hover == nil || hover == i ? 1 : 0.55)
            }
            if let hover, hover < bars.count {
                RuleMark(x: .value("序", hover))
                    .foregroundStyle(Color.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 0.8))
            }
        }
        .chartXScale(domain: -1...bars.count)
        .chartYScale(domain: 0...(maxVolume * 1.1))
        .chartXAxis {
            AxisMarks(values: Self.tickIndices(count: bars.count)) { _ in
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
        }
        .chartPlotStyle { $0.background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.025))) }
        .modifier(ChartHoverModifier(hoverIndex: $hoverIndex, maxIndex: max(bars.count - 1, 0)))
    }

    // MARK: - 辅助

    /// 横轴刻度:首尾及中间均分共 5 档
    static func tickIndices(count: Int) -> [Int] {
        guard count > 1 else { return [0] }
        return (0..<5).map { Int((Double(count - 1) * Double($0) / 4).rounded()) }
    }

    /// 日期标签:月 K 显示 yy-MM,日/周 K 显示 yy-MM-dd
    static func dateLabel(_ date: String, period: KLinePeriod) -> String {
        let short = date.count >= 10 ? String(date.dropFirst(2)) : date
        return period == .month ? String(short.prefix(5)) : short
    }
}
