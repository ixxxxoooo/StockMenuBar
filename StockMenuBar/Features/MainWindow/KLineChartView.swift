//
//  KLineChartView.swift
//  StockMenuBar
//
//  AppKit 画布绘制的日/周/月 K 线:蜡烛图 + MA5/10/20 均线 + 十字光标,
//  下方对齐的成交量柱状图;顶部显示光标(或最新一根)的开高低收与涨跌。
//  @author ixxxxoooo
//

import SwiftUI

struct KLineChartView: View {
    let series: KLineSeries?
    let isLoading: Bool
    let failed: Bool
    var retry: (() -> Void)?
    @State private var hoverIndex: Int?
    private let prefs = AppEnvironment.shared.prefs
    private static let maColors: [Color] = [.orange, .blue, .purple]

    /// 截取展示窗口;均线基于完整序列计算后再截取,保证窗口首根就有值
    private func window(_ series: KLineSeries) -> KLineWindow {
        let offset = max(series.bars.count - KLineConfig.visibleCount, 0)
        let mas = KLineChartContent.maLines.map { Array(series.movingAverage($0.n).dropFirst(offset)) }
        return KLineWindow(bars: Array(series.bars.dropFirst(offset)), offset: offset, mas: mas)
    }

    var body: some View {
        if let series, !series.bars.isEmpty {
            let w = window(series)
            VStack(spacing: 6) {
                infoBar(series, w)
                ChartCanvas(content: KLineChartContent(window: w, period: series.period, decimals: series.decimals,
                                                       redUp: prefs.redUp, stealth: prefs.stealthMode),
                            onHover: { hoverIndex = $0 })
                    .frame(minHeight: 360)
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
    private func infoBar(_ series: KLineSeries, _ w: KLineWindow) -> some View {
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
            ForEach(Array(KLineChartContent.maLines.enumerated()), id: \.offset) { k, line in
                if let v = w.mas[k][i] {
                    Text("MA\(line.n) \(Fmt.price(v, decimals: d))").foregroundStyle(Self.maColors[k])
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
}
