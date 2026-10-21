//
//  StealthRefresh.swift
//  StockMenuBar
//
//  摸鱼模式切换时刷新视图树(依赖 AppEnvironment,仅属于应用目标,不编入测试包)。
//  @author ixxxxoooo
//

import SwiftUI

extension View {
    /// 摸鱼模式开关变化时重建视图树,让所有走势/涨跌颜色立即刷新(开关极少切换,重建代价可忽略)
    /// - Returns: 以摸鱼模式状态为 id 的视图
    func refreshOnStealthChange() -> some View {
        id(AppEnvironment.shared.prefs.stealthMode)
    }
}
