//
//  BackupTests.swift
//  StockMenuBarTests
//
//  备份导入/导出:编解码往返、清洗校验、合并/替换语义、偏好导入。
//  @author ixxxxoooo
//

import Foundation
import Testing

@MainActor
struct BackupTests {
    /// 构造隔离的偏好存储
    private func makePrefs() -> Preferences {
        let name = "backup-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return Preferences(defaults: defaults)
    }

    private func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private var validHeader: [String: Any] {
        ["format": BackupFile.formatID, "schemaVersion": 1, "appVersion": "1.0", "exportedAt": "2026-10-16T08:00:00Z"]
    }

    @Test func 导出再解析往返一致() throws {
        let store = WatchlistStore(inMemory: true)
        let prefs = makePrefs()
        prefs.refreshInterval = 10
        prefs.redUp = false
        prefs.floatingOpacity = 0.5
        prefs.pinnedSymbols = ["sh600519"]
        let file = BackupFile.snapshot(watchlist: store, prefs: prefs, appVersion: "1.3.0")
        let parsed = try BackupCodec.parse(BackupCodec.encode(file))
        #expect(parsed.droppedItems == 0)
        #expect(parsed.file.watchlist == file.watchlist)
        #expect(parsed.file.watchlist.map(\.name) == store.groups.map(\.name))
        #expect(parsed.file.settings?.refreshInterval == 10)
        #expect(parsed.file.settings?.redUp == false)
        #expect(parsed.file.settings?.pinnedSymbols == ["sh600519"])
        #expect(abs(parsed.file.exportedAt.timeIntervalSince(file.exportedAt)) < 1)
    }

    @Test func 导出文件不含机器相关状态() throws {
        let store = WatchlistStore(inMemory: true)
        let prefs = makePrefs()
        prefs.skippedUpdateVersion = "9.9.9"
        prefs.lastUpdateCheck = Date()
        prefs.saveFloatingOrigin(x: 123, y: 456)
        let text = String(decoding: try BackupCodec.encode(.snapshot(watchlist: store, prefs: prefs, appVersion: "1")), as: UTF8.self)
        #expect(!text.contains("skippedUpdateVersion"))
        #expect(!text.contains("lastUpdateCheck"))
        #expect(!text.contains("floatingOrigin"))
        #expect(!text.contains("launchAtLogin"))
    }

    @Test func 非备份文件被拒绝() throws {
        #expect(throws: BackupError.notBackupFile) { try BackupCodec.parse(Data("hello".utf8)) }
        #expect(throws: BackupError.notBackupFile) { try BackupCodec.parse(json(["foo": "bar"])) }
        #expect(throws: BackupError.notBackupFile) { try BackupCodec.parse(json(["format": "other"])) }
    }

    @Test func 更新版本的备份被拒绝() throws {
        var obj = validHeader
        obj["schemaVersion"] = 99
        obj["watchlist"] = [[String: Any]]()
        #expect(throws: BackupError.newerVersion(99)) { try BackupCodec.parse(json(obj)) }
    }

    @Test func 体积超限被拒绝() {
        #expect(throws: BackupError.tooLarge) { try BackupCodec.parse(Data(count: BackupCodec.maxBytes + 1)) }
    }

    @Test func 空自选被拒绝() throws {
        var obj = validHeader
        obj["watchlist"] = [["name": "  ", "items": [[String: String]]()]]
        #expect(throws: BackupError.empty) { try BackupCodec.parse(json(obj)) }
    }

    @Test func 结构损坏给出可读错误() throws {
        var obj = validHeader
        obj["watchlist"] = "oops"
        #expect(throws: BackupError.unreadable("格式不正确")) { try BackupCodec.parse(json(obj)) }
    }

    @Test func 清洗非法代码重复项与重名分组() throws {
        var obj = validHeader
        obj["watchlist"] = [
            ["name": " 我的 ", "items": [
                ["symbol": "sh600519", "name": "贵州茅台"],
                ["symbol": "sh600519", "name": "重复"],
                ["symbol": "bogus", "name": "非法"],
                ["symbol": "sz000001", "name": "  "]
            ]],
            ["name": "我的", "items": [["symbol": "sh600036", "name": "招商银行"]]]
        ]
        let parsed = try BackupCodec.parse(json(obj))
        #expect(parsed.droppedItems == 1)
        #expect(parsed.file.watchlist.count == 1)
        let group = parsed.file.watchlist[0]
        #expect(group.name == "我的")
        #expect(group.items.map(\.symbol) == ["sh600519", "sz000001"])
        #expect(group.items[1].name == "000001")
    }

    @Test func 未知字段被忽略且设置越界被丢弃() throws {
        var obj = validHeader
        obj["futureField"] = ["x": 1]
        obj["watchlist"] = [["name": "A", "items": [["symbol": "sh600519", "name": "茅台"]]]]
        obj["settings"] = [
            "refreshInterval": 7, "floatingOpacity": 5.0, "menuBarLabel": "nope", "floatingStyle": "card",
            "pinnedSymbols": ["sh600519", "bad", "sh600519", "sz000001", "sz000002"]
        ]
        let settings = try #require(try BackupCodec.parse(json(obj)).file.settings)
        #expect(settings.refreshInterval == nil)
        #expect(settings.floatingOpacity == 1.0)
        #expect(settings.menuBarLabel == nil)
        #expect(settings.floatingStyle == "card")
        #expect(settings.pinnedSymbols == ["sh600519", "sz000001"])
    }

    @Test func 替换导入会清空现有并还原顺序() throws {
        let store = WatchlistStore(inMemory: true)
        let groups = [
            BackupGroup(name: "港美", items: [BackupItem(symbol: "sh600036", name: "招商银行"), BackupItem(symbol: "sz000001", name: "平安银行")]),
            BackupGroup(name: "空组", items: [])
        ]
        let result = store.importGroups(groups, mode: .replace)
        #expect(result == WatchlistStore.ImportResult(groupsAdded: 2, itemsAdded: 2, itemsSkipped: 0))
        #expect(store.groups.map(\.name) == ["港美", "空组"])
        #expect(store.groups[0].items.map(\.symbol.full) == ["sh600036", "sz000001"])
        #expect(store.selectedGroup?.name == "港美")
    }

    @Test func 合并导入保留现有只补充缺失() throws {
        let store = WatchlistStore(inMemory: true)
        let before = store.groups
        let groups = [
            // 同名分组:茅台已存在,招商银行为新增
            BackupGroup(name: "自选A", items: [BackupItem(symbol: "sh600519", name: "贵州茅台"), BackupItem(symbol: "sh600036", name: "招商银行")]),
            BackupGroup(name: "新分组", items: [BackupItem(symbol: "sh600519", name: "贵州茅台")])
        ]
        let result = store.importGroups(groups, mode: .merge)
        #expect(result == WatchlistStore.ImportResult(groupsAdded: 1, itemsAdded: 2, itemsSkipped: 1))
        #expect(store.groups.count == before.count + 1)
        #expect(store.groups.last?.name == "新分组")
        let a = try #require(store.groups.first { $0.name == "自选A" })
        #expect(a.items.map(\.symbol.full) == ["sh600519", "sz000001", "sz300750", "sh600036"])
        // 其他分组不受影响
        #expect(store.groups.first { $0.name == "大盘" }?.items.count == 4)
    }

    @Test func 合并导入同一文件两次不会重复() throws {
        let store = WatchlistStore(inMemory: true)
        let groups = [BackupGroup(name: "X", items: [BackupItem(symbol: "sh600036", name: "招商银行")])]
        store.importGroups(groups, mode: .merge)
        let second = store.importGroups(groups, mode: .merge)
        #expect(second == WatchlistStore.ImportResult(groupsAdded: 0, itemsAdded: 0, itemsSkipped: 1))
        #expect(store.groups.filter { $0.name == "X" }.count == 1)
    }

    @Test func 导入偏好只覆盖存在的字段() {
        let prefs = makePrefs()
        prefs.refreshInterval = 5
        prefs.menuBarCompact = true
        prefs.applyImportedSettings(BackupSettings(refreshInterval: 10, redUp: false, floatingStyle: "card", floatingOpacity: 9))
        #expect(prefs.refreshInterval == 10)
        #expect(!prefs.redUp)
        #expect(prefs.floatingStyle == .card)
        #expect(prefs.floatingOpacity == 1.0)
        #expect(prefs.menuBarCompact, "备份里没有的字段保持原值")
    }

    @Test func 完整迁移流程_旧机器导出新机器导入() throws {
        let oldStore = WatchlistStore(inMemory: true)
        _ = oldStore.addGroup(name: "我的组合")
        let mine = try #require(oldStore.groups.first { $0.name == "我的组合" })
        oldStore.add(symbol: StockSymbol(full: "sh601318")!, name: "中国平安", to: mine.id)
        let oldPrefs = makePrefs()
        oldPrefs.refreshInterval = 10
        let data = try BackupCodec.encode(.snapshot(watchlist: oldStore, prefs: oldPrefs, appVersion: "1.3.0"))

        let newStore = WatchlistStore(inMemory: true)
        let newPrefs = makePrefs()
        let parsed = try BackupCodec.parse(data)
        let summary = parsed.file.apply(dropped: parsed.droppedItems, mode: .replace, includeSettings: true,
                                        watchlist: newStore, prefs: newPrefs)
        #expect(summary.settingsApplied)
        #expect(newStore.groups.map(\.name) == oldStore.groups.map(\.name))
        #expect(newStore.groups.map { $0.items.map(\.symbol.full) } == oldStore.groups.map { $0.items.map(\.symbol.full) })
        #expect(newPrefs.refreshInterval == 10)
    }

    @Test func 建议文件名带日期() {
        let date = Date(timeIntervalSince1970: 1_792_000_000)
        #expect(BackupFile.suggestedFileName(now: date).hasPrefix("StockMenuBar-backup-2026"))
        #expect(BackupFile.suggestedFileName(now: date).hasSuffix(".json"))
    }
}
