//
//  QuoteProvider.swift
//  StockMenuBar
//
//  行情数据源抽象:统一协议、错误类型与 HTTP 客户端。
//  @author ixxxxoooo
//

import Foundation

/// 数据源标识
enum ProviderID: String, Sendable, CaseIterable, Hashable {
    case tencent, sina, eastmoney, yahoo

    var displayName: String {
        switch self {
        case .tencent: return "腾讯"
        case .sina: return "新浪"
        case .eastmoney: return "东财"
        case .yahoo: return "雅虎"
        }
    }
}

/// 数据源能力
enum ProviderCapability: Sendable, Hashable {
    case quotes, minute, search
    /// 期货/全球指数的实时行情、分时、搜索
    case futuresQuotes, futuresMinute, futuresSearch
}

/// 数据源错误
enum ProviderError: Error, Sendable, LocalizedError {
    case httpStatus(Int)
    case emptyResponse
    case invalidData(String)
    case unsupported
    case allSourcesFailed(String)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code): return "HTTP 状态异常: \(code)"
        case .emptyResponse: return "响应为空"
        case .invalidData(let reason): return "数据无效: \(reason)"
        case .unsupported: return "数据源不支持该能力"
        case .allSourcesFailed(let reason): return "所有数据源均不可用: \(reason)"
        }
    }
}

/// HTTP 客户端抽象,便于单元测试注入
protocol HTTPClient: Sendable {
    /// 发送请求并返回响应体
    /// - Parameter request: 请求
    func send(_ request: URLRequest) async throws -> Data
}

/// 基于 URLSession 的实现:短超时、无缓存、无持久化 Cookie
struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    /// - Parameter timeout: 单次请求超时(秒),默认 3 秒
    init(timeout: TimeInterval = 3) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpMaximumConnectionsPerHost = 4
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            "Accept": "*/*"
        ]
        session = URLSession(configuration: config)
    }

    func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ProviderError.httpStatus(http.statusCode)
        }
        guard !data.isEmpty else { throw ProviderError.emptyResponse }
        return data
    }
}

/// 行情数据源协议
protocol QuoteProvider: Sendable {
    var id: ProviderID { get }
    var capabilities: Set<ProviderCapability> { get }

    /// 是否能服务某个具体标的(默认只看能力集)。
    /// 例如新浪只有国内期货分时、东财才有全部外盘,路由据此在发请求前过滤,避免无意义的失败计数污染熔断统计。
    func canServe(_ capability: ProviderCapability, symbol: StockSymbol?) -> Bool

    /// 批量获取实时行情
    func fetchQuotes(_ symbols: [StockSymbol]) async throws -> [Quote]
    /// 获取当日分时
    func fetchMinute(symbol: StockSymbol) async throws -> MinuteSeries
    /// 搜索联想
    func search(keyword: String) async throws -> [SearchResult]
    /// 搜索期货与全球指数
    func searchFutures(keyword: String) async throws -> [SearchResult]
}

extension QuoteProvider {
    func canServe(_ capability: ProviderCapability, symbol: StockSymbol?) -> Bool {
        capabilities.contains(capability)
    }
    func fetchMinute(symbol: StockSymbol) async throws -> MinuteSeries { throw ProviderError.unsupported }
    func search(keyword: String) async throws -> [SearchResult] { throw ProviderError.unsupported }
    func searchFutures(keyword: String) async throws -> [SearchResult] { throw ProviderError.unsupported }
}

/// 解析辅助
enum ParseUtil {
    /// 将 Any 转为 Double,兼容数字与字符串(东财停牌时为 "-")
    static func double(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String, let d = Double(s) { return d }
        return nil
    }

    /// 将数组切成固定大小的块
    static func chunked<T>(_ array: [T], size: Int) -> [[T]] {
        guard size > 0 else { return [array] }
        return stride(from: 0, to: array.count, by: size).map { Array(array[$0..<min($0 + size, array.count)]) }
    }

    /// 对关键字做 URL 查询参数编码
    static func encodeQuery(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+#"))) ?? text
    }
}
