//
//  MinuteChartContent.swift
//  StockMenuBar
//
//  分时图的 AppKit 绘制:昨收中轴、分时线、面积渐变、均价线、成交量柱,以及悬停提示文本。
//  @author ixxxxoooo
//

import AppKit

struct MinuteChartContent: ChartContent, Equatable {
    let series: MinuteSeries
    let redUp: Bool
    let stealth: Bool

    var hasVolume: Bool { series.bars.contains { $0.volume > 0 } }
    var axisInsets: (left: CGFloat, right: CGFloat) { (62, 54) }

    func isSame(as other: any ChartContent) -> Bool { (other as? MinuteChartContent) == self }

    private var range: (lo: Double, hi: Double) {
        MinuteScale.range(prevClose: series.prevClose, prices: series.bars.map(\.price))
    }

    private func color(_ trend: Trend) -> NSColor { Theme.nsColor(trend, redUp: redUp) }

    // MARK: 绘制

    func draw(in g: ChartGeometry) {
        drawPrice(g.price)
        if let v = g.volume { drawVolume(v) }
    }

    private func xPos(_ index: Int, _ rect: CGRect) -> CGFloat {
        rect.minX + rect.width * CGFloat(index) / CGFloat(series.axis.total)
    }

    private func drawPrice(_ rect: CGRect) {
        let prev = series.prevClose
        let (lo, hi) = range
        let span = max(hi - lo, 1e-9)
        let dev = (hi - prev) / 1.08
        let decimals = series.decimals
        func y(_ v: Double) -> CGFloat { rect.minY + rect.height * (1 - CGFloat((v - lo) / span)) }

        ChartDraw.paneBackground(rect)
        for i in series.axis.tickIndices {
            let x = xPos(i, rect).rounded() + 0.5
            ChartDraw.line(from: CGPoint(x: x, y: rect.minY), to: CGPoint(x: x, y: rect.maxY), color: ChartDraw.gridColor)
            let label = series.axis.tickLabel(index: i)
            let last = i == series.axis.total
            ChartDraw.text(label, at: CGPoint(x: x, y: rect.maxY + 3), align: last ? .right : .center,
                           color: .secondaryLabelColor, centerY: false)
        }
        for k in -2...2 {
            let v = prev + dev * Double(k) / 2
            let yy = y(v).rounded() + 0.5
            ChartDraw.line(from: CGPoint(x: rect.minX, y: yy), to: CGPoint(x: rect.maxX, y: yy), color: ChartDraw.gridColor)
            let trend = Theme.trend(of: v - prev, epsilon: 1e-9)
            ChartDraw.text(Fmt.price(v, decimals: decimals), at: CGPoint(x: rect.minX - 6, y: yy), align: .right, color: color(trend))
            if prev > 0 {
                let pct = (v - prev) / prev * 100
                let t = Theme.trend(of: pct, epsilon: 1e-9)
                ChartDraw.text(Fmt.percent(pct), at: CGPoint(x: rect.maxX + 6, y: yy), align: .left, color: color(t))
            }
        }

        guard series.bars.count > 0 else { return }
        let line = color(Sparkline.trend(of: series))
        let pts = series.bars.map { CGPoint(x: xPos($0.index, rect), y: y($0.price)) }
        // 面积渐变
        let area = NSBezierPath()
        area.move(to: CGPoint(x: pts[0].x, y: rect.maxY))
        pts.forEach { area.line(to: $0) }
        area.line(to: CGPoint(x: pts[pts.count - 1].x, y: rect.maxY))
        area.close()
        NSGraphicsContext.saveGraphicsState()
        area.addClip()
        if let ctx = NSGraphicsContext.current?.cgContext,
           let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: [line.withAlphaComponent(0.30).cgColor, line.withAlphaComponent(0.02).cgColor] as CFArray,
                                     locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.maxY), options: [])
        }
        NSGraphicsContext.restoreGraphicsState()
        // 昨收虚线
        ChartDraw.line(from: CGPoint(x: rect.minX, y: y(prev)), to: CGPoint(x: rect.maxX, y: y(prev)),
                       color: NSColor.secondaryLabelColor.withAlphaComponent(0.7), width: 1, dash: [4, 3])
        // 均价线
        let avg = NSBezierPath()
        var started = false
        for b in series.bars {
            guard let a = b.avgPrice else { continue }
            let p = CGPoint(x: xPos(b.index, rect), y: y(a))
            if started { avg.line(to: p) } else { avg.move(to: p); started = true }
        }
        avg.lineWidth = 1
        NSColor.systemOrange.setStroke()
        avg.stroke()
        // 价格线
        let path = NSBezierPath()
        path.move(to: pts[0])
        pts.dropFirst().forEach { path.line(to: $0) }
        path.lineWidth = 1.6
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        line.setStroke()
        path.stroke()
    }

    private func drawVolume(_ rect: CGRect) {
        let bars = series.bars
        ChartDraw.paneBackground(rect)
        for i in series.axis.tickIndices {
            let x = xPos(i, rect).rounded() + 0.5
            ChartDraw.line(from: CGPoint(x: x, y: rect.minY), to: CGPoint(x: x, y: rect.maxY), color: ChartDraw.gridColor)
        }
        let maxVolume = max(bars.map(\.volume).max() ?? 1, 1)
        let scale = rect.height / CGFloat(maxVolume * 1.1)
        ChartDraw.text(Fmt.volume(maxVolume), at: CGPoint(x: rect.minX - 6, y: rect.minY + rect.height * 0.09),
                       align: .right, color: .secondaryLabelColor, size: 9)
        let up = color(.up), down = color(.down)
        let width = max(1.5, rect.width / CGFloat(series.axis.total) * 0.8)
        // 价格不低于上一分钟记为上涨量:分涨跌两批一次填充,减少状态切换
        let upPath = NSBezierPath(), downPath = NSBezierPath()
        for (i, bar) in bars.enumerated() {
            let isUp = i == 0 ? bar.price >= series.prevClose : bar.price >= bars[i - 1].price
            let h = CGFloat(bar.volume) * scale
            let r = CGRect(x: xPos(bar.index, rect) - width / 2, y: rect.maxY - h, width: width, height: h)
            (isUp ? upPath : downPath).appendRect(r)
        }
        up.setFill(); upPath.fill()
        down.setFill(); downPath.fill()
    }

    // MARK: 悬停

    /// 悬停序号 = 光标所在分钟;取不晚于该分钟的最后一根
    func hoverIndex(forFraction f: CGFloat) -> Int? {
        let h = Int((f * CGFloat(series.axis.total)).rounded())
        return series.bars.last { $0.index <= h }?.index
    }

    func cursor(forIndex index: Int) -> (x: CGFloat, y: CGFloat?) {
        let x = CGFloat(index) / CGFloat(series.axis.total)
        guard let bar = series.bars.last(where: { $0.index <= index }) else { return (x, nil) }
        let (lo, hi) = range
        return (x, 1 - CGFloat((bar.price - lo) / max(hi - lo, 1e-9)))
    }

    func tooltip(forIndex index: Int) -> NSAttributedString? {
        guard let bar = series.bars.last(where: { $0.index <= index }) else { return nil }
        let prev = series.prevClose
        let pct = prev > 0 ? (bar.price - prev) / prev * 100 : 0
        let c = ChartDraw.resolved(color(Theme.trend(of: bar.price - prev, epsilon: 1e-9)))
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        let secondary = ChartDraw.resolved(.secondaryLabelColor)
        let out = NSMutableAttributedString()
        func add(_ s: String, _ color: NSColor) {
            out.append(NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color]))
        }
        add(series.axis.label(index: bar.index) + "\n", secondary)
        add("\(Fmt.price(bar.price, decimals: series.decimals))  \(Fmt.percent(pct))\n", c)
        if let avg = bar.avgPrice { add("均 \(Fmt.price(avg, decimals: series.decimals))\n", ChartDraw.resolved(.systemOrange)) }
        add("量 \(Fmt.volume(bar.volume))", secondary)
        return out
    }
}
