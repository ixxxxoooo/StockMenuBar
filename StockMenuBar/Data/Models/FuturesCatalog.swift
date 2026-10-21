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
        /// 展示名称(所有数据源统一使用该名称,避免故障转移时名称跳变)
        let name: String
        /// 东财 secid
        let secid: String
        /// 拼音首字母(本地联想用)
        let pinyin: String
        /// 新浪代码(含 nf_/hf_/znb_/gb_ 前缀),为空表示无备源
        let sinaCode: String?
        /// 新浪价格换算系数(如 COMEX 铜新浪为美分/磅,东财为美元/磅,系数 0.01)
        let sinaScale: Double
        /// 腾讯代码(如 `usDJI`),为空表示腾讯不支持
        let tencentCode: String?
        /// 雅虎财经代码(如 `^KS11`、`GC=F`),为空表示雅虎不支持
        let yahooCode: String?
        /// TradingView 代码(如 `OANDA:XAUUSD`),为空表示不支持;现货黄金只由它提供
        let tradingViewCode: String?
        /// 东财是否收录(如韩国创业板东财没有)
        let inEastmoney: Bool
        /// 所属主题,用于文档与分组
        let theme: String

        init(_ name: String, _ secid: String, _ pinyin: String, sina: String? = nil, scale: Double = 1,
             tencent: String? = nil, yahoo: String? = nil, tradingView: String? = nil,
             eastmoney: Bool = true, theme: String) {
            self.name = name
            self.secid = secid
            self.pinyin = pinyin
            self.sinaCode = sina
            self.sinaScale = scale
            self.tencentCode = tencent
            self.yahooCode = yahoo
            self.tradingViewCode = tradingView
            self.inEastmoney = eastmoney
            self.theme = theme
        }

        /// 对应的证券标识
        var symbol: StockSymbol { StockSymbol(market: .future, code: secid) }
    }

    /// 默认写入「期货」分组的品种:铜(沪/伦/美)、煤(焦煤/焦炭)
    static let defaults: [Preset] = [
        Preset("沪铜主连", "113.cum", "HTZL", sina: "nf_CU0", theme: "铜"),
        Preset("伦铜", "109.LCPT", "LT", sina: "hf_CAD", theme: "铜"),
        Preset("COMEX铜", "101.HG00Y", "COMEXT", sina: "hf_HG", scale: 0.01, yahoo: "HG=F", theme: "铜"),
        Preset("焦煤主连", "114.jmm", "JMZL", sina: "nf_JM0", theme: "煤"),
        Preset("焦炭主连", "114.jm", "JTZL", sina: "nf_J0", theme: "煤")
    ]

    /// 默认写入「贵金属」分组的品种:纽约金银(COMEX)、伦敦金银(现货)、沪金沪银
    static let preciousMetals: [Preset] = [
        Preset("纽约金", "101.GC00Y", "NYJ", sina: "hf_GC", yahoo: "GC=F", theme: "贵金属"),
        Preset("伦敦金", "122.XAU", "LDJ", sina: "hf_XAU", theme: "贵金属"),
        Preset("纽约银", "101.SI00Y", "NYY", sina: "hf_SI", yahoo: "SI=F", theme: "贵金属"),
        Preset("伦敦银", "122.XAG", "LDY", sina: "hf_XAG", theme: "贵金属"),
        Preset("沪金主连", "113.aum", "HJZL", sina: "nf_AU0", theme: "贵金属"),
        Preset("沪银主连", "113.agm", "HYZL", sina: "nf_AG0", theme: "贵金属"),
        spotGold
    ]

    /// 现货黄金(XAU/USD):不在东财/新浪/雅虎体系内,secid 为自定义的 `999.XAUUSD`,数据全部来自 TradingView
    static let spotGold = Preset("现货黄金", "999.XAUUSD", "XHHJ", tradingView: "OANDA:XAUUSD", eastmoney: false, theme: "贵金属")

    /// 默认写入「全球指数」分组的指数:美股三大指数、日经 225、韩国综合与创业板
    static let globalIndices: [Preset] = [
        Preset("道琼斯", "100.DJIA", "DQS", sina: "gb_$dji", tencent: "usDJI", yahoo: "^DJI", theme: "美股指数"),
        Preset("纳斯达克", "100.NDX", "NSDK", sina: "gb_ixic", tencent: "usIXIC", yahoo: "^IXIC", theme: "美股指数"),
        Preset("标普500", "100.SPX", "BP500", sina: "gb_inx", tencent: "usINX", yahoo: "^GSPC", theme: "美股指数"),
        Preset("日经225", "100.N225", "RJ225", sina: "znb_NKY", yahoo: "^N225", theme: "亚洲指数"),
        Preset("韩国KOSPI", "100.KS11", "HGKOSPI", sina: "znb_KOSPI", yahoo: "^KS11", theme: "亚洲指数"),
        Preset("韩国KOSDAQ", "100.KQ11", "HGKOSDAQ", sina: "znb_KOSDAQ", yahoo: "^KQ11", eastmoney: false, theme: "亚洲指数")
    ]

    /// 可联想的扩展品种(不默认加入自选)
    static let extras: [Preset] = [
        Preset("动力煤主连", "115.ZCM", "DLMZL", sina: "nf_ZC0", theme: "煤"),
        Preset("国际铜主连", "142.bcm", "GJTZL", sina: "nf_BC0", theme: "铜"),
        Preset("纽约原油", "102.CL00Y", "NYYY", sina: "hf_CL", yahoo: "CL=F", theme: "能源"),
        Preset("布伦特原油", "112.B00Y", "BLTYY", sina: "hf_OIL", yahoo: "BZ=F", theme: "能源"),
        Preset("韩国KOSPI200", "100.KOSPI200", "HGKOSPI200", yahoo: "^KS200", theme: "亚洲指数"),
        Preset("德国DAX30", "100.GDAXI", "DGDAX30", yahoo: "^GDAXI", theme: "欧洲指数"),
        Preset("英国富时100", "100.FTSE", "YGFS100", yahoo: "^FTSE", theme: "欧洲指数"),
        Preset("法国CAC40", "100.FCHI", "FGCAC40", yahoo: "^FCHI", theme: "欧洲指数"),
        Preset("纳斯达克100", "100.NDX100", "NSDK100", yahoo: "^NDX", theme: "美股指数")
    ]

    /// 首次安装与升级时写入的分组(名称, 品种)
    static let groupSeeds: [(name: String, presets: [Preset])] = [
        ("期货", defaults),
        ("贵金属", preciousMetals),
        ("全球指数", globalIndices)
    ]

    /// 全部预置
    static var all: [Preset] { defaults + preciousMetals + globalIndices + extras }

    /// 按 secid 查找预置
    static func preset(secid: String) -> Preset? { all.first { $0.secid == secid } }

    /// 东财是否可能收录该标的(未收录的预置品种直接跳过,避免无意义的失败计数)
    static func eastmoneySupports(secid: String) -> Bool { preset(secid: secid)?.inEastmoney ?? true }

    /// 腾讯代码(仅美股指数等少数品种)
    static func tencentCode(secid: String) -> String? { preset(secid: secid)?.tencentCode }

    /// 雅虎代码
    static func yahooCode(secid: String) -> String? { preset(secid: secid)?.yahooCode }

    /// TradingView 代码
    static func tradingViewCode(secid: String) -> String? { preset(secid: secid)?.tradingViewCode }

    /// 腾讯行情键到证券的反查
    static func symbol(tencentKey: String, among requested: [StockSymbol]) -> StockSymbol? {
        requested.first { s in s.isFuture && tencentCode(secid: s.code)?.lowercased() == tencentKey.lowercased() }
    }

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
        case "112": return "ICE"
        case "122": return "伦敦现货"
        case "999": return "现货"
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
