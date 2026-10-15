//
//  CommonViews.swift
//  StockMenuBar
//
//  通用界面组件:涨跌幅色块、价格文本、迷你走势线(Canvas)、跳动闪色、数据源状态点。
//  @author ixxxxoooo
//

import SwiftUI

/// 涨跌幅色块
struct ChangeBadge: View {
    let quote: Quote?
    var width: CGFloat = 64
    var height: CGFloat = 20
    var fontSize: CGFloat = 12
    private let prefs = AppEnvironment.shared.prefs

    var body: some View {
        let trend = quote?.trend ?? .flat
        Text(quote.map { Fmt.percent($0.changePercent) } ?? "--")
            .font(.system(size: fontSize, weight: .semibold, design: .rounded).monospacedDigit())
            .foregroundStyle(.white)
            .frame(width: width, height: height)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.badgeFill(trend, redUp: prefs.redUp)))
            .contentTransition(.numericText())
    }
}

/// 价格文本:等宽数字、涨跌着色、数字滚动过渡
struct PriceText: View {
    let quote: Quote?
    var size: CGFloat = 14
    var weight: Font.Weight = .semibold
    private let prefs = AppEnvironment.shared.prefs

    var body: some View {
        let trend = quote?.trend ?? .flat
        Text(quote.map { Fmt.price($0.price, decimals: $0.decimals) } ?? "--")
            .font(.system(size: size, weight: weight, design: .rounded).monospacedDigit())
            .foregroundStyle(trend == .flat ? Color.primary : Theme.color(trend, redUp: prefs.redUp))
            .contentTransition(.numericText(value: quote?.price ?? 0))
            .animation(.snappy(duration: 0.25), value: quote?.price)
    }
}

/// 分时价格范围:以昨收为中轴对称,保证中轴线居中
enum MinuteScale {
    /// - Returns: 纵轴 (下界, 上界)
    static func range(prevClose: Double, prices: [Double]) -> (lo: Double, hi: Double) {
        let maxDev = max(prices.map { abs($0 - prevClose) }.max() ?? 0, prevClose * 0.003)
        return (prevClose - maxDev * 1.08, prevClose + maxDev * 1.08)
    }
}

/// 迷你走势线:用 Canvas 手绘,比 Swift Charts 更省资源,用于列表缩略图与悬浮窗
struct Sparkline: View {
    let series: MinuteSeries?
    var lineWidth: CGFloat = 1.2
    var showBaseline = true
    var showFill = true
    private let prefs = AppEnvironment.shared.prefs

    var body: some View {
        let trend = Self.trend(of: series)
        let color = Theme.color(trend, redUp: prefs.redUp)
        let baselineColor = Color.secondary.opacity(0.45)
        let data = series
        Canvas { context, size in
            guard let data, data.bars.count > 1 else {
                var line = Path()
                line.move(to: CGPoint(x: 0, y: size.height / 2))
                line.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                context.stroke(line, with: .color(baselineColor), style: StrokeStyle(lineWidth: 0.6, dash: [2, 3]))
                return
            }
            let range = MinuteScale.range(prevClose: data.prevClose, prices: data.bars.map(\.price))
            let span = max(range.hi - range.lo, 0.000001)
            func point(_ b: MinuteBar) -> CGPoint {
                CGPoint(x: size.width * CGFloat(b.index) / 240,
                        y: size.height * (1 - CGFloat((b.price - range.lo) / span)))
            }
            let pts = data.bars.map(point)
            if showBaseline {
                let y = size.height * (1 - CGFloat((data.prevClose - range.lo) / span))
                var base = Path()
                base.move(to: CGPoint(x: 0, y: y))
                base.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(base, with: .color(baselineColor), style: StrokeStyle(lineWidth: 0.6, dash: [2, 3]))
            }
            var path = Path()
            path.addLines(pts)
            if showFill, let first = pts.first, let last = pts.last {
                var area = path
                area.addLine(to: CGPoint(x: last.x, y: size.height))
                area.addLine(to: CGPoint(x: first.x, y: size.height))
                area.closeSubpath()
                context.fill(area, with: .linearGradient(
                    Gradient(colors: [color.opacity(0.28), color.opacity(0.0)]),
                    startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            }
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            if let last = pts.last {
                context.fill(Path(ellipseIn: CGRect(x: last.x - 2, y: last.y - 2, width: 4, height: 4)), with: .color(color))
            }
        }
    }

    /// 末价相对昨收的方向
    static func trend(of series: MinuteSeries?) -> Trend {
        guard let series, let last = series.lastPrice else { return .flat }
        return Theme.trend(of: last - series.prevClose)
    }
}

/// 价格变动时短暂闪色背景
struct TickFlash: ViewModifier {
    let ticker: QuoteTicker
    var cornerRadius: CGFloat = 6
    @State private var on = false
    private let prefs = AppEnvironment.shared.prefs

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Theme.color(ticker.flashTrend, redUp: prefs.redUp).opacity(on ? 0.22 : 0))
            )
            .onChange(of: ticker.flashToken) { _, _ in
                on = true
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(60))
                    withAnimation(.easeOut(duration: 0.9)) { on = false }
                }
            }
    }
}

extension View {
    /// 价格变动闪色
    func tickFlash(_ ticker: QuoteTicker, cornerRadius: CGFloat = 6) -> some View {
        modifier(TickFlash(ticker: ticker, cornerRadius: cornerRadius))
    }
}

/// 板块小标签(创业板/科创板/ETF 等)
struct KindTag: View {
    let kind: SecurityKind

    var body: some View {
        if kind != .main {
            Text(kind.title)
                .font(.system(size: 9, weight: .medium))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.secondary.opacity(0.18)))
                .foregroundStyle(.secondary)
        }
    }
}

/// 数据状态点:绿=新鲜,橙=延迟(使用旧数据),红=无数据
struct HealthDot: View {
    let health: DataHealth
    var suspended = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .help(helpText)
    }

    private var color: Color {
        if suspended { return .gray }
        switch health {
        case .ok: return .green
        case .stale: return .orange
        case .offline: return .red
        }
    }

    private var helpText: String {
        if suspended { return "系统休眠/锁屏,已暂停刷新" }
        switch health {
        case .ok: return "数据正常"
        case .stale: return "数据延迟:当前展示上一次有效数据"
        case .offline: return "暂无可用数据"
        }
    }
}
