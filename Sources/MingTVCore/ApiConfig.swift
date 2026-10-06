import Foundation

// MARK: - 解析器声明 (对应 Android: bean/Parse.java)

public struct Parse: Codable, Sendable, Hashable {
    public var name: String?
    public var type: Int?
    public var url: String?
    public var ext: [String: String]?

    public init(name: String? = nil, type: Int? = nil, url: String? = nil, ext: [String: String]? = nil) {
        self.name = name
        self.type = type
        self.url = url
        self.ext = ext
    }
}

// MARK: - 直播源声明 (对应 Android: ApiConfig 中 lives[] 的解析)

public struct LiveSourceDecl: Codable, Sendable, Hashable {
    public var name: String?
    /// 0 = m3u / txt 直链直播源
    public var type: Int?
    public var url: String?
    public var ua: String?

    public init(name: String? = nil, type: Int? = nil, url: String? = nil, ua: String? = nil) {
        self.name = name
        self.type = type
        self.url = url
        self.ua = ua
    }
}

// MARK: - TVBox 单接口配置 (对应 Android: api/ApiConfig.java)

/// 解析 TVBox 单仓接口 JSON.
///
/// 刻意用 `JSONSerialization` 而非 `Codable`: TVBox 生态里同一字段类型极不统一
/// (如 `ext` 既可能是字符串也可能是对象, `searchable` 可能是 0/1 也可能是 true/false),
/// 强类型解码会整份配置失败. 弱类型解析 + 逐字段容错更贴近 Android 版行为.
public struct ApiConfig: Sendable {

    public var spider: String?
    public var wallpaper: String?
    public var logo: String?
    /// 全局请求头, 播放时并入防盗链头
    public var headers: [String: String]
    public var sites: [Site]
    public var parses: [Parse]
    public var lives: [LiveSourceDecl]

    public init(spider: String? = nil, wallpaper: String? = nil, logo: String? = nil,
                headers: [String: String] = [:], sites: [Site] = [],
                parses: [Parse] = [], lives: [LiveSourceDecl] = []) {
        self.spider = spider
        self.wallpaper = wallpaper
        self.logo = logo
        self.headers = headers
        self.sites = sites
        self.parses = parses
        self.lives = lives
    }

    /// iOS 原生可用的站点: 仅苹果CMS 采集源 (type 0/1).
    /// type 3/4 是 jar / drpy 爬虫, 依赖 DexClassLoader / QuickJS, iOS 无法运行, 直接过滤.
    public var nativeSites: [Site] { sites.filter { $0.isCMS } }

    // MARK: - 解析

    public static func parse(jsonText: String) throws -> ApiConfig {
        guard let data = jsonText.data(using: .utf8) else { throw CmsError.decode("配置非 UTF-8") }
        return try parse(json: data)
    }

    public static func parse(json data: Data) throws -> ApiConfig {
        let obj: Any
        do {
            obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw CmsError.decode("配置非合法 JSON: \(error.localizedDescription)")
        }
        guard let root = obj as? [String: Any] else {
            throw CmsError.decode("配置根节点不是对象")
        }

        var sites: [Site] = []
        for raw in (root["sites"] as? [[String: Any]]) ?? [] {
            // 过滤规则与 Android 一致: 显式 changeable==0 或 api 为空则跳过
            if let changeable = ApiConfig.int(raw["changeable"]), changeable == 0 { continue }
            let api = (ApiConfig.str(raw["api"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if api.isEmpty { continue }
            let name = ApiConfig.str(raw["name"]) ?? ""
            var key = ApiConfig.str(raw["key"]) ?? ""
            if key.isEmpty { key = name }
            guard !key.isEmpty else { continue }

            sites.append(Site(
                key: key,
                name: name.isEmpty ? key : name,
                type: ApiConfig.int(raw["type"]) ?? 0,
                api: api,
                searchable: ApiConfig.int(raw["searchable"]) ?? 1,
                quickSearch: ApiConfig.int(raw["quickSearch"]) ?? 1,
                filterable: ApiConfig.int(raw["filterable"]),
                ext: ApiConfig.extString(raw["ext"])
            ))
        }

        var parses: [Parse] = []
        for raw in (root["parses"] as? [[String: Any]]) ?? [] {
            parses.append(Parse(
                name: ApiConfig.str(raw["name"]),
                type: ApiConfig.int(raw["type"]),
                url: ApiConfig.str(raw["url"]),
                ext: raw["ext"] as? [String: String]
            ))
        }

        var lives: [LiveSourceDecl] = []
        for raw in (root["lives"] as? [[String: Any]]) ?? [] {
            let url = (ApiConfig.str(raw["url"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty else { continue }
            lives.append(LiveSourceDecl(
                name: ApiConfig.str(raw["name"]),
                type: ApiConfig.int(raw["type"]) ?? 0,
                url: url,
                ua: ApiConfig.str(raw["ua"])
            ))
        }

        var headers: [String: String] = [:]
        if let h = root["headers"] as? [String: Any] {
            for (k, v) in h { if let s = ApiConfig.str(v) { headers[k] = s } }
        }

        return ApiConfig(
            spider: ApiConfig.str(root["spider"]),
            wallpaper: ApiConfig.str(root["wallpaper"]),
            logo: ApiConfig.str(root["logo"]),
            headers: headers,
            sites: sites,
            parses: parses,
            lives: lives
        )
    }

    // MARK: - 弱类型取值

    private static func str(_ v: Any?) -> String? {
        switch v {
        case let s as String:  return s
        case let n as NSNumber: return n.stringValue
        case let b as Bool:    return b ? "1" : "0"
        case nil:              return nil
        default:               return nil
        }
    }

    private static func int(_ v: Any?) -> Int? {
        switch v {
        case let n as NSNumber: return n.intValue
        case let s as String:   return Int(s.trimmingCharacters(in: .whitespaces))
        case let b as Bool:     return b ? 1 : 0
        default:                return nil
        }
    }

    /// ext 可能是字符串或对象; 对象时序列化为紧凑 JSON 文本
    private static func extString(_ v: Any?) -> String? {
        switch v {
        case let s as String:
            return s
        case let dict as [String: Any]:
            guard let d = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
            return String(data: d, encoding: .utf8)
        case nil:
            return nil
        default:
            return str(v)
        }
    }
}

// MARK: - 配置加载 (含伪装为图片的 base64 反解)

public enum ConfigLoader {

    /// 拉取并解析接口配置. 若返回内容不是 JSON 而是一段长 base64, 尝试反解 (兼容接口伪装成图片的场景).
    public static func fetch(urlString: String, timeout: TimeInterval = 15) async throws -> ApiConfig {
        let (data, _) = try await MingNet.get(urlString, headers: ["User-Agent": MingNet.okhttpUA], timeout: timeout)

        if let cfg = try? ApiConfig.parse(json: data) { return cfg }

        // 反解 base64: 阈值 512 字符, 避免误伤正常 HTML
        if let text = String(data: data, encoding: .utf8),
           let decoded = extractBase64Config(from: text) {
            return try ApiConfig.parse(jsonText: decoded)
        }
        let preview = String(data: data.prefix(120), encoding: .utf8) ?? "<binary>"
        throw CmsError.decode("接口配置无法解析 | 原始: \(preview)")
    }

    /// 从文本中提取长度 > 512 的 base64 片段并解码
    static func extractBase64Config(from text: String) -> String? {
        let pattern = "[A-Za-z0-9+/]{512,}={0,2}"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let b64 = ns.substring(with: m.range)
            guard let d = Data(base64Encoded: b64),
                  let s = String(data: d, encoding: .utf8),
                  s.contains("\"sites\"") else { continue }
            return s
        }
        return nil
    }
}
