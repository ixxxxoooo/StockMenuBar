//
//  MinuteChartView.swift
//  StockMenuBar
//
//  当日分时图(AppKit 画布):昨收中轴、分时线、面积阴影、均价线、十字光标与成交量柱。
//  绘制见 Chart/MinuteChartContent.swift;悬停只更新光标层,不重绘图形。
//  @author ixxxxoooo
//

import SwiftUI

struct MinuteChartView: View {
    let series: MinuteSeries?
    let isLoading: Bool
    let failed: Bool
    /// 加载失败时的手动重试(为空则不显示按钮)
    var retry: (() -> Void)?
    private let prefs = AppEnvironment.shared.prefs

    var body: some View {
        if let series, !series.bars.isEmpty {
            ChartCanvas(content: MinuteChartContent(series: series, redUp: prefs.redUp, stealth: prefs.stealthMode))
                .frame(minHeight: 360)
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
}
