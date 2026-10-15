//
//  HotKeyCenter.swift
//  StockMenuBar
//
//  全局快捷键:基于 Carbon RegisterEventHotKey,无需辅助功能权限。
//  @author ixxxxoooo
//

import AppKit
import Carbon.HIToolbox

@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var handlers: [UInt32: @MainActor () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var handlerInstalled = false

    private init() {}

    /// 注册全局快捷键
    /// - Parameters:
    ///   - keyCode: 虚拟键码(如 kVK_ANSI_F)
    ///   - modifiers: Carbon 修饰键(cmdKey / optionKey 等)
    ///   - id: 快捷键唯一编号
    ///   - handler: 触发回调(主线程)
    func register(keyCode: Int, modifiers: Int, id: UInt32, handler: @escaping @MainActor () -> Void) {
        installHandlerIfNeeded()
        handlers[id] = handler
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x534D4248), id: id)
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref { refs.append(ref) }
    }

    /// 取消全部快捷键
    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        handlers.removeAll()
    }

    fileprivate func fire(id: UInt32) {
        handlers[id]?()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyEventHandler, 1, &spec, nil, nil)
    }
}

/// Carbon 回调(C 函数指针,不能捕获上下文),转回主线程分发
private func hotKeyEventHandler(_ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == noErr else { return status }
    let id = hotKeyID.id
    DispatchQueue.main.async {
        MainActor.assumeIsolated { HotKeyCenter.shared.fire(id: id) }
    }
    return noErr
}
