//
//  ReleaseInfo.swift
//  StockMenuBar
//
//  GitHub Release 元数据与解析:从 releases/latest 的 JSON 中提取版本、说明、安装包与校验值。
//  @author ixxxxoooo
//

import Foundation

/// 一个可安装的发布版本
struct ReleaseInfo: Equatable, Sendable, Identifiable {
    /// 语义化版本
    let version: SemanticVersion
    /// 原始标签(如 v1.2.0)
    let tag: String
    /// 发布标题
    let name: String
    /// 更新说明(Markdown 原文)
    let notes: String
    /// Release 网页
    let pageURL: URL
    /// 发布时间
    let publishedAt: Date?
    /// 安装包(zip)下载地址
    let zipURL: URL
    /// 安装包文件名
    let zipName: String
    /// 安装包大小(字节),未知为 0
    let zipSize: Int64
    /// 安装包 SHA-256(小写十六进制),API 未提供时为 nil
    let sha256: String?
    /// 校验文件(*.sha256)地址,没有内置摘要时用它取得校验值
    let checksumURL: URL?

    var id: String { tag }
}

/// 更新相关错误
enum UpdateError: LocalizedError, Equatable {
    case noInstallableAsset
    case invalidResponse
    case checksumMissing
    case checksumMismatch
    case downloadFailed(String)
    case unpackFailed(String)
    case validationFailed(String)
    case cannotInstallInPlace(String)
    case installerLaunchFailed(String)

    var errorDescription: String? {
        switch self {
        case .noInstallableAsset: return "该版本没有可用的 macOS 安装包"
        case .invalidResponse: return "更新服务器返回的数据无法识别"
        case .checksumMissing: return "该版本缺少校验信息,已拒绝自动安装"
        case .checksumMismatch: return "安装包校验失败,文件可能已损坏或被篡改"
        case .downloadFailed(let m): return "下载失败:\(m)"
        case .unpackFailed(let m): return "解压失败:\(m)"
        case .validationFailed(let m): return "新版本校验未通过:\(m)"
        case .cannotInstallInPlace(let m): return m
        case .installerLaunchFailed(let m): return "无法启动安装程序:\(m)"
        }
    }
}

/// GitHub Release JSON 解析器(纯函数)
enum GitHubReleaseParser {
    private struct Asset: Decodable {
        let name: String
        let size: Int64?
        let browserDownloadUrl: URL
        let digest: String?
    }

    private struct Payload: Decodable {
        let tagName: String
        let name: String?
        let body: String?
        let htmlUrl: URL
        let draft: Bool?
        let prerelease: Bool?
        let publishedAt: Date?
        let assets: [Asset]
    }

    /// 安装包命名约定:`StockMenuBar-<版本>-macOS.zip`
    static func isInstallableAsset(_ name: String) -> Bool { name.hasSuffix("-macOS.zip") }

    /// 解析 releases/latest 响应
    /// - Parameter data: JSON 数据
    /// - Returns: 发布信息;草稿、版本号无法识别、没有安装包时抛出错误
    static func parse(_ data: Data) throws -> ReleaseInfo {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        let payload: Payload
        do { payload = try decoder.decode(Payload.self, from: data) } catch { throw UpdateError.invalidResponse }
        guard payload.draft != true, let version = SemanticVersion(payload.tagName) else {
            throw UpdateError.invalidResponse
        }
        guard let zip = payload.assets.first(where: { isInstallableAsset($0.name) }) else {
            throw UpdateError.noInstallableAsset
        }
        let checksumAsset = payload.assets.first { $0.name == zip.name + ".sha256" }
        return ReleaseInfo(
            version: version,
            tag: payload.tagName,
            name: payload.name.flatMap { $0.isEmpty ? nil : $0 } ?? payload.tagName,
            notes: payload.body ?? "",
            pageURL: payload.htmlUrl,
            publishedAt: payload.publishedAt,
            zipURL: zip.browserDownloadUrl,
            zipName: zip.name,
            zipSize: zip.size ?? 0,
            sha256: parseDigest(zip.digest),
            checksumURL: checksumAsset?.browserDownloadUrl
        )
    }

    /// 解析 API 的 digest 字段(形如 sha256:abcd...)
    static func parseDigest(_ digest: String?) -> String? {
        guard let digest, digest.hasPrefix("sha256:") else { return nil }
        return normalizeHex(String(digest.dropFirst(7)))
    }

    /// 解析 shasum 输出("<hex>  <文件名>"),取第一个 64 位十六进制串
    static func parseChecksumFile(_ text: String) -> String? {
        for token in text.split(whereSeparator: { $0.isWhitespace }) {
            if let hex = normalizeHex(String(token)) { return hex }
        }
        return nil
    }

    private static func normalizeHex(_ text: String) -> String? {
        let lower = text.lowercased()
        guard lower.count == 64, lower.allSatisfy({ $0.isHexDigit }) else { return nil }
        return lower
    }
}
