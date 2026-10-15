//
//  ObservationHelper.swift
//  StockMenuBar
//
//  让 AppKit 代码订阅 @Observable 属性:body 中读取到的属性变化后自动重新执行。
//  @author ixxxxoooo
//

import Foundation
import Observation

/// 持续观察:执行 body 并追踪其中读取的 @Observable 属性,任一变化后在主线程重新执行
/// - Parameter body: 读取状态并刷新 AppKit 界面的闭包
@MainActor
func autoUpdate(_ body: @escaping @MainActor () -> Void) {
    withObservationTracking {
        body()
    } onChange: {
        Task { @MainActor in autoUpdate(body) }
    }
}
