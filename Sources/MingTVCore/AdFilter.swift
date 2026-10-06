import Foundation

/// m3u8 广告过滤 (对应 Android: ui/play/AdFilterDataSource.java)
///
/// 过滤规则与 Android 完全一致:
///   1. SCTE-35 广告区间标记 (#EXT-X-CUE-OUT / #EXT-X-CUE-IN) 之间的分片;
///   2. URI 含广告关键字的分片 (advert / _ad_ / /ad/ / -ad- / 广告), 连同其 #EXTINF 一起移除.
/// 只处理播放列表, 不碰 .ts/.m4s 分片, 保证正常内容不受影响.
public enum AdFilter {

    public static func isM3U8(_ url: String) -> Bool {
        let u = url.lowercased()
        let path = u.split(separator: "?", maxSplits: 1).first.map(String.init) ?? u
        return path.hasSuffix(".m3u8")
    }

    /// 保守匹配广告分片 URI, 避免误伤 load / shadow / download 等正常文件名
    public static func isAdURI(_ uri: String) -> Bool {
        let u = uri.lowercased()
        return u.contains("advert") || u.contains("_ad_") || u.contains("/ad/")
            || u.contains("-ad-") || u.contains("广告")
    }

    /// 多码率主列表 (含 #EXT-X-STREAM-INF)
    public static func isMasterPlaylist(_ text: String) -> Bool {
        text.contains("#EXT-X-STREAM-INF")
    }

    /// 过滤广告分片. removed = 0 表示无广告, 此时原样返回.
    public static func filter(_ text: String) -> (text: String, removed: Int) {
        let lines = text.components(separatedBy: .newlines)
        var out: [String] = []
        var inAd = false
        var removed = 0

        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#EXT-X-CUE-OUT") { inAd = true; removed += 1; continue }
            if t.hasPrefix("#EXT-X-CUE-IN")  { inAd = false; removed += 1; continue }
            if inAd { removed += 1; continue }

            if !t.hasPrefix("#"), isAdURI(t) {
                // 广告分片: 连同紧邻的 #EXTINF 一起移除
                if let last = out.last?.trimmingCharacters(in: .whitespaces), last.hasPrefix("#EXTINF") {
                    out.removeLast()
                }
                removed += 1
                continue
            }
            out.append(line)
        }

        guard removed > 0 else { return (text, 0) }
        return (out.joined(separator: "\n"), removed)
    }

    /// 把播放列表里的相对地址全部改成绝对地址.
    /// 改造后的列表会落到本地文件播放, 此时相对路径已无基准, 必须绝对化.
    public static func absolutize(_ text: String, base: URL) -> String {
        text.components(separatedBy: .newlines).map { line -> String in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return line }
            if t.hasPrefix("#") { return rewriteURIAttributes(in: line, base: base) }
            guard let abs = URL(string: t, relativeTo: base)?.absoluteURL else { return line }
            return abs.absoluteString
        }
        .joined(separator: "\n")
    }

    /// 改写 #EXT-X-KEY / #EXT-X-MAP / #EXT-X-MEDIA 里的 URI="..."
    private static func rewriteURIAttributes(in line: String, base: URL) -> String {
        guard line.contains("URI="),
              let re = try? NSRegularExpression(pattern: #"URI="([^"]+)""#) else { return line }
        let matches = re.matches(in: line, range: NSRange(line.startIndex..., in: line))
        guard !matches.isEmpty else { return line }

        var result = line
        for m in matches.reversed() {
            guard let r = Range(m.range(at: 1), in: line),
                  let full = Range(m.range(at: 0), in: result) else { continue }
            let uri = String(line[r])
            guard let abs = URL(string: uri, relativeTo: base)?.absoluteURL else { continue }
            result.replaceSubrange(full, with: "URI=\"\(abs.absoluteString)\"")
        }
        return result
    }
}

// MARK: - 播放列表拉取 / 广告探测

public extension AdFilter {

    /// 拉取播放列表文本. 返回最终地址作为相对路径基准(可能发生重定向).
    static func fetchPlaylist(_ url: URL,
                              headers: [String: String],
                              timeout: TimeInterval = 15) async -> (text: String, base: URL)? {
        guard let (data, http) = try? await MingNet.get(url.absoluteString,
                                                        headers: headers, timeout: timeout),
              let text = String(data: data, encoding: .utf8),
              text.contains("#EXTM3U") else { return nil }
        return (text, http.url ?? url)
    }

    /// 探测该播放列表需要过滤多少行广告.
    /// 返回 nil 表示不需要/无法处理(非 m3u8、多码率主列表、拉取失败).
    static func probe(_ url: URL, headers: [String: String]) async -> Int? {
        guard isM3U8(url.absoluteString) else { return nil }
        guard let (text, _) = await fetchPlaylist(url, headers: headers) else { return nil }
        // 多码率主列表不改写: 展平会牺牲自适应码率, 且变体列表之后无法再被拦截
        guard !isMasterPlaylist(text) else { return nil }
        return filter(text).removed
    }
}
