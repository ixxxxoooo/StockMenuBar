//
//  FloatingPanelController.swift
//  StockMenuBar
//
//  悬浮迷你窗:置顶、不抢焦点、跨桌面/全屏可见、拖动吸附、位置记忆、穿透锁定。
//  @author ixxxxoooo
//

import AppKit
import SwiftUI

/// 不抢焦点的悬浮面板
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// 拖动起点:鼠标屏幕坐标与窗口原点的差值
    private var dragOffset: NSPoint?
    /// 本次按下后是否已发生真实位移(用于区分点击与拖动)
    private var didDrag = false

    /// 自行实现"按住任意位置拖动窗口"。
    /// SwiftUI 承载视图不会声明 mouseDownCanMoveWindow,系统自带的背景拖动不生效;
    /// 这里在事件分发前计算位移,并继续把事件交给 SwiftUI,保证点击、右键菜单、悬停照常工作。
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            let mouse = NSEvent.mouseLocation
            dragOffset = NSPoint(x: mouse.x - frame.origin.x, y: mouse.y - frame.origin.y)
            didDrag = false
        case .leftMouseDragged:
            if let offset = dragOffset {
                let mouse = NSEvent.mouseLocation
                let target = NSPoint(x: mouse.x - offset.x, y: mouse.y - offset.y)
                // 位移超过 3pt 才视为拖动,避免轻微抖动吞掉点击
                if didDrag || hypot(target.x - frame.origin.x, target.y - frame.origin.y) > 3 {
                    didDrag = true
                    setFrameOrigin(target)
                }
            }
        case .leftMouseUp:
            dragOffset = nil
            if didDrag {
                didDrag = false
                // 拖动结束不再把抬起事件当作点击交给内容视图
                return
            }
        default:
            break
        }
        super.sendEvent(event)
    }
}

@MainActor
final class FloatingPanelController: NSObject {
    private let env = AppEnvironment.shared
    private var panel: FloatingPanel?
    private var moveTask: Task<Void, Never>?
    private var shrinkTask: Task<Void, Never>?
    private var lastShown = false
    private var moveObserver: NSObjectProtocol?
    /// 程序调整尺寸期间(含展开分时图)产生的移动通知不是用户拖动,不触发吸边与位置保存
    private var ignoreMovesUntil = Date.distantPast
    /// 当前窗口为分类面板向左多出的宽度(内容区左边缘 = 窗口左边缘 + leftExtra)
    private var leftExtra: CGFloat = 0

    /// 开始观察偏好与状态,按需显示/隐藏/调整悬浮窗
    func setup() {
        autoUpdate { [weak self] in self?.sync() }
    }

    /// 悬浮窗当前是否可见
    var isVisible: Bool { panel?.isVisible ?? false }

    /// 根据偏好同步窗口状态(在 withObservationTracking 内调用,读取到的偏好变化会再次触发)
    private func sync() {
        let prefs = env.prefs
        let shouldShow = prefs.floatingVisible && !env.ui.bossHidden
        let style = prefs.floatingStyle
        let count = env.floatingSymbols.count
        let clickThrough = prefs.floatingClickThrough
        // 列表样式窗口恒取"展开后"的最大高度,悬停展开只在窗口内部动画,避免窗口缩放与内容布局不同步造成顶部跳动
        let expanded = style == .list && count > 0
        let categoryOpen = env.ui.floatingCategoryOpen && shouldShow
        let categoryRows = categoryOpen ? env.watchlist.groups.count + 2 : nil

        if shouldShow {
            let panel = ensurePanel()
            panel.ignoresMouseEvents = clickThrough
            let card = FloatingLayout.size(style: style, count: count, expanded: expanded)
            let extra = categoryOpen ? FloatingLayout.categoryWidth + FloatingLayout.categoryGap : 0
            resize(panel, to: FloatingLayout.windowSize(card: card, categoryRows: categoryRows), leftExtra: extra)
            if !panel.isVisible { panel.orderFrontRegardless() }
        } else {
            panel?.orderOut(nil)
            // 隐藏后再显示时不保留展开的分类面板
            if env.ui.floatingCategoryOpen { Task { @MainActor [env] in env.ui.setFloatingCategory(false) } }
        }
        if shouldShow != lastShown {
            lastShown = shouldShow
            // 在下一轮主线程循环中通知调度器,避免在观察闭包内修改状态
            Task { @MainActor [env] in env.consumersChanged() }
        }
    }

    /// 创建面板
    private func ensurePanel() -> FloatingPanel {
        if let panel { return panel }
        let size = FloatingLayout.size(style: env.prefs.floatingStyle, count: env.floatingSymbols.count)
        let panel = FloatingPanel(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        // 拖动由 FloatingPanel.sendEvent 自行处理,关闭系统背景拖动避免重复位移
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.titleVisibility = .hidden
        let hosting = NSHostingView(rootView: FloatingRootView().refreshOnStealthChange())
        hosting.sizingOptions = []
        panel.contentView = hosting

        if let origin = env.prefs.loadFloatingOrigin() {
            panel.setFrameTopLeftPoint(NSPoint(x: origin.x, y: origin.y))
        } else if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: frame.maxX - size.width - 20, y: frame.maxY - 20))
        }
        moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.panelDidMove() }
        }
        self.panel = panel
        return panel
    }

    /// 调整尺寸并保持左上角不动。
    /// 窗口缩放动画与 SwiftUI 内容动画并发会不同步(内容已按新高度布局,窗口还没长高,顶部被上顶裁掉),
    /// 所以窗口本身不做动画:变高时立即长到目标高度(多出的下方区域透明),内容在其中做动画;
    /// 变矮时等内容收起动画结束后再缩小。
    private func resize(_ panel: FloatingPanel, to size: CGSize, leftExtra extra: CGFloat) {
        shrinkTask?.cancel()
        let old = panel.frame
        guard abs(old.width - size.width) > 0.5 || abs(old.height - size.height) > 0.5 || extra != leftExtra else { return }
        if size.height < old.height - 0.5 || size.width < old.width - 0.5, panel.isVisible {
            shrinkTask = Task { @MainActor [weak self, weak panel] in
                try? await Task.sleep(for: .milliseconds(260))
                guard !Task.isCancelled, let self, let panel else { return }
                self.applyFrame(panel, size, leftExtra: extra)
            }
        } else {
            applyFrame(panel, size, leftExtra: extra)
        }
    }

    /// 以顶边和内容区左边缘为基准一次性设置窗口尺寸(不带窗口动画);分类面板向左加宽,卡片位置不动
    private func applyFrame(_ panel: FloatingPanel, _ size: CGSize, leftExtra extra: CGFloat) {
        let old = panel.frame
        let frame = NSRect(x: old.minX + leftExtra - extra, y: old.maxY - size.height, width: size.width, height: size.height)
        leftExtra = extra
        ignoreMovesUntil = Date().addingTimeInterval(0.6)
        panel.setFrame(frame, display: true, animate: false)
    }

    /// 拖动结束(停止移动 0.25 秒)后吸附边缘并保存位置
    private func panelDidMove() {
        guard Date() >= ignoreMovesUntil else { return }
        moveTask?.cancel()
        moveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self, let panel = self.panel else { return }
            // 分类面板展开期间窗口左侧含透明扩展区,不吸边;保存位置按内容区左边缘计算
            if self.leftExtra == 0 { self.snapToEdges(panel) }
            let frame = panel.frame
            self.env.prefs.saveFloatingOrigin(x: frame.minX + self.leftExtra, y: frame.maxY)
        }
    }

    /// 靠近屏幕可见区域边缘 18pt 内时吸附到距边缘 8pt 处
    private func snapToEdges(_ panel: FloatingPanel) {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let area = screen.visibleFrame
        var frame = panel.frame
        let threshold: CGFloat = 18
        let margin: CGFloat = 8
        if abs(frame.minX - area.minX) < threshold { frame.origin.x = area.minX + margin }
        if abs(area.maxX - frame.maxX) < threshold { frame.origin.x = area.maxX - frame.width - margin }
        if abs(area.maxY - frame.maxY) < threshold { frame.origin.y = area.maxY - frame.height - margin }
        if abs(frame.minY - area.minY) < threshold { frame.origin.y = area.minY + margin }
        if frame.origin != panel.frame.origin {
            panel.setFrame(frame, display: true, animate: true)
        }
    }
}
