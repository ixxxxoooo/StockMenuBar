//
//  KLineChartContent.swift
//  StockMenuBar
//
//  K 线图的 AppKit 绘制:蜡烛 + MA5/10/20 均线 + 成交量柱。悬停信息由上方 SwiftUI 信息栏展示。
//  @author ixxxxoooo
//

import AppKit

/// 展示窗口:最近 N 根及其均线
struct KLineWindow: Equatable {
    let bars: [KLineBar]
    let offset: Int
    let mas: [[Double?]]
}

struct KLineChartContent: ChartContent, Equatable {
    let window: KLineWindow
    let period: KLinePeriod
    let decimals: Int
    let redUp: Bool
    let stealth: Bool

    /// 均线周期与配色
    static let maLines: [(n: Int, color: NSColor)] = [(5, .systemOrange), (10, .systemBlue), (20, .systemPurple)]

    var hasVolume: Bool { window.bars.contains { $0.volume > 0 } }
    var axisInsets: (left: CGFloat, right: CGFloat) { (62, 30) }

    func isSame(as other: any ChartContent) -> Bool { (other as? KLineChartContent) == self }

    private var bars: [KLineBar] { window.bars }

    /// 横轴域 -1...count,第 i 根位于 (i+1)/(count+1)
    private func fraction(_ i: Int) -> CGFloat { CGFloat(i + 1) / CGFloat(bars.count + 1) }

    private var priceDomain: (lo: Double, hi: Double) {
        let ma = window.mas.flatMap { $0.compactMap { $0 } }
        let lo = (bars.map(\.low) + ma).min() ?? 0
        let hi = (bars.map(\.high) + ma).max() ?? 1
        let pad = max((hi - lo) * 0.06, 1e-6)
        return (lo - pad, hi + pad)
    }

    // MARK: 绘制

    func draw(in g: ChartGeometry) {
        drawPrice(g.price)
        if let v = g.volume { drawVolume(v) }
    }

    private func drawGrid(_ rect: CGRect) {
        ChartDraw.paneBackground(rect)
        for i in Self.tickIndices(count: bars.count) {
            let x = (rect.minX + rect.width * fraction(i)).rounded() + 0.5
            ChartDraw.line(from: CGPoint(x: x, y: rect.minY), to: CGPoint(x: x, y: rect.maxY), color: ChartDraw.gridColor)
        }
    }

    private func drawPrice(_ rect: CGRect) {
        guard !bars.isEmpty else { return }
        let (lo, hi) = priceDomain
        let span = max(hi - lo, 1e-9)
        func y(_ v: Double) -> CGFloat { rect.minY + rect.height * (1 - CGFloat((v - lo) / span)) }
        func x(_ i: Int) -> CGFloat { rect.minX + rect.width * fraction(i) }

        drawGrid(rect)
        for i in Self.tickIndices(count: bars.count) {
            ChartDraw.text(Self.dateLabel(bars[i].date, period: period), at: CGPoint(x: x(i), y: rect.maxY + 3),
                           align: .center, color: .secondaryLabelColor, centerY: false)
        }
        for v in ChartDraw.niceTicks(lo: lo, hi: hi, count: 4) {
            let yy = y(v).rounded() + 0.5
            ChartDraw.line(from: CGPoint(x: rect.minX, y: yy), to: CGPoint(x: rect.maxX, y: yy), color: ChartDraw.gridColor)
            ChartDraw.text(Fmt.price(v, decimals: decimals), at: CGPoint(x: rect.minX - 6, y: yy), align: .right, color: .secondaryLabelColor)
        }
        let up = Theme.nsColor(.up, redUp: redUp), down = Theme.nsColor(.down, redUp: redUp)
        let bodyW = max(1.5, rect.width / CGFloat(bars.count + 1) * 0.65)
        let pad = (hi - lo) * 0.06
        // 涨、跌各合并为一条路径,一次描边/填充
        let wicks = [true: NSBezierPath(), false: NSBezierPath()]
        let bodies = [true: NSBezierPath(), false: NSBezierPath()]
        for (i, bar) in bars.enumerated() {
            let cx = x(i)
            wicks[bar.isUp]?.move(to: CGPoint(x: cx, y: y(bar.high)))
            wicks[bar.isUp]?.line(to: CGPoint(x: cx, y: y(bar.low)))
            // 开收相等(一字/十字)时给实体一个极小厚度,避免不可见
            let close = bar.open == bar.close ? bar.close + pad * 0.02 : bar.close
            let top = y(max(bar.open, close)), bottom = y(min(bar.open, close))
            bodies[bar.isUp]?.appendRect(CGRect(x: cx - bodyW / 2, y: top, width: bodyW, height: max(bottom - top, 1)))
        }
        for isUp in [true, false] {
            let color = isUp ? up : down
            color.setStroke(); wicks[isUp]?.lineWidth = 1; wicks[isUp]?.stroke()
            color.setFill(); bodies[isUp]?.fill()
        }
        for (k, line) in Self.maLines.enumerated() {
            let path = NSBezierPath()
            var open = false
            for (i, v) in window.mas[k].enumerated() {
                guard let v else { open = false; continue }
                let p = CGPoint(x: x(i), y: y(v))
                if open { path.line(to: p) } else { path.move(to: p); open = true }
            }
            path.lineWidth = 1
            line.color.setStroke()
            path.stroke()
        }
    }

    private func drawVolume(_ rect: CGRect) {
        guard !bars.isEmpty else { return }
        drawGrid(rect)
        let maxVolume = max(bars.map(\.volume).max() ?? 1, 1)
        let scale = rect.height / CGFloat(maxVolume * 1.1)
        ChartDraw.text(Fmt.volume(maxVolume), at: CGPoint(x: rect.minX - 6, y: rect.minY + rect.height * 0.09),
                       align: .right, color: .secondaryLabelColor, size: 9)
        let bodyW = max(1.5, rect.width / CGFloat(bars.count + 1) * 0.65)
        let paths = [true: NSBezierPath(), false: NSBezierPath()]
        for (i, bar) in bars.enumerated() {
            let h = CGFloat(bar.volume) * scale
            paths[bar.isUp]?.appendRect(CGRect(x: rect.minX + rect.width * fraction(i) - bodyW / 2, y: rect.maxY - h, width: bodyW, height: h))
        }
        Theme.nsColor(.up, redUp: redUp).setFill(); paths[true]?.fill()
        Theme.nsColor(.down, redUp: redUp).setFill(); paths[false]?.fill()
    }

    // MARK: 悬停

    func hoverIndex(forFraction f: CGFloat) -> Int? {
        guard !bars.isEmpty else { return nil }
        return min(max(Int((f * CGFloat(bars.count + 1) - 1).rounded()), 0), bars.count - 1)
    }

    func cursor(forIndex index: Int) -> (x: CGFloat, y: CGFloat?) { (fraction(index), nil) }

    func tooltip(forIndex index: Int) -> NSAttributedString? { nil }

    // MARK: 辅助

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
