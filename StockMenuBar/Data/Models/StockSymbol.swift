//
//  StockSymbol.swift
//  StockMenuBar
//
//  证券标识与市场识别:沪(sh)/深(sz)/北交所(bj),并区分创业板、科创板、ETF、指数。
//  @author ixxxxoooo
//

import Foundation

/// 交易所
enum Market: String, Codable, Sendable, CaseIterable {
    case sh, sz, bj

    var title: String {
        switch self {
        case .sh: return "沪"
        case .sz: return "深"
        case .bj: return "京"
        }
    }
}

/// 证券类别/板块
enum SecurityKind: String, Codable, Sendable {
    case main, gem, star, beijing, etf, index

    /// 板块展示名称
    var title: String {
        switch self {
        case .main: return "主板"
        case .gem: return "创业板"
        case .star: return "科创板"
        case .beijing: return "北交所"
        case .etf: return "ETF"
        case .index: return "指数"
        }
    }

    /// 价格小数位数(ETF/基金 3 位,其余 2 位)
    var decimals: Int { self == .etf ? 3 : 2 }

    /// 根据市场与代码推断类别
    /// - Parameters:
    ///   - market: 交易所
    ///   - code: 6 位代码
    static func infer(market: Market, code: String) -> SecurityKind {
        switch market {
        case .sh:
            if code.hasPrefix("000") { return .index }
            if code.hasPrefix("688") || code.hasPrefix("689") { return .star }
            if code.hasPrefix("5") { return .etf }
            return .main
        case .sz:
            if code.hasPrefix("399") { return .index }
            if code.hasPrefix("30") { return .gem }
            if code.hasPrefix("15") || code.hasPrefix("16") { return .etf }
            return .main
        case .bj:
            if code.hasPrefix("899") { return .index }
            return .beijing
        }
    }
}

/// 证券标识(市场 + 代码)
struct StockSymbol: Hashable, Codable, Sendable, Identifiable {
    let market: Market
    let code: String

    var id: String { full }

    /// 带市场前缀的完整代码,如 `sh600519`
    var full: String { market.rawValue + code }

    /// 类别
    var kind: SecurityKind { SecurityKind.infer(market: market, code: code) }

    /// 东财 secid,如 `1.600519`(沪为 1,深/京为 0)
    var eastmoneySecid: String { (market == .sh ? "1." : "0.") + code }

    init(market: Market, code: String) {
        self.market = market
        self.code = code
    }

    /// 由完整代码构造,如 `sh600519`;格式不合法返回 nil
    init?(full: String) {
        let text = full.trimmingCharacters(in: .whitespaces).lowercased()
        guard text.count == 8,
              let market = Market(rawValue: String(text.prefix(2))) else { return nil }
        let code = String(text.suffix(6))
        guard code.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        self.init(market: market, code: code)
    }

    /// 由纯 6 位数字代码按号段识别市场
    /// - 6/5/9/7 开头为沪市,0/2/3/1 开头为深市,4/8 及 92 开头为北交所
    /// - 注意:指数(如 000001)与同号个股冲突,必须经搜索结果的市场前缀确定,此处按个股识别
    /// - Parameter code: 6 位数字
    /// - Returns: 识别失败返回 nil
    static func resolve(code: String) -> StockSymbol? {
        let text = code.trimmingCharacters(in: .whitespaces)
        guard text.count == 6, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        if text.hasPrefix("92") { return StockSymbol(market: .bj, code: text) }
        switch text.first {
        case "6", "5", "9", "7": return StockSymbol(market: .sh, code: text)
        case "0", "2", "3", "1": return StockSymbol(market: .sz, code: text)
        case "4", "8": return StockSymbol(market: .bj, code: text)
        default: return nil
        }
    }
}
