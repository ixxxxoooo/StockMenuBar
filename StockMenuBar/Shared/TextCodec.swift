//
//  TextCodec.swift
//  StockMenuBar
//
//  文本编码与拼音工具:GBK 解码、拼音首字母。
//  @author ixxxxoooo
//

import Foundation

enum TextCodec {
    /// GB18030 编码(GBK 的超集),用于解码腾讯/新浪行情返回
    static let gb18030: String.Encoding = {
        let cfEnc = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEnc))
    }()

    /// 将响应数据解码为字符串:优先 UTF-8,失败再用 GB18030
    /// - Parameter data: 原始响应
    /// - Returns: 解码后的文本;全部失败返回 nil
    static func decode(_ data: Data) -> String? {
        if let utf8 = String(data: data, encoding: .utf8), !utf8.contains("\u{FFFD}") { return utf8 }
        return String(data: data, encoding: gb18030)
    }

    /// 强制按 GB18030 解码
    static func decodeGBK(_ data: Data) -> String? {
        String(data: data, encoding: gb18030)
    }
}

enum Pinyin {
    /// 多音字词组的拼音首字母修正表
    private static let polyphonic: [(String, String)] = [
        ("银行", "YH"), ("重庆", "CQ"), ("长江", "CJ"), ("长城", "CC"), ("长春", "CC"), ("长安", "CA"),
        ("长虹", "CH"), ("厦门", "XM"), ("朝阳", "CY"), ("曾", "Z"), ("蚌埠", "BB"), ("六安", "LA")
    ]

    /// 生成拼音首字母(大写),如「贵州茅台」→ `GZMT`;字母数字原样保留(大写),其他符号忽略
    /// - Parameter text: 中文名称
    /// - Returns: 首字母串
    static func initials(_ text: String) -> String {
        var result = ""
        var rest = Substring(text)
        while let ch = rest.first {
            // 多音字常见词组按词处理(如「银行」读 yin hang 而非 yin xing)
            if let (word, abbr) = polyphonic.first(where: { rest.hasPrefix($0.0) }) {
                result += abbr
                rest = rest.dropFirst(word.count)
                continue
            }
            rest = rest.dropFirst()
            guard let scalar = ch.unicodeScalars.first else { continue }
            if (0x4E00...0x9FFF).contains(scalar.value) {
                let m = NSMutableString(string: String(ch)) as CFMutableString
                CFStringTransform(m, nil, kCFStringTransformMandarinLatin, false)
                CFStringTransform(m, nil, kCFStringTransformStripDiacritics, false)
                if let first = (m as String).first { result.append(Character(first.uppercased())) }
            } else if ch.isLetter || ch.isNumber {
                result.append(Character(ch.uppercased()))
            }
        }
        return result
    }

    /// 判断名称/代码是否匹配关键字(支持中文子串、代码子串、拼音首字母前缀)
    /// - Parameters:
    ///   - keyword: 用户输入
    ///   - name: 股票名称
    ///   - code: 6 位代码
    static func matches(keyword: String, name: String, code: String) -> Bool {
        let key = keyword.trimmingCharacters(in: .whitespaces)
        if key.isEmpty { return true }
        if name.localizedCaseInsensitiveContains(key) { return true }
        if code.contains(key) { return true }
        return initials(name).hasPrefix(key.uppercased())
    }
}
