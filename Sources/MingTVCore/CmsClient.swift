import Foundation

public enum CmsError: Error, CustomStringConvertible {
    case badURL(String)
    case http(Int)
    case network(String)
    case decode(String)
    case empty

    public var description: String {
        switch self {
        case .badURL(let s):   return "URL 非法: \(s)"
        case .http(let c):     return "HTTP \(c)"
        case .network(let s):  return "网络失败: \(s)"
        case .decode(let s):   return "解析失败: \(s)"
        case .empty:           return "接口返回空数据"
        }
    }
}

/// 苹果CMS V10 采集接口客户端 (type 0/1), 对应 Android 版 api/CspApi.java.
/// 纯 HTTP + JSON, 无任何 Android 依赖 —— 这正是 iOS 版可原生复用的部分.
public struct CmsClient: Sendable {

    public let base: String
    public let userAgent: String
    private let session: URLSession

    public static let defaultUA =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    public init(base: String, userAgent: String = CmsClient.defaultUA, timeout: TimeInterval = 15) {
        var b = base.trimmingCharacters(in: .whitespacesAndNewlines)
        if !b.hasSuffix("/") { b += "/" }
        self.base = b
        self.userAgent = userAgent
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout
        cfg.httpAdditionalHeaders = ["User-Agent": userAgent]
        self.session = URLSession(configuration: cfg)
    }

    // MARK: - 请求

    private func fetch<T: Codable & Sendable>(_ path: String, as type: T.Type) async throws -> T {
        guard let url = URL(string: base + path) else { throw CmsError.badURL(base + path) }
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw CmsError.network(error.localizedDescription)
        }
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw CmsError.http(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            let preview = String(data: data.prefix(120), encoding: .utf8) ?? "<binary>"
            throw CmsError.decode("\(error.localizedDescription) | 原始: \(preview)")
        }
    }

    // MARK: - 接口

    /// 最新影片列表.
    /// 注意: 必须用 ac=videolist —— ac=list 返回的是精简字段(不含 vod_pic),
    /// 海报会全空. Android 版 CspApi.homeContent 已踩过这个坑.
    public func latest(page: Int = 1) async throws -> [Vod] {
        let r = try await fetch("?ac=videolist&pg=\(page)", as: CmsResponse<Vod>.self)
        guard let list = r.list, !list.isEmpty else { throw CmsError.empty }
        return list
    }

    /// 分类列表 + 该分类下影片
    public func category(tid: String, page: Int = 1) async throws -> (classes: [VodClass], list: [Vod]) {
        let r = try await fetch("?ac=videolist&t=\(tid)&pg=\(page)", as: CmsResponse<Vod>.self)
        return (r.classes ?? [], r.list ?? [])
    }

    /// 首页分类项
    public func classes() async throws -> [VodClass] {
        let r = try await fetch("?ac=list", as: CmsResponse<Vod>.self)
        return r.classes ?? []
    }

    /// 详情 (含 vod_play_from / vod_play_url)
    public func detail(ids: String) async throws -> Vod {
        let r = try await fetch("?ac=detail&ids=\(ids)", as: CmsResponse<Vod>.self)
        guard let v = r.list?.first else { throw CmsError.empty }
        return v
    }

    /// 搜索
    public func search(keyword: String, page: Int = 1) async throws -> [Vod] {
        let enc = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        let r = try await fetch("?ac=videolist&wd=\(enc)&pg=\(page)", as: CmsResponse<Vod>.self)
        return r.list ?? []
    }
}
