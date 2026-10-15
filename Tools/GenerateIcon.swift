//
//  GenerateIcon.swift
//  StockMenuBar
//
//  应用图标生成脚本:用 CoreGraphics 绘制并导出 AppIcon.appiconset 所需的全部尺寸。
//  用法:swift Tools/GenerateIcon.swift StockMenuBar/Resources/Assets.xcassets/AppIcon.appiconset
//  @author ixxxxoooo
//

import AppKit

/// 绘制指定边长的图标并返回 PNG 数据
/// - Parameter pixels: 输出像素边长
/// - Returns: PNG 二进制数据
func renderIcon(pixels: Int) -> Data {
    let s = CGFloat(pixels)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let space = CGColorSpaceCreateDeviceRGB()

    func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: space, components: [
            CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha
        ])!
    }

    // 苹果图标模板:824/1024 的圆角方块居中,四周留白用于阴影
    let body = CGRect(x: s * 100 / 1024, y: s * 100 / 1024, width: s * 824 / 1024, height: s * 824 / 1024)
    let radius = body.width * 0.2237
    let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // 柔和投影
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 10 / 1024), blur: s * 28 / 1024, color: color(0x000000, 0.35))
    ctx.addPath(path)
    ctx.setFillColor(color(0x0F172A))
    ctx.fillPath()
    ctx.restoreGState()

    // 背景渐变(深靛蓝 → 深青)
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let bg = CGGradient(colorsSpace: space, colors: [color(0x1E2A52), color(0x0B1224)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])

    // 顶部高光
    let glow = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.16), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: body.midX, y: body.maxY + body.height * 0.05), startRadius: 0,
                           endCenter: CGPoint(x: body.midX, y: body.maxY + body.height * 0.05), endRadius: body.width * 0.8, options: [])

    // 水平参考线
    ctx.setStrokeColor(color(0xFFFFFF, 0.07))
    ctx.setLineWidth(max(1, s * 3 / 1024))
    for i in 1...3 {
        let y = body.minY + body.height * CGFloat(i) / 4
        ctx.move(to: CGPoint(x: body.minX + body.width * 0.08, y: y))
        ctx.addLine(to: CGPoint(x: body.maxX - body.width * 0.08, y: y))
    }
    ctx.strokePath()

    // K 线:(开, 收, 最高, 最低) 以 0~1 的相对高度表示,红涨绿跌
    let candles: [(open: CGFloat, close: CGFloat, high: CGFloat, low: CGFloat)] = [
        (0.28, 0.20, 0.32, 0.15),
        (0.24, 0.35, 0.39, 0.20),
        (0.37, 0.30, 0.43, 0.25),
        (0.46, 0.63, 0.69, 0.42),
        (0.64, 0.79, 0.85, 0.60)
    ]
    let areaX = body.minX + body.width * 0.14
    let areaW = body.width * 0.72
    let baseY = body.minY + body.height * 0.14
    let areaH = body.height * 0.72
    let slot = areaW / CGFloat(candles.count)
    let candleW = slot * 0.46
    for (i, c) in candles.enumerated() {
        let up = c.close >= c.open
        let fill = up ? color(0xFF4D5A) : color(0x22D17B)
        let cx = areaX + slot * (CGFloat(i) + 0.5)
        let wick = CGRect(x: cx - max(1, s * 5 / 1024), y: baseY + areaH * c.low,
                          width: max(2, s * 10 / 1024), height: areaH * (c.high - c.low))
        ctx.setFillColor(fill)
        ctx.addPath(CGPath(roundedRect: wick, cornerWidth: wick.width / 2, cornerHeight: wick.width / 2, transform: nil))
        ctx.fillPath()
        let lo = min(c.open, c.close), hi = max(c.open, c.close)
        let bodyRect = CGRect(x: cx - candleW / 2, y: baseY + areaH * lo, width: candleW, height: max(areaH * (hi - lo), s * 14 / 1024))
        ctx.addPath(CGPath(roundedRect: bodyRect, cornerWidth: candleW * 0.18, cornerHeight: candleW * 0.18, transform: nil))
        ctx.fillPath()
    }

    // 趋势折线(白色发光)
    let points: [CGPoint] = [(0.0, 0.18), (0.22, 0.30), (0.42, 0.26), (0.66, 0.50), (1.0, 0.80)].map {
        CGPoint(x: areaX + areaW * $0.0, y: baseY + areaH * $0.1)
    }
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: s * 18 / 1024, color: color(0xFFFFFF, 0.6))
    ctx.setStrokeColor(color(0xFFFFFF, 0.92))
    ctx.setLineWidth(max(2, s * 22 / 1024))
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: points[0])
    for p in points.dropFirst() { ctx.addLine(to: p) }
    ctx.strokePath()
    ctx.restoreGState()
    ctx.restoreGState()

    // 细描边
    ctx.addPath(path)
    ctx.setStrokeColor(color(0xFFFFFF, 0.14))
    ctx.setLineWidth(max(1, s * 3 / 1024))
    ctx.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

guard CommandLine.arguments.count > 1 else {
    print("用法: swift GenerateIcon.swift <AppIcon.appiconset 目录>")
    exit(1)
}
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

// (逻辑尺寸, 倍率)
let specs: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
var images: [[String: String]] = []
for (size, scale) in specs {
    let name = "icon_\(size)x\(size)@\(scale)x.png"
    try renderIcon(pixels: size * scale).write(to: dir.appendingPathComponent(name))
    images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(size)x\(size)"])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: dir.appendingPathComponent("Contents.json"))
print("已生成 \(specs.count) 个尺寸 → \(dir.path)")
