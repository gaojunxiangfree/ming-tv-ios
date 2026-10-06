import Foundation

// MARK: - 直播频道 / 分组 (对应 Android: bean/LiveChannel.java, LiveChannelGroup.java)

public struct LiveChannel: Sendable, Hashable, Identifiable {
    public var name: String
    /// 多个备用地址, 依次重试
    public var urls: [String]
    public var group: String
    public var logo: String?
    public var tvgID: String?
    public var httpUserAgent: String?
    /// 回看模板, 含 {date} / {time} 占位
    public var recTemplate: String?

    public var id: String { "\(group)|\(name)" }
    public var primaryURL: String { urls.first ?? "" }
    /// 是否支持时移回看
    public var supportsLookback: Bool { !(recTemplate ?? "").isEmpty }

    public init(name: String, urls: [String], group: String = "未分组",
                logo: String? = nil, tvgID: String? = nil,
                httpUserAgent: String? = nil, recTemplate: String? = nil) {
        self.name = name
        self.urls = urls
        self.group = group
        self.logo = logo
        self.tvgID = tvgID
        self.httpUserAgent = httpUserAgent
        self.recTemplate = recTemplate
    }
}

public struct LiveGroup: Sendable, Identifiable {
    public var name: String
    public var channels: [LiveChannel]
    public var id: String { name }

    public init(name: String, channels: [LiveChannel]) {
        self.name = name
        self.channels = channels
    }
}

// MARK: - m3u / txt 解析 (对应 Android: util/M3uParser.java)

public enum M3uParser {

    /// 解析结果
    public struct Result: Sendable {
        public var groups: [LiveGroup]
        public var epgURLs: [String]
        public var channels: [LiveChannel] { groups.flatMap(\.channels) }
    }

    /// 从网络拉取并解析直播源 (自动处理 .gz)
    public static func parseFromURL(_ urlString: String,
                                    userAgent: String? = nil,
                                    timeout: TimeInterval = 20) async throws -> Result {
        var headers: [String: String] = [:]
        if let ua = userAgent, !ua.isEmpty { headers["User-Agent"] = ua }
        let text = try await MingNet.getText(urlString, headers: headers, timeout: timeout)
        return parse(text: text, defaultGroup: "直播")
    }

    /// 解析 m3u (扩展属性) 或纯 txt (名称,地址)
    public static func parse(text: String, defaultGroup: String = "直播") -> Result {
        let lower = text.lowercased()
        if lower.contains("#extm3u") || lower.contains("#extinf") {
            return parseExtM3U(text, defaultGroup: defaultGroup)
        }
        return parsePlainText(text, defaultGroup: defaultGroup)
    }

    // MARK: m3u

    private static func parseExtM3U(_ text: String, defaultGroup: String) -> Result {
        var groups: [LiveGroup] = []
        var order: [String] = []
        var bucket: [String: [LiveChannel]] = [:]
        var epgURLs: [String] = []

        var pending: (name: String, attrs: [String: String])?
        var currentUA: String?

        func append(_ ch: LiveChannel) {
            let g = ch.group.isEmpty ? defaultGroup : ch.group
            if bucket[g] == nil { bucket[g] = []; order.append(g) }
            bucket[g]?.append(ch)
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            if line.hasPrefix("#EXTM3U") {
                // 解析 x-tvg-url / url-tvg
                let attrs = parseAttributes(line)
                for key in ["x-tvg-url", "url-tvg", "tvg-url"] {
                    if let v = attrs[key] ?? attrs[key.uppercased()] {
                        epgURLs.append(contentsOf: v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
                    }
                }
                continue
            }

            if line.hasPrefix("#EXTINF") {
                let attrs = parseAttributes(line)
                let comma = line.range(of: ",", options: .backwards)
                let name = comma.map { String(line[$0.upperBound...]).trimmingCharacters(in: .whitespaces) } ?? ""
                var merged = attrs
                if let ua = attrs["http-user-agent"] ?? attrs["user-agent"] { currentUA = ua; merged["http-user-agent"] = ua }
                pending = (name.isEmpty ? "未命名" : name, merged)
                continue
            }

            if line.hasPrefix("#") { continue }

            // 非 # 行 = 播放地址
            guard let p = pending else { continue }
            let group = p.attrs["group-title"] ?? p.attrs["group"] ?? defaultGroup
            let ch = LiveChannel(
                name: p.name,
                urls: [line],
                group: group,
                logo: p.attrs["tvg-logo"] ?? p.attrs["logo"],
                tvgID: p.attrs["tvg-id"] ?? p.attrs["tvg-name"],
                httpUserAgent: p.attrs["http-user-agent"] ?? currentUA ?? p.attrs["user-agent"],
                recTemplate: p.attrs["tvg-rec"] ?? p.attrs["catchup-source"]
            )
            append(ch)
            pending = nil
        }

        for g in order { groups.append(LiveGroup(name: g, channels: bucket[g] ?? [])) }
        return Result(groups: groups, epgURLs: dedupe(epgURLs))
    }

    /// 解析 `key="value"` 形式的属性
    static func parseAttributes(_ line: String) -> [String: String] {
        var out: [String: String] = [:]
        guard let re = try? NSRegularExpression(pattern: #"([A-Za-z0-9_-]+)="([^"]*)""#) else { return out }
        let ns = line as NSString
        for m in re.matches(in: line, range: NSRange(location: 0, length: ns.length)) where m.numberOfRanges == 3 {
            let k = ns.substring(with: m.range(at: 1)).lowercased()
            out[k] = ns.substring(with: m.range(at: 2))
        }
        return out
    }

    // MARK: txt

    private static func parsePlainText(_ text: String, defaultGroup: String) -> Result {
        var groups: [LiveGroup] = []
        var order: [String] = []
        var bucket: [String: [LiveChannel]] = [:]
        var current = defaultGroup

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }

            // #genre# 结尾 = 分组名
            if line.hasSuffix("#genre#") {
                current = line.replacingOccurrences(of: "#genre#", with: "").trimmingCharacters(in: .whitespaces)
                if current.isEmpty { current = defaultGroup }
                continue
            }

            let parts = line.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty, parts[1].hasPrefix("http") else { continue }
            let ch = LiveChannel(name: parts[0], urls: [parts[1]], group: current)
            if bucket[current] == nil { bucket[current] = []; order.append(current) }
            bucket[current]?.append(ch)
        }

        for g in order { groups.append(LiveGroup(name: g, channels: bucket[g] ?? [])) }
        return Result(groups: groups, epgURLs: [])
    }

    /// 同名频道合并备用地址 (m3u 多源时有用)
    private static func dedupe(_ arr: [String]) -> [String] {
        var seen = Set<String>()
        return arr.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

// MARK: - 内置兜底直播源 (对应 Android: ApiConfig.BUILTIN_LIVE_URLS)

public enum BuiltinLive {
    public static let urls: [String] = [
        "https://iptv-org.github.io/iptv/countries/cn.m3u",
        "https://raw.githubusercontent.com/YanG-1989/m3u/main/Gather.m3u",
    ]
    /// 兜底 EPG (对应 Android: EpgManager.DEFAULT_EPG_URLS)
    public static let epgURLs: [String] = [
        "https://epg.112114.xyz/pp.xml",
        "http://epg.112114.xyz/pp.xml",
    ]
}
