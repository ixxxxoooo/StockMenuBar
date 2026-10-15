//
//  WatchlistModels.swift
//  StockMenuBar
//
//  自选股持久化模型(SwiftData)与界面使用的值类型快照。
//  @author ixxxxoooo
//

import Foundation
import SwiftData

/// 分组持久化实体
@Model
final class GroupEntity {
    @Attribute(.unique) var id: UUID
    var name: String
    var order: Int
    @Relationship(deleteRule: .cascade, inverse: \ItemEntity.group) var items: [ItemEntity] = []

    init(id: UUID = UUID(), name: String, order: Int) {
        self.id = id
        self.name = name
        self.order = order
    }
}

/// 自选股持久化实体
@Model
final class ItemEntity {
    @Attribute(.unique) var id: UUID
    /// 完整代码,如 sh600519
    var symbolFull: String
    var name: String
    var order: Int
    var group: GroupEntity?

    init(id: UUID = UUID(), symbolFull: String, name: String, order: Int, group: GroupEntity? = nil) {
        self.id = id
        self.symbolFull = symbolFull
        self.name = name
        self.order = order
        self.group = group
    }
}

/// 自选条目快照(值类型,供界面使用)
struct WatchItem: Identifiable, Hashable, Sendable {
    let id: UUID
    let symbol: StockSymbol
    var name: String
}

/// 分组快照
struct WatchGroup: Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var items: [WatchItem]
}
