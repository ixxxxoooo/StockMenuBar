//
//  FuturesCatalog.swift
//  StockMenuBar
//
//  期货品种目录:预置常用品种(铜、煤、日经等)、交易所识别、新浪代码映射与夜盘时段模板。
//  - 标的统一以东财 secid(`市场号.代码`)标识,如 `113.cum`(沪铜主连)、`101.HG00Y`(COMEX 铜)
//  - 国内合约可由 secid 直接推导新浪代码(`cu2612` → `nf_CU2612`);外盘与主连需查预置表
//  @author ixxxxoooo
//

import Foundation

enum FuturesCatalog {
    /// 预置品种
    struct Preset: Sendable, Equatable {
        /// 展示名称
        let name: String
        /// 东财 secid
        let secid: String
        /// 拼音首字母(本地联想用)
        let pinyin: String
        /// 新浪代码(含 nf_/hf_ 前缀),为空表示无备源
        let sinaCode: String?
        /// 新浪价格换算系数(如 COMEX 铜新浪为美分/磅,东财为美元/磅,系数 0.01)
        let sinaScale: Double
        /// 所属主题,用于文档与分组
        let theme: String

        init(_ name: String, _ secid: String, _ pinyin: String, sina: String? = nil, scale: Double = 1, theme: String) {
            self.name = name
            self.secid = secid
            self.pinyin = pinyin
            self.sinaCode = sina
            self.sinaScale = scale
            self.theme = theme
        }

        /// 对应的证券标识
        var symbol: StockSymbol { StockSymbol(market: .future, code: secid) }
    }

    /// 默认写入「期货」分组的品种:铜(沪/伦/美)、煤(焦煤/焦炭)、东京(日经 225)
    static let defaults: [Preset] = [
        Preset("沪铜主连", "113.cum", "HTZL", sina: "nf_CU0", theme: "铜"),
        Preset("伦铜", "109.LCPT", "LT", sina: "hf_CAD", theme: "铜"),
        Preset("COMEX铜", "101.HG00Y", "COMEXT", sina: "hf_HG", scale: 0.01, theme: "铜"),
        Preset("焦煤主连", "114.jmm", "JMZL", sina: "nf_JM0", theme: "煤"),
        Preset("焦炭主连", "114.jm", "JTZL", sina: "nf_J0", theme: "煤"),
        Preset("日经225", "100.N225", "RJ225", sina: "znb_NKY", theme: "东京")
    ]

    /// 可联想的扩展品种(不默认加入自选)
    static let extras: [Preset] = [
        Preset("动力煤主连", "115.ZCM", "DLMZL", sina: "nf_ZC0", theme: "煤"),
        Preset("国际铜主连", "142.bcm", "GJTZL", sina: "nf_BC0", theme: "铜"),
        Preset("纽约原油", "102.CL00Y", "NYYY", sina: "hf_CL", theme: "能源")
    ]

    /// 全部预置
    static var all: [Preset] { defaults + extras }

    /// 按 secid 查找预置
    static func preset(secid: String) -> Preset? { all.first { $0.secid == secid } }

    // MARK: - 交易所

    /// 国内期货市场号:上期所 113、大商所 114、郑商所 115、能源中心 142、广期所 225、中金所 8
    static let domesticMarkets: Set<String> = ["113", "114", "115", "142", "225", "8"]

    /// 由 secid 取市场号
    static func marketNumber(secid: String) -> String {
        secid.split(separator: ".").first.map(String.init) ?? ""
    }

    /// 是否国内期货
    static func isDomestic(secid: String) -> Bool { domesticMarkets.contains(marketNumber(secid: secid)) }

    /// 交易所名称
    static func exchangeName(secid: String) -> String {
        switch marketNumber(secid: secid) {
        case "113": return "上期所"
        case "114": return "大商所"
        case "115": return "郑商所"
        case "142": return "能源中心"
        case "225": return "广期所"
        case "8": return "中金所"
        case "101": return "COMEX"
        case "102": return "NYMEX"
        case "103": return "CBOT"
        case "109": return "LME"
        case "100": return "全球指数"
        default: return "外盘"
        }
    }

    // MARK: - 新浪映射

    /// 新浪代码与价格换算系数
    /// - 优先查预置表;国内具体合约(字母 + 数字,如 `cu2612`)直接推导
    /// - Returns: 无备源时返回 nil
    static func sinaMapping(secid: String) -> (code: String, scale: Double)? {
        if let preset = preset(secid: secid), let code = preset.sinaCode { return (code, preset.sinaScale) }
        guard isDomestic(secid: secid), marketNumber(secid: secid) != "8" else { return nil }
        let code = secid.split(separator: ".", maxSplits: 1).last.map(String.init) ?? ""
        guard let split = code.firstIndex(where: { $0.isNumber }), split != code.startIndex,
              code[split...].allSatisfy({ $0.isNumber }) else { return nil }
        var product = String(code[..<split]).uppercased()
        var digits = String(code[split...])
        // 郑商所合约东财为 3 位(月份),新浪为 4 位(年+月)
        if marketNumber(secid: secid) == "115", digits.count == 3 { digits = "2" + digits }
        if product.isEmpty { product = code.uppercased() }
        return ("nf_" + product + digits, 1)
    }

    /// 新浪行情键(不含 nf_/hf_ 前缀的原始代码)到证券的反查,用于解析响应
    static func symbol(sinaKey: String, among requested: [StockSymbol]) -> (symbol: StockSymbol, scale: Double)? {
        for s in requested where s.isFuture {
            if let m = sinaMapping(secid: s.code), m.code.lowercased() == sinaKey.lowercased() { return (s, m.scale) }
        }
        return nil
    }

    // MARK: - 国内夜盘模板

    /// 夜盘结束时刻(自夜盘当天零点起的分钟):无夜盘返回 nil
    /// - 有色金属 01:00;贵金属、原油 02:30;黑色、橡胶、油脂油料、化工等 23:00
    /// - Parameters:
    ///   - product: 品种代码(小写字母,如 `cu`)
    ///   - observedNight: 数据中是否观察到 21:00 开盘(用于未收录品种)
    static func nightEnd(product: String, observedNight: Bool) -> Int? {
        let p = product.lowercased()
        if ["cu", "al", "zn", "pb", "sn", "ni", "ss", "bc"].contains(p) { return 25 * 60 }
        if ["au", "ag", "sc"].contains(p) { return 26 * 60 + 30 }
        if ["rb", "hc", "ru", "bu", "fu", "sp", "nr", "lu", "i", "j", "jm", "a", "b", "m", "y", "p", "c", "cs",
            "l", "v", "pp", "eg", "eb", "pg", "ma", "ta", "sr", "cf", "fg", "rm", "oi", "zc", "sa", "pf", "px", "sh"].contains(p) {
            return 23 * 60
        }
        if ["if", "ih", "ic", "im", "t", "tf", "ts", "tl", "ap", "cj", "pk", "jd", "lh", "lc", "si", "ur", "sm", "sf", "pm", "wh", "ri", "lr", "jr", "rs", "ec"].contains(p) { return nil }
        return observedNight ? 23 * 60 : nil
    }

    /// 国内期货标准时间轴:[夜盘 21:00-夜盘结束] + 9:00-10:15 + 10:30-11:30 + 13:30-15:00
    /// 夜盘与日盘首尾相接;有夜盘时日盘分钟数加 1440(次日)。
    static func domesticAxis(nightEnd: Int?) -> MinuteAxis {
        let base = nightEnd == nil ? 0 : 1440
        var segments: [MinuteAxis.Segment] = []
        if let nightEnd { segments.append(.init(start: 21 * 60, end: nightEnd)) }
        segments += [
            .init(start: base + 9 * 60, end: base + 10 * 60 + 15),
            .init(start: base + 10 * 60 + 30, end: base + 11 * 60 + 30),
            .init(start: base + 13 * 60 + 30, end: base + 15 * 60)
        ]
        return MinuteAxis(segments: segments)
    }

    /// 由 secid 提取品种代码(字母部分,如 `113.cu2612` → `cu`;主连 `113.cum` 去掉末尾 m 的情形由预置表处理)
    static func productCode(secid: String) -> String {
        let code = secid.split(separator: ".", maxSplits: 1).last.map(String.init) ?? ""
        let letters = code.prefix { $0.isLetter }
        return String(letters)
    }

    // MARK: - 本地联想

    /// 在预置品种中按名称、拼音首字母或代码匹配(离线可用)
    /// - Parameter keyword: 关键字
    static func localSearch(_ keyword: String) -> [SearchResult] {
        let key = keyword.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return [] }
        let upper = key.uppercased()
        return all.filter {
            $0.name.contains(key) || $0.pinyin.hasPrefix(upper)
                || $0.secid.lowercased().contains(key.lowercased()) || $0.theme == key
        }
        .map { SearchResult(symbol: $0.symbol, name: $0.name, pinyin: $0.pinyin) }
    }
}
