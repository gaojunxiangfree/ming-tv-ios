import AVFoundation
import Foundation

// MARK: - 播放资产构造 (方案 D: AVURLAssetHTTPHeaderFieldsKey)

/// 给 AVPlayer 注入请求头 (Referer / User-Agent / Cookie).
///
/// 依据 `Validate` 的实测结论: 苹果CMS 资源站的 m3u8 存在防盗链,
/// 三种方案里 **D 胜出** ——
///   A 裸请求       3/6 就绪
///   B 标准 https + resourceLoader.delegate  0 次回调, 该写法无效
///   C 自定义 scheme 中转                     0/6 就绪 (数据送达正确, 但 CoreMedia -12881, 不可用)
///   D AVURLAssetHTTPHeaderFieldsKey         4/6 就绪  ← 采用
///
/// 因此 iOS 版播放统一走 D, 不再实现 HeaderedAssetLoader 那套中转.
public enum PlaybackAsset {

    public static let headerFieldsKey = "AVURLAssetHTTPHeaderFieldsKey"

    public static func makeAsset(url: URL, headers: [String: String]) -> AVURLAsset {
        guard !headers.isEmpty else { return AVURLAsset(url: url) }
        return AVURLAsset(url: url, options: [headerFieldsKey: headers])
    }

    public static func makeItem(url: URL, headers: [String: String]) -> AVPlayerItem {
        AVPlayerItem(asset: makeAsset(url: url, headers: headers))
    }
}

// MARK: - 一次播放请求

public struct PlaybackRequest: Sendable, Hashable {
    public var url: String
    public var headers: [String: String]
    /// 用于展示的标题 (片名 / 频道名)
    public var title: String?
    /// 副标题 (集名)
    public var subtitle: String?

    public init(url: String, headers: [String: String] = [:], title: String? = nil, subtitle: String? = nil) {
        self.url = url
        self.headers = headers
        self.title = title
        self.subtitle = subtitle
    }
}

// MARK: - 播放地址解析 (对应 Android: PlayUrlResolver.java)

public enum PlayUrlResolver {

    /// 构造防盗链请求头: Referer 取自接口域名, 再并入接口的全局 headers
    public static func defaultHeaders(site: Site?, global: [String: String] = [:]) -> [String: String] {
        var h: [String: String] = ["User-Agent": CmsClient.defaultUA]
        if let site, let u = URL(string: site.api), let scheme = u.scheme, let host = u.host {
            h["Referer"] = "\(scheme)://\(host)/"
        }
        for (k, v) in global { h[k] = v }
        return h
    }

    /// 解析一个剧集地址为可直接播放的请求.
    /// - 直链 (m3u8/mp4/...) → 直接返回
    /// - 网页播放页 → 走 parses 解析链
    public static func resolve(episodeURL: String,
                               site: Site?,
                               config: ApiConfig?,
                               extraHeaders: [String: String] = [:]) async -> PlaybackRequest {
        var headers = defaultHeaders(site: site, global: config?.headers ?? [:])
        for (k, v) in extraHeaders { headers[k] = v }

        let raw = episodeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if StreamResolver.isDirectURL(raw) {
            return PlaybackRequest(url: raw, headers: headers)
        }

        // 非直链: 尝试 parses 解析链
        if let parses = config?.parses, !parses.isEmpty,
           let resolved = await parseChain(raw, parses: parses) {
            return PlaybackRequest(url: resolved, headers: headers)
        }

        // 兜底: 原样交给播放器 (部分源实际仍可直接播)
        return PlaybackRequest(url: raw, headers: headers)
    }

    /// 依次尝试 parses 链路, 从返回 JSON 中抽取可播放地址
    static func parseChain(_ raw: String, parses: [Parse]) async -> String? {
        for p in parses {
            guard let base = p.url, !base.isEmpty else { continue }
            let enc = raw.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? raw
            let target = base.contains("?") ? "\(base)\(enc)" : "\(base)?url=\(enc)"
            guard let text = try? await MingNet.getText(target, timeout: 12) else { continue }
            if let url = extractPlayableURL(from: text), StreamResolver.isDirectURL(url) {
                return url
            }
        }
        return nil
    }

    /// 从解析接口的 JSON 文本里找 url / playUrl / data.url 等字段
    static func extractPlayableURL(from text: String) -> String? {
        if let d = text.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: d) {
            if let s = findURL(in: obj) { return s }
        }
        // 兜底: 正则抓第一个 http(s) 直链
        if let re = try? NSRegularExpression(pattern: #"https?://[^\s"'\\]+"#) {
            let ns = text as NSString
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let candidate = ns.substring(with: m.range)
                if StreamResolver.isDirectURL(candidate) { return candidate }
            }
        }
        return nil
    }

    private static func findURL(in obj: Any) -> String? {
        if let s = obj as? String { return StreamResolver.isDirectURL(s) ? s : nil }
        if let dict = obj as? [String: Any] {
            // 优先常见字段
            for key in ["url", "playUrl", "playURL", "alyUrl", "src", "video"] {
                if let v = dict[key] as? String, StreamResolver.isDirectURL(v) { return v }
            }
            for (_, v) in dict {
                if let found = findURL(in: v) { return found }
            }
        }
        if let arr = obj as? [Any] {
            for v in arr { if let found = findURL(in: v) { return found } }
        }
        return nil
    }
}
