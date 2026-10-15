//
//  WatchlistStore.swift
//  StockMenuBar
//
//  自选股与分组管理:SwiftData 持久化,对外暴露值类型快照,支持增删改与拖拽排序。
//  @author ixxxxoooo
//

import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class WatchlistStore {
    /// 分组快照(按 order 升序)
    private(set) var groups: [WatchGroup] = []
    /// 当前选中分组(Popover 加自选的目标分组)
    var selectedGroupID: UUID?

    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private var context: ModelContext { container.mainContext }

    /// 全部不重复的自选证券
    var allSymbols: [StockSymbol] {
        var seen = Set<StockSymbol>()
        var result: [StockSymbol] = []
        for group in groups {
            for item in group.items where seen.insert(item.symbol).inserted { result.append(item.symbol) }
        }
        return result
    }

    /// 当前选中的分组
    var selectedGroup: WatchGroup? {
        groups.first(where: { $0.id == selectedGroupID }) ?? groups.first
    }

    /// - Parameter inMemory: 为 true 时使用内存存储(测试)
    init(inMemory: Bool = false) {
        let schema = Schema([GroupEntity.self, ItemEntity.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        if let c = try? ModelContainer(for: schema, configurations: [config]) {
            container = c
        } else {
            // 磁盘存储失败时退回内存,保证应用可用
            let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            // swiftlint:disable:next force_try
            container = try! ModelContainer(for: schema, configurations: [memory])
        }
        seedIfNeeded()
        if !inMemory { migrateFuturesGroupIfNeeded() }
        reload()
        selectedGroupID = groups.first?.id
    }

    // MARK: - 查询

    /// 指定分组是否已包含某证券
    func contains(_ symbol: StockSymbol, in groupID: UUID?) -> Bool {
        guard let group = groups.first(where: { $0.id == groupID }) else { return false }
        return group.items.contains { $0.symbol == symbol }
    }

    /// 全局是否已自选某证券
    func containsAnywhere(_ symbol: StockSymbol) -> Bool {
        groups.contains { g in g.items.contains { $0.symbol == symbol } }
    }

    /// 按 id 查找条目
    func item(id: UUID) -> WatchItem? {
        for g in groups { if let i = g.items.first(where: { $0.id == id }) { return i } }
        return nil
    }

    /// 按证券查找首个条目
    func firstItem(for symbol: StockSymbol) -> WatchItem? {
        for g in groups { if let i = g.items.first(where: { $0.symbol == symbol }) { return i } }
        return nil
    }

    // MARK: - 条目操作

    /// 加入自选
    /// - Parameters:
    ///   - result: 搜索结果
    ///   - groupID: 目标分组,为空则使用当前选中分组
    /// - Returns: 是否新增成功(已存在则返回 false)
    @discardableResult
    func add(_ result: SearchResult, to groupID: UUID? = nil) -> Bool {
        add(symbol: result.symbol, name: result.name, to: groupID)
    }

    /// 加入自选(按证券与名称)
    @discardableResult
    func add(symbol: StockSymbol, name: String, to groupID: UUID? = nil) -> Bool {
        let targetID = groupID ?? selectedGroup?.id
        guard let entity = groupEntity(id: targetID) else { return false }
        if entity.items.contains(where: { $0.symbolFull == symbol.full }) { return false }
        let order = (entity.items.map(\.order).max() ?? -1) + 1
        let item = ItemEntity(symbolFull: symbol.full, name: name, order: order, group: entity)
        context.insert(item)
        persist()
        return true
    }

    /// 从分组中移除条目
    func remove(itemID: UUID) {
        guard let entity = itemEntity(id: itemID) else { return }
        context.delete(entity)
        persist()
    }

    /// 拖拽排序:在分组内移动条目
    func moveItems(in groupID: UUID, from source: IndexSet, to destination: Int) {
        guard let g = groupEntity(id: groupID) else { return }
        var sorted = g.items.sorted { $0.order < $1.order }
        sorted.move(fromOffsets: source, toOffset: destination)
        for (i, item) in sorted.enumerated() { item.order = i }
        persist()
    }

    /// 将条目移动到另一个分组末尾
    func moveItem(itemID: UUID, toGroup groupID: UUID) {
        guard let item = itemEntity(id: itemID), let target = groupEntity(id: groupID), item.group?.id != groupID else { return }
        if target.items.contains(where: { $0.symbolFull == item.symbolFull }) { return }
        item.group = target
        item.order = (target.items.map(\.order).max() ?? -1) + 1
        persist()
    }

    // MARK: - 分组操作

    /// 新建分组
    @discardableResult
    func addGroup(name: String) -> UUID? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let entity = GroupEntity(name: trimmed, order: groups.count)
        context.insert(entity)
        persist()
        return entity.id
    }

    /// 重命名分组
    func renameGroup(id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let g = groupEntity(id: id) else { return }
        g.name = trimmed
        persist()
    }

    /// 删除分组(级联删除其中自选);至少保留一个分组
    func deleteGroup(id: UUID) {
        guard groups.count > 1, let g = groupEntity(id: id) else { return }
        context.delete(g)
        persist()
        if selectedGroupID == id { selectedGroupID = groups.first?.id }
    }

    /// 分组拖拽排序
    func moveGroups(from source: IndexSet, to destination: Int) {
        let all = (try? context.fetch(FetchDescriptor<GroupEntity>(sortBy: [SortDescriptor(\.order)]))) ?? []
        var sorted = all
        sorted.move(fromOffsets: source, toOffset: destination)
        for (i, g) in sorted.enumerated() { g.order = i }
        persist()
    }

    // MARK: - 内部

    private func groupEntity(id: UUID?) -> GroupEntity? {
        guard let id else { return nil }
        let all = (try? context.fetch(FetchDescriptor<GroupEntity>())) ?? []
        return all.first { $0.id == id }
    }

    private func itemEntity(id: UUID) -> ItemEntity? {
        let all = (try? context.fetch(FetchDescriptor<ItemEntity>())) ?? []
        return all.first { $0.id == id }
    }

    private func persist() {
        try? context.save()
        reload()
    }

    /// 从数据库重新加载快照
    private func reload() {
        let entities = (try? context.fetch(FetchDescriptor<GroupEntity>(sortBy: [SortDescriptor(\.order)]))) ?? []
        groups = entities.map { g in
            let items = g.items.sorted { $0.order < $1.order }.compactMap { e -> WatchItem? in
                guard let s = StockSymbol(full: e.symbolFull) else { return nil }
                return WatchItem(id: e.id, symbol: s, name: e.name)
            }
            return WatchGroup(id: g.id, name: g.name, items: items)
        }
        if selectedGroupID == nil || !groups.contains(where: { $0.id == selectedGroupID }) {
            selectedGroupID = groups.first?.id
        }
    }

    /// 首次启动写入默认分组与示例数据
    private func seedIfNeeded() {
        let count = (try? context.fetchCount(FetchDescriptor<GroupEntity>())) ?? 0
        guard count == 0 else { return }
        let seeds: [(String, [(String, String)])] = [
            ("大盘", [("sh000001", "上证指数"), ("sz399001", "深证成指"), ("sz399006", "创业板指"), ("sh000300", "沪深300")]),
            ("自选A", [("sh600519", "贵州茅台"), ("sz000001", "平安银行"), ("sz300750", "宁德时代")]),
            ("自选B", []),
            ("ETF", [("sh510300", "沪深300ETF"), ("sz159915", "创业板ETF")]),
            ("期货", FuturesCatalog.defaults.map { ($0.symbol.full, $0.name) })
        ]
        for (gi, seed) in seeds.enumerated() {
            let g = GroupEntity(name: seed.0, order: gi)
            context.insert(g)
            for (ii, item) in seed.1.enumerated() {
                context.insert(ItemEntity(symbolFull: item.0, name: item.1, order: ii, group: g))
            }
        }
        try? context.save()
        UserDefaults.standard.set(true, forKey: Self.futuresSeededKey)
    }

    /// 期货分组是否已写入过的标记(只写一次,用户删除后不再自动恢复)
    private static let futuresSeededKey = "watchlist.futuresSeeded"

    /// 老用户升级:自动追加「期货」分组与预置品种(铜、煤、日经),仅执行一次
    private func migrateFuturesGroupIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.futuresSeededKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.futuresSeededKey)
        let existing = (try? context.fetch(FetchDescriptor<GroupEntity>())) ?? []
        guard !existing.contains(where: { $0.name == "期货" }) else { return }
        let g = GroupEntity(name: "期货", order: existing.count)
        context.insert(g)
        for (i, preset) in FuturesCatalog.defaults.enumerated() {
            context.insert(ItemEntity(symbolFull: preset.symbol.full, name: preset.name, order: i, group: g))
        }
        try? context.save()
    }
}
