//
//  ChartCanvas.swift
//  StockMenuBar
//
//  AppKit 图表画布:价格区 + 成交量区共用一个 NSView。
//  系列内容只在数据变化时重绘一次(层缓存),鼠标悬停只更新十字光标与提示框两个轻量 CALayer,
//  避免 Swift Charts 每次鼠标移动都重新求值全部图元造成的卡顿。
//  @author ixxxxoooo
//

import AppKit
import SwiftUI

/// 画布几何:价格区与成交量区
struct ChartGeometry {
    let price: CGRect
    let volume: CGRect?
}

/// 图表内容:负责某一种图(分时 / K 线)的绘制与悬停语义
protocol ChartContent {
    /// 是否绘制成交量区
    var hasVolume: Bool { get }
    /// 绘图区左右两侧为坐标轴标签预留的宽度
    var axisInsets: (left: CGFloat, right: CGFloat) { get }
    /// 内容相同则无需重绘
    func isSame(as other: any ChartContent) -> Bool
    /// 绘制价格区、成交量区(当前 NSGraphicsContext 已就绪,坐标原点在左上)
    func draw(in geometry: ChartGeometry)
    /// 横向位置占绘图区宽度的比例 → 悬停序号;该位置无数据返回 nil
    func hoverIndex(forFraction fraction: CGFloat) -> Int?
    /// 悬停序号对应的竖线 x 占比与光标点(价格区内占比 0...1 的 x、y)
    func cursor(forIndex index: Int) -> (x: CGFloat, y: CGFloat?)
    /// 悬停提示文本;返回 nil 则不显示提示框
    func tooltip(forIndex index: Int) -> NSAttributedString?
}

// MARK: - 绘制工具

enum ChartDraw {
    static let gridColor = NSColor.secondaryLabelColor.withAlphaComponent(0.18)

    /// 绘制绘图区底色与圆角
    static func paneBackground(_ rect: CGRect) {
        NSColor.labelColor.withAlphaComponent(0.025).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
    }

    /// 绘制一条 1px 对齐的线
    /// - Parameters:
    ///   - dash: 虚线样式,为空则实线
    static func line(from a: CGPoint, to b: CGPoint, color: NSColor, width: CGFloat = 0.5, dash: [CGFloat] = []) {
        let path = NSBezierPath()
        path.move(to: a)
        path.line(to: b)
        path.lineWidth = width
        if !dash.isEmpty { path.setLineDash(dash, count: dash.count, phase: 0) }
        color.setStroke()
        path.stroke()
    }

    /// 绘制文本
    /// - Parameters:
    ///   - anchor: 锚点;`align` 决定锚点位于文本的左/中/右,垂直方向居中于 y
    static func text(_ string: String, at anchor: CGPoint, align: NSTextAlignment, color: NSColor,
                     size: CGFloat = 10, centerY: Bool = true) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular), .foregroundColor: color]
        let s = NSAttributedString(string: string, attributes: attrs)
        let w = s.size()
        let x = align == .right ? anchor.x - w.width : (align == .center ? anchor.x - w.width / 2 : anchor.x)
        s.draw(at: CGPoint(x: x, y: centerY ? anchor.y - w.height / 2 : anchor.y))
    }

    /// 把动态颜色固化为当前外观下的具体颜色(CATextLayer 不会随外观重新解析动态色)
    static func resolved(_ color: NSColor) -> NSColor {
        NSColor(cgColor: color.cgColor) ?? color
    }

    /// 取 count 个"好看"的纵轴刻度(1/2/5 × 10^n 步长)
    static func niceTicks(lo: Double, hi: Double, count: Int) -> [Double] {
        guard hi > lo, count > 0 else { return [lo] }
        let raw = (hi - lo) / Double(count)
        let mag = pow(10, floor(log10(raw)))
        let step = [1.0, 2, 5, 10].map { $0 * mag }.first { $0 >= raw } ?? raw
        var ticks: [Double] = []
        var v = (lo / step).rounded(.up) * step
        while v <= hi + step * 1e-9 { ticks.append(v); v += step }
        return ticks
    }
}

// MARK: - AppKit 视图

final class ChartCanvasNSView: NSView {
    private var content: (any ChartContent)?
    var onHover: ((Int?) -> Void)?
    private var hoverIndex: Int?
    private let cursorLayer = CAShapeLayer()
    private let dotLayer = CAShapeLayer()
    private let tipLayer = CATextLayer()
    private let volumeHeight: CGFloat = 92
    private let xAxisHeight: CGFloat = 18

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        for l in [cursorLayer, dotLayer, tipLayer] { l.isHidden = true; l.actions = ["hidden": NSNull(), "position": NSNull(), "path": NSNull(), "bounds": NSNull(), "string": NSNull()] }
        cursorLayer.lineWidth = 0.8
        cursorLayer.fillColor = nil
        tipLayer.cornerRadius = 6
        tipLayer.borderWidth = 0.5
        tipLayer.contentsScale = 2
        tipLayer.isWrapped = false
        [cursorLayer, dotLayer, tipLayer].forEach { layer?.addSublayer($0) }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// 更新内容;相同则不重绘
    func update(content new: any ChartContent) {
        if let old = content, old.isSame(as: new) { return }
        content = new
        hoverIndex = nil
        hideCursor()
        needsDisplay = true
    }

    /// 由当前尺寸与内容计算几何
    private func geometry() -> ChartGeometry? {
        guard let content else { return nil }
        let ins = content.axisInsets
        let x = ins.left, w = max(bounds.width - ins.left - ins.right, 1)
        if content.hasVolume {
            let volTop = bounds.height - volumeHeight
            return ChartGeometry(price: CGRect(x: x, y: 2, width: w, height: max(volTop - xAxisHeight - 6, 1)),
                                 volume: CGRect(x: x, y: volTop, width: w, height: volumeHeight - 2))
        }
        return ChartGeometry(price: CGRect(x: x, y: 2, width: w, height: max(bounds.height - xAxisHeight - 4, 1)), volume: nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let g = geometry(), let content else { return }
        content.draw(in: g)
    }

    // MARK: 悬停

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        guard let g = geometry(), let content else { return }
        let p = convert(event.locationInWindow, from: nil)
        let fraction = (p.x - g.price.minX) / g.price.width
        let index = fraction >= -0.02 && fraction <= 1.02 ? content.hoverIndex(forFraction: min(max(fraction, 0), 1)) : nil
        setHover(index, geometry: g)
    }

    override func mouseExited(with event: NSEvent) { setHover(nil, geometry: nil) }

    private func setHover(_ index: Int?, geometry g: ChartGeometry?) {
        guard index != hoverIndex else { return }
        hoverIndex = index
        onHover?(index)
        guard let index, let g, let content else { hideCursor(); return }
        let c = content.cursor(forIndex: index)
        let x = (g.price.minX + g.price.width * c.x).rounded() + 0.5
        let bottom = g.volume?.maxY ?? g.price.maxY
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x, y: g.price.minY))
        path.addLine(to: CGPoint(x: x, y: bottom))
        cursorLayer.path = path
        var tip: NSAttributedString?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            tip = content.tooltip(forIndex: index)
            cursorLayer.strokeColor = NSColor.secondaryLabelColor.withAlphaComponent(0.5).cgColor
            tipLayer.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.94).cgColor
            tipLayer.borderColor = NSColor.secondaryLabelColor.withAlphaComponent(0.25).cgColor
        }
        cursorLayer.isHidden = false
        if let y = c.y {
            dotLayer.path = CGPath(ellipseIn: CGRect(x: x - 3, y: g.price.minY + g.price.height * y - 3, width: 6, height: 6), transform: nil)
            effectiveAppearance.performAsCurrentDrawingAppearance { dotLayer.fillColor = NSColor.labelColor.cgColor }
            dotLayer.isHidden = false
        } else { dotLayer.isHidden = true }
        if let tip { showTip(tip, x: x, top: g.price.minY) } else { tipLayer.isHidden = true }
    }

    /// 提示框跟随竖线,左右越界时贴边
    private func showTip(_ text: NSAttributedString, x: CGFloat, top: CGFloat) {
        let size = text.size()
        let w = ceil(size.width) + 14, h = ceil(size.height) + 8
        let left = min(max(x - w / 2, 0), bounds.width - w)
        tipLayer.string = text
        tipLayer.alignmentMode = .left
        tipLayer.frame = CGRect(x: left, y: top + 4, width: w, height: h)
        tipLayer.contentsScale = window?.backingScaleFactor ?? 2
        tipLayer.isHidden = false
    }

    private func hideCursor() {
        [cursorLayer, dotLayer, tipLayer].forEach { $0.isHidden = true }
    }
}

// MARK: - SwiftUI 桥接

struct ChartCanvas: NSViewRepresentable {
    let content: any ChartContent
    /// 悬停序号变化(离开为 nil);仅在序号变化时回调
    var onHover: ((Int?) -> Void)?

    func makeNSView(context: Context) -> ChartCanvasNSView { ChartCanvasNSView(frame: .zero) }

    func updateNSView(_ view: ChartCanvasNSView, context: Context) {
        view.onHover = onHover
        view.update(content: content)
    }
}
