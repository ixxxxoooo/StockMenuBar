//
//  StockSymbol.swift
//  StockMenuBar
//
//  证券标识与市场识别:沪(sh)/深(sz)/北交所(bj),并区分创业板、科创板、ETF、指数。
//  @author ixxxxoooo
//

import Foundation

/// 交易所/市场
/// - 期货与全球指数统一归入 `.future`:其 `code` 为东财 secid(如 `113.cum`、`101.HG00Y`),大小写敏感
enum Market: String, Codable, Sendable, CaseIterable {
    case sh, sz, bj
    case future = "fu"

    var title: String {
        switch self {
        case .sh: return "沪"
        case .sz: return "深"
        case .bj: return "京"
        case .future: return "期"
        }
    }
}

/// 证券类别/板块
enum SecurityKind: String, Codable, Sendable {
    case main, gem, star, beijing, etf, index, future

    /// 板块展示名称
    var title: String {
        switch self {
        case .main: return "主板"
        case .gem: return "创业板"
        case .star: return "科创板"
        case .beijing: return "北交所"
        case .etf: return "ETF"
        case .index: return "指数"
        case .future: return "期货"
        }
    }

    /// 价格小数位数(ETF/基金 3 位,其余 2 位;期货以行情自带小数位为准,见 Quote.decimals)
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
        case .future:
            // 东财市场号 100 为全球指数(如日经 225),其余为期货合约
            return code.hasPrefix("100.") ? .index : .future
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

    /// 东财 secid,如 `1.600519`(沪为 1,深/京为 0);期货的 code 本身就是 secid
    var eastmoneySecid: String {
        switch market {
        case .sh: return "1." + code
        case .sz, .bj: return "0." + code
        case .future: return code
        }
    }

    /// 是否为期货/全球指数类标的
    var isFuture: Bool { market == .future }

    /// 界面展示用代码:期货去掉东财市场号,如 `113.cum` → `cum`
    var displayCode: String {
        guard isFuture, let dot = code.firstIndex(of: ".") else { return code }
        return String(code[code.index(after: dot)...])
    }

    /// 界面展示用市场/交易所名称:A 股为 SH/SZ/BJ,期货为上期所、COMEX 等
    var marketTag: String {
        isFuture ? FuturesCatalog.exchangeName(secid: code) : market.rawValue.uppercased()
    }

    init(market: Market, code: String) {
        self.market = market
        self.code = code
    }

    /// 由完整代码构造,如 `sh600519`;格式不合法返回 nil
    init?(full: String) {
        let raw = full.trimmingCharacters(in: .whitespaces)
        // 期货:`fu` + 东财 secid(市场号.代码,代码大小写敏感)
        if raw.hasPrefix("fu"), raw.count > 5 {
            let secid = String(raw.dropFirst(2))
            let parts = secid.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].allSatisfy({ $0.isASCII && $0.isNumber }), !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
            self.init(market: .future, code: secid)
            return
        }
        let text = raw.lowercased()
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
