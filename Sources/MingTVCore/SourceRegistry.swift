import Foundation

/// 已验证的苹果CMS 采集源清单 (type 1).
/// 这些是 2026-10 实测可连通的源; 采集站域名新陈代谢很快, 生产版必须保留
/// "多源管理 + 失效自动跳过" 能力, 不能写死.
public enum SourceRegistry {

    public static let verified: [Site] = [
        Site(key: "ffzy",   name: "非凡资源", type: 1, api: "http://cj.ffzyapi.com/api.php/provide/vod/"),
        Site(key: "lzi",    name: "量子资源", type: 1, api: "http://cj.lziapi.com/api.php/provide/vod/"),
        Site(key: "zuid",   name: "最大资源", type: 1, api: "https://api.zuidapi.com/api.php/provide/vod/"),
        Site(key: "sdzy",   name: "闪电资源", type: 1, api: "https://sdzyapi.com/api.php/provide/vod/"),
        Site(key: "gs",     name: "光速资源", type: 1, api: "https://api.guangsuapi.com/api.php/provide/vod/"),
        Site(key: "bfzy",   name: "暴风资源", type: 1, api: "https://bfzyapi.com/api.php/provide/vod/"),
        Site(key: "huya",   name: "虎牙资源", type: 1, api: "https://www.huyaapi.com/api.php/provide/vod/"),
        Site(key: "modu",   name: "魔都资源", type: 1, api: "https://www.mdzyapi.com/api.php/provide/vod/"),
        Site(key: "p2100",  name: "飘零资源", type: 1, api: "https://p2100.net/api.php/provide/vod/"),
        Site(key: "dytt",   name: "电影天堂", type: 1, api: "https://caiji.dyttzyapi.com/api.php/provide/vod/"),
        Site(key: "jy",     name: "金鹰资源", type: 1, api: "https://jyzyapi.com/api.php/provide/vod/"),
        Site(key: "xinlang",name: "新浪资源", type: 1, api: "https://api.xinlangapi.com/xinlangapi.php/provide/vod/"),
    ]

    public struct ProbeResult: Sendable {
        public let site: Site
        public let ok: Bool
        public let classes: Int
        public let videos: Int
        public let withPoster: Int
        public let note: String
    }

    /// 并发探测所有源
    public static func probeAll(_ sites: [Site] = verified, timeout: TimeInterval = 12) async -> [ProbeResult] {
        await withTaskGroup(of: ProbeResult.self) { group in
            for site in sites {
                group.addTask {
                    let client = CmsClient(base: site.api, timeout: timeout)
                    do {
                        let cls: [VodClass]
                        do { cls = try await client.classes() } catch { cls = [] }
                        let list = try await client.latest()
                        let withPic = list.filter { !$0.pic.isEmpty }.count
                        return ProbeResult(site: site, ok: true,
                                           classes: cls.count, videos: list.count,
                                           withPoster: withPic, note: "")
                    } catch {
                        return ProbeResult(site: site, ok: false, classes: 0, videos: 0,
                                           withPoster: 0, note: "\(error)")
                    }
                }
            }
            var out: [ProbeResult] = []
            for await r in group { out.append(r) }
            return out.sorted { $0.site.name < $1.site.name }
        }
    }
}

// MARK: - 防盗链原始探测

public enum HotlinkProbe {

    public struct Outcome: Sendable {
        public let status: Int
        public let contentType: String
        public let bytes: Int
        public let looksLikePlaylist: Bool
        public let note: String
    }

    /// 不带任何请求头直接拉 m3u8, 看是否被防盗链拦截
    public static func bare(_ url: String, timeout: TimeInterval = 15) async -> Outcome {
        await request(url, headers: nil, timeout: timeout)
    }

    /// 带 Referer / User-Agent 拉 m3u8
    public static func withHeaders(_ url: String, headers: [String: String], timeout: TimeInterval = 15) async -> Outcome {
        await request(url, headers: headers, timeout: timeout)
    }

    private static func request(_ urlString: String, headers: [String: String]?, timeout: TimeInterval) async -> Outcome {
        guard let url = URL(string: urlString) else {
            return Outcome(status: -1, contentType: "", bytes: 0, looksLikePlaylist: false, note: "URL 非法")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        // 注意: 裸请求只是"不带自定义请求头", 仍走 URLSession 默认 UA.
        // 若把 UA 显式设为空串, 多数 CDN 会直接判定为异常请求返回拦截页, 会造成防盗链误判.
        if let headers {
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let http = resp as? HTTPURLResponse
            let ct = (http?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            let isPlaylist = data.starts(with: Array("#EXTM3U".utf8))
            return Outcome(status: http?.statusCode ?? -1,
                           contentType: ct,
                           bytes: data.count,
                           looksLikePlaylist: isPlaylist,
                           note: "")
        } catch {
            return Outcome(status: -1, contentType: "", bytes: 0, looksLikePlaylist: false,
                           note: "\(error.localizedDescription)")
        }
    }
}
