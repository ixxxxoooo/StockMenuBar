//
//  BackupActions.swift
//  StockMenuBar
//
//  设置页的"导出/导入"交互:系统保存/打开面板、导入确认对话框,以及供脚本调用的无界面入口。
//  文件解析与应用逻辑在 Core/Backup,这里只负责与用户交互。
//  @author ixxxxoooo
//

import AppKit
import UniformTypeIdentifiers

/// 一次操作的结果提示
struct BackupOutcome: Equatable {
    let message: String
    let isError: Bool
}

@MainActor
enum BackupActions {
    private static var env: AppEnvironment { AppEnvironment.shared }

    // MARK: - 导出

    /// 弹出保存面板并导出
    /// - Returns: 结果提示;用户取消返回 nil
    static func exportWithPanel() -> BackupOutcome? {
        let panel = NSSavePanel()
        panel.title = "导出自选与设置"
        panel.message = "导出的文件可在另一台机器的 StockMenuBar 中通过「导入」恢复。"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = BackupFile.suggestedFileName()
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return export(to: url)
    }

    /// 导出到指定文件
    /// - Parameter url: 目标文件
    static func export(to url: URL) -> BackupOutcome {
        let file = BackupFile.snapshot(watchlist: env.watchlist, prefs: env.prefs, appVersion: AppInfo.version)
        do {
            try BackupCodec.encode(file).write(to: url, options: .atomic)
            return BackupOutcome(message: "已导出 \(file.groupCount) 个分组、\(file.itemCount) 个自选到 \(url.lastPathComponent)", isError: false)
        } catch {
            return BackupOutcome(message: "导出失败:\(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - 导入

    /// 弹出打开面板、确认导入方式并导入
    /// - Returns: 结果提示;用户取消返回 nil
    static func importWithPanel() -> BackupOutcome? {
        let panel = NSOpenPanel()
        panel.title = "导入自选与设置"
        panel.message = "选择之前导出的 StockMenuBar 备份文件(.json)。"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        let parsed: ParsedBackup
        do { parsed = try parse(url) } catch {
            return BackupOutcome(message: error.localizedDescription, isError: true)
        }
        guard let choice = confirm(parsed) else { return nil }
        return apply(parsed, mode: choice.mode, includeSettings: choice.includeSettings)
    }

    /// 读取并解析备份文件
    /// - Parameter url: 备份文件
    static func parse(_ url: URL) throws -> ParsedBackup {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= BackupCodec.maxBytes else { throw BackupError.tooLarge }
        do { return try BackupCodec.parse(Data(contentsOf: url)) } catch let e as BackupError { throw e } catch {
            throw BackupError.unreadable(error.localizedDescription)
        }
    }

    /// 应用备份并刷新行情
    static func apply(_ parsed: ParsedBackup, mode: BackupImportMode, includeSettings: Bool) -> BackupOutcome {
        let summary = parsed.file.apply(dropped: parsed.droppedItems, mode: mode, includeSettings: includeSettings,
                                        watchlist: env.watchlist, prefs: env.prefs)
        env.consumersChanged()
        env.scheduler.refreshOnDemand()
        return BackupOutcome(message: summary.message, isError: false)
    }

    /// 导入确认:选择合并/替换以及是否导入偏好
    private static func confirm(_ parsed: ParsedBackup) -> (mode: BackupImportMode, includeSettings: Bool)? {
        let file = parsed.file
        let alert = NSAlert()
        alert.messageText = "导入 \(file.groupCount) 个分组、\(file.itemCount) 个自选?"
        var info = "备份导出于 \(file.exportedAt.formatted(date: .abbreviated, time: .shortened)),应用版本 \(file.appVersion)。"
        if parsed.droppedItems > 0 { info += "\n有 \(parsed.droppedItems) 个无法识别的条目将被忽略。" }
        info += "\n\n合并:保留现有内容,只补充备份中新增的分组与自选。\n替换:先清空现有的分组与自选,再恢复为备份内容(不可撤销)。"
        alert.informativeText = info
        alert.addButton(withTitle: "合并")
        alert.addButton(withTitle: "取消")
        let replace = alert.addButton(withTitle: "替换")
        replace.hasDestructiveAction = true

        let checkbox = NSButton(checkboxWithTitle: "同时导入偏好设置(刷新间隔、菜单栏与悬浮窗等)", target: nil, action: nil)
        checkbox.state = file.settings == nil ? .off : .on
        checkbox.isEnabled = file.settings != nil
        checkbox.sizeToFit()
        alert.accessoryView = checkbox

        switch alert.runModal() {
        case .alertFirstButtonReturn: return (.merge, checkbox.state == .on)
        case .alertThirdButtonReturn: return (.replace, checkbox.state == .on)
        default: return nil
        }
    }

    // MARK: - 无界面入口(脚本/自动化)

    /// 处理 --export-backup=PATH 与 --import-backup=PATH [--import-mode=merge|replace] [--no-settings]
    /// - Returns: 是否处理了备份参数(处理后应用应退出)
    static func handleLaunchArguments(_ args: [String]) -> Bool {
        func value(_ key: String) -> String? {
            args.first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) }
        }
        var handled = false
        if let path = value("--import-backup") {
            handled = true
            do {
                let parsed = try parse(URL(fileURLWithPath: path))
                let mode: BackupImportMode = value("--import-mode") == "replace" ? .replace : .merge
                print(apply(parsed, mode: mode, includeSettings: !args.contains("--no-settings")).message)
            } catch {
                print("导入失败:\(error.localizedDescription)")
            }
        }
        if let path = value("--export-backup") {
            handled = true
            print(export(to: URL(fileURLWithPath: path)).message)
        }
        return handled
    }
}
