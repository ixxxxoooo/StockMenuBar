//
//  GlassStyle.swift
//  StockMenuBar
//
//  Liquid Glass 样式封装:macOS 26+ 使用系统玻璃效果(与窗口工具栏按钮一致),
//  更早的系统或旧版 SDK 构建时退回到 regularMaterial 圆形底。
//  @author ixxxxoooo
//

import SwiftUI

extension View {
    /// 把视图裹在圆形 Liquid Glass 里(可交互:按下时有玻璃反馈)
    @ViewBuilder
    func glassCircle() -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: Circle())
        } else {
            self.background(.regularMaterial, in: Circle())
        }
        #else
        self.background(.regularMaterial, in: Circle())
        #endif
    }
}
