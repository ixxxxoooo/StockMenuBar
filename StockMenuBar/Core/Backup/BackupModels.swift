//
//  BackupModels.swift
//  StockMenuBar
//
//  备份文件格式与编解码:把自选分组、条目顺序与偏好设置导出为 JSON,换机器后可导回。
//  解析阶段统一做合法性校验与清洗(未知代码丢弃、重复去重、数量与体积上限),
//  界面与存储层只面对已清洗的数据。
//  @author ixxxxoooo
//

import Foundation

/// 导入方式
enum BackupImportMode: Sendable {
    /// 合并:保留现有内容,补充备份里有而现有没有的分组与自选
    case merge
    /// 替换:清空现有自选后恢复为备份内容
    case replace
}

/// 备份中的一个自选条目
struct BackupItem: Codable, Equatable, Sendable {
    /// 完整代码,如 sh600519、fu113.cum
    var symbol: String
    var name: String
}

/// 备份中的一个分组(条目顺序即展示顺序)
struct BackupGroup: Codable, Equatable, Sendable {
    var name: String
    var items: [BackupItem]
}

/// 备份中的偏好设置;字段均为可选,缺失的字段导入时保持原值,便于以后增删设置项
struct BackupSettings: Codable, Equatable, Sendable {
    var refreshInterval: Int?
    var redUp: Bool?
    var menuBarLabel: String?
    var menuBarCompact: Bool?
    var menuBarRotate: Bool?
    var pinnedSymbols: [String]?
    var popoverMinimal: Bool?
    var floatingStyle: String?
    var floatingSymbols: [String]?
    var floatingOpacity: Double?
    var floatingFade: Bool?
    var floatingClickThrough: Bool?
    var autoCheckUpdates: Bool?
}

/// 备份文件
struct BackupFile: Codable, Equatable, Sendable {
    /// 文件类型标识,用来拒绝导入无关的 JSON
    static let formatID = "StockMenuBar.backup"
    /// 当前格式版本;高于它的文件来自更新的应用,拒绝导入
    static let currentSchemaVersion = 1

    var format: String = BackupFile.formatID
    var schemaVersion: Int = BackupFile.currentSchemaVersion
    /// 导出时的应用版本,仅供展示
    var appVersion: String
    var exportedAt: Date
    var watchlist: [BackupGroup]
    var settings: BackupSettings?

    /// 分组数
    var groupCount: Int { watchlist.count }
    /// 条目总数(含跨分组重复)
    var itemCount: Int { watchlist.reduce(0) { $0 + $1.items.count } }
}

/// 备份错误
enum BackupError: LocalizedError, Equatable {
    case tooLarge
    case notBackupFile
    case newerVersion(Int)
    case empty
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .tooLarge: return "文件过大,不像是 StockMenuBar 的备份"
        case .notBackupFile: return "这不是 StockMenuBar 的备份文件"
        case .newerVersion(let v): return "备份来自更新版本的应用(格式 v\(v)),请先更新应用后再导入"
        case .empty: return "备份里没有可导入的自选"
        case .unreadable(let m): return "无法读取备份:\(m)"
        }
    }
}

/// 解析结果
struct ParsedBackup: Equatable, Sendable {
    let file: BackupFile
    /// 因代码无法识别而被丢弃的条目数
    let droppedItems: Int
}

/// 备份编解码与清洗(纯函数)
enum BackupCodec {
    /// 体积上限:正常备份只有几十 KB
    static let maxBytes = 5 * 1024 * 1024
    static let maxGroups = 200
    static let maxItemsPerGroup = 2000
    static let maxNameLength = 60

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// 编码为 JSON 数据
    static func encode(_ file: BackupFile) throws -> Data {
        try makeEncoder().encode(file)
    }

    /// 解码并清洗
    /// - Parameter data: 文件内容
    /// - Returns: 清洗后的备份与被丢弃的条目数
    static func parse(_ data: Data) throws -> ParsedBackup {
        guard data.count <= maxBytes else { throw BackupError.tooLarge }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // 先只读取头部,区分"不是备份"与"备份损坏"
        struct Header: Decodable { let format: String?; let schemaVersion: Int? }
        guard let header = try? decoder.decode(Header.self, from: data), header.format == BackupFile.formatID else {
            throw BackupError.notBackupFile
        }
        if let version = header.schemaVersion, version > BackupFile.currentSchemaVersion {
            throw BackupError.newerVersion(version)
        }
        var file: BackupFile
        do { file = try decoder.decode(BackupFile.self, from: data) } catch {
            throw BackupError.unreadable("格式不正确")
        }

        var dropped = 0
        var groups: [BackupGroup] = []
        var seenNames = Set<String>()
        for group in file.watchlist.prefix(maxGroups) {
            let name = String(group.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxNameLength))
            // 空名与重名分组直接并入第一个同名分组之外的丢弃,避免导入后出现无法区分的分组
            guard !name.isEmpty, seenNames.insert(name).inserted else { continue }
            var seen = Set<String>()
            var items: [BackupItem] = []
            for item in group.items.prefix(maxItemsPerGroup) {
                guard let symbol = StockSymbol(full: item.symbol) else { dropped += 1; continue }
                guard seen.insert(symbol.full).inserted else { continue }
                let trimmed = String(item.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxNameLength))
                items.append(BackupItem(symbol: symbol.full, name: trimmed.isEmpty ? symbol.displayCode : trimmed))
            }
            groups.append(BackupGroup(name: name, items: items))
        }
        guard !groups.isEmpty else { throw BackupError.empty }
        file.watchlist = groups
        file.settings = file.settings.map(sanitize)
        return ParsedBackup(file: file, droppedItems: dropped)
    }

    /// 清洗偏好设置:越界值丢弃(导入时保持原值)
    private static func sanitize(_ s: BackupSettings) -> BackupSettings {
        var s = s
        if let v = s.refreshInterval, !Preferences.allowedIntervals.contains(v) { s.refreshInterval = nil }
        if let v = s.menuBarLabel, MenuBarLabelMode(rawValue: v) == nil { s.menuBarLabel = nil }
        if let v = s.floatingStyle, FloatingStyle(rawValue: v) == nil { s.floatingStyle = nil }
        if let v = s.floatingOpacity { s.floatingOpacity = v.isFinite ? min(max(v, 0.3), 1.0) : nil }
        s.pinnedSymbols = s.pinnedSymbols.map { valid($0).prefix(Preferences.maxPinned).map { $0 } }
        s.floatingSymbols = s.floatingSymbols.map { valid($0) }
        return s
    }

    private static func valid(_ symbols: [String]) -> [String] {
        var seen = Set<String>()
        return symbols.compactMap { StockSymbol(full: $0)?.full }.filter { seen.insert($0).inserted }
    }
}

// MARK: - 偏好设置的导出与导入

extension Preferences {
    /// 导出需要迁移的偏好(不含窗口位置、更新检查状态、开机自启等与机器相关的状态)
    func exportSettings() -> BackupSettings {
        BackupSettings(
            refreshInterval: refreshInterval, redUp: redUp, menuBarLabel: menuBarLabel.rawValue,
            menuBarCompact: menuBarCompact, menuBarRotate: menuBarRotate, pinnedSymbols: pinnedSymbols,
            popoverMinimal: popoverMinimal, floatingStyle: floatingStyle.rawValue, floatingSymbols: floatingSymbols,
            floatingOpacity: floatingOpacity, floatingFade: floatingFade, floatingClickThrough: floatingClickThrough,
            autoCheckUpdates: autoCheckUpdates
        )
    }

    /// 导入偏好:只覆盖备份里存在且合法的字段
    func applyImportedSettings(_ s: BackupSettings) {
        if let v = s.refreshInterval, Self.allowedIntervals.contains(v) { refreshInterval = v }
        if let v = s.redUp { redUp = v }
        if let v = s.menuBarLabel, let mode = MenuBarLabelMode(rawValue: v) { menuBarLabel = mode }
        if let v = s.menuBarCompact { menuBarCompact = v }
        if let v = s.menuBarRotate { menuBarRotate = v }
        if let v = s.pinnedSymbols { pinnedSymbols = Array(v.prefix(Self.maxPinned)) }
        if let v = s.popoverMinimal { popoverMinimal = v }
        if let v = s.floatingStyle, let style = FloatingStyle(rawValue: v) { floatingStyle = style }
        if let v = s.floatingSymbols { floatingSymbols = v }
        if let v = s.floatingOpacity { floatingOpacity = min(max(v, 0.3), 1.0) }
        if let v = s.floatingFade { floatingFade = v }
        if let v = s.floatingClickThrough { floatingClickThrough = v }
        if let v = s.autoCheckUpdates { autoCheckUpdates = v }
    }
}

// MARK: - 导出与导入入口

extension BackupFile {
    /// 由当前自选与偏好生成备份
    @MainActor
    static func snapshot(watchlist: WatchlistStore, prefs: Preferences, appVersion: String, now: Date = Date()) -> BackupFile {
        let groups = watchlist.groups.map { g in
            BackupGroup(name: g.name, items: g.items.map { BackupItem(symbol: $0.symbol.full, name: $0.name) })
        }
        return BackupFile(appVersion: appVersion, exportedAt: now, watchlist: groups, settings: prefs.exportSettings())
    }

    /// 建议的文件名:StockMenuBar-backup-20261016.json
    static func suggestedFileName(now: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd"
        return "StockMenuBar-backup-\(f.string(from: now)).json"
    }
}

/// 导入结果摘要
struct BackupImportSummary: Equatable, Sendable {
    var groupsAdded = 0
    var itemsAdded = 0
    var itemsSkipped = 0
    var droppedItems = 0
    var settingsApplied = false

    /// 面向用户的一句话描述
    var message: String {
        var parts = ["新增 \(groupsAdded) 个分组、\(itemsAdded) 个自选"]
        if itemsSkipped > 0 { parts.append("\(itemsSkipped) 个已存在而跳过") }
        if droppedItems > 0 { parts.append("\(droppedItems) 个无法识别而丢弃") }
        if settingsApplied { parts.append("已应用偏好设置") }
        return "导入完成:" + parts.joined(separator: ",")
    }
}

extension BackupFile {
    /// 把备份应用到当前应用
    /// - Parameters:
    ///   - parsed: 已清洗的备份
    ///   - mode: 合并或替换
    ///   - includeSettings: 是否同时导入偏好设置
    @MainActor
    func apply(dropped: Int, mode: BackupImportMode, includeSettings: Bool,
               watchlist: WatchlistStore, prefs: Preferences) -> BackupImportSummary {
        var summary = BackupImportSummary()
        let result = watchlist.importGroups(self.watchlist, mode: mode)
        summary.groupsAdded = result.groupsAdded
        summary.itemsAdded = result.itemsAdded
        summary.itemsSkipped = result.itemsSkipped
        summary.droppedItems = dropped
        if includeSettings, let settings {
            prefs.applyImportedSettings(settings)
            summary.settingsApplied = true
        }
        return summary
    }
}
