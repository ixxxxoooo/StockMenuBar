//
//  Theme.swift
//  StockMenuBar
//
//  主题色:遵循 A 股「红涨绿跌」习惯,可一键反转;自动适配浅色/深色模式。
//  @author ixxxxoooo
//

import AppKit
import SwiftUI

enum Theme {
    /// 摸鱼模式:涨跌色降饱和、降对比,由 Preferences 同步(界面根视图随开关重建以刷新颜色)
    nonisolated(unsafe) static var stealth = false

    private static let mutedRed = dynamic(
        light: NSColor(srgbRed: 0.62, green: 0.48, blue: 0.48, alpha: 1),
        dark: NSColor(srgbRed: 0.62, green: 0.52, blue: 0.52, alpha: 1))
    private static let mutedGreen = dynamic(
        light: NSColor(srgbRed: 0.46, green: 0.56, blue: 0.50, alpha: 1),
        dark: NSColor(srgbRed: 0.50, green: 0.60, blue: 0.54, alpha: 1))

    /// 上涨/下跌语义色(随浅深色模式自适应)
    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    private static let red = dynamic(
        light: NSColor(srgbRed: 0.88, green: 0.18, blue: 0.20, alpha: 1),
        dark: NSColor(srgbRed: 1.00, green: 0.37, blue: 0.34, alpha: 1))
    private static let green = dynamic(
        light: NSColor(srgbRed: 0.08, green: 0.63, blue: 0.33, alpha: 1),
        dark: NSColor(srgbRed: 0.20, green: 0.82, blue: 0.47, alpha: 1))

    /// 涨跌对应的 AppKit 颜色(菜单栏富文本使用)
    /// - Parameters:
    ///   - trend: 涨跌方向
    ///   - redUp: 红涨绿跌
    static func nsColor(_ trend: Trend, redUp: Bool) -> NSColor {
        let red = stealth ? mutedRed : red, green = stealth ? mutedGreen : green
        switch trend {
        case .up: return redUp ? red : green
        case .down: return redUp ? green : red
        case .flat: return .secondaryLabelColor
        }
    }

    /// 涨跌对应的 SwiftUI 颜色
    static func color(_ trend: Trend, redUp: Bool) -> Color {
        Color(nsColor: nsColor(trend, redUp: redUp))
    }

    /// 涨跌幅色块底色(平盘用灰色)
    static func badgeFill(_ trend: Trend, redUp: Bool) -> Color {
        switch trend {
        case .flat: return Color(nsColor: .systemGray)
        default: return color(trend, redUp: redUp).opacity(stealth ? 0.8 : 1)
        }
    }

    /// 由涨跌额得到方向
    static func trend(of change: Double, epsilon: Double = 0.0005) -> Trend {
        if change > epsilon { return .up }
        if change < -epsilon { return .down }
        return .flat
    }
}
