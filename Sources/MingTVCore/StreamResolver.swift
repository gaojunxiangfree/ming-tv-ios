import Foundation

/// 播放线路解析与优选.
/// 苹果CMS 的 vod_play_from / vod_play_url 约定:
///   - 多条线路之间用 `$$$` 分隔, 与 vod_play_from 的 `$$$` 一一对应
///   - 同一线路内多集之间用 `#` 分隔
///   - 每集形如 `第01集$https://..../index.m3u8`
public enum StreamResolver {

    /// 可直接交给播放器的媒体扩展名
    private static let directExts: Set<String> = [
        "m3u8", "mp4", "ts", "flv", "mkv", "avi", "mov", "webm", "mp3", "m4a",
    ]

    /// 判断 URL 是否已是可直接播放的直链
    public static func isDirectURL(_ url: String) -> Bool {
        let s = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard s.hasPrefix("http://") || s.hasPrefix("https://") else { return false }
        // 去掉 query 后看扩展名
        let path = s.split(separator: "?", maxSplits: 1).first.map(String.init) ?? s
        guard let ext = path.split(separator: ".").last.map(String.init), path.contains(".") else {
            return false
        }
        return directExts.contains(ext)
    }

    /// 拆分线路
    public static func parseLines(from vod: Vod) -> [PlayLine] {
        let flags = vod.playFrom.components(separatedBy: "$$$").map { $0.trimmingCharacters(in: .whitespaces) }
        let groups = vod.playURL.components(separatedBy: "$$$")

        var lines: [PlayLine] = []
        for (i, group) in groups.enumerated() {
            let flag = i < flags.count ? flags[i] : "line\(i + 1)"
            var episodes: [Episode] = []
            for item in group.components(separatedBy: "#") {
                let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                if let sep = trimmed.firstIndex(of: "$") {
                    let title = String(trimmed[trimmed.startIndex..<sep])
                    let url = String(trimmed[trimmed.index(after: sep)...])
                    episodes.append(Episode(title: title, url: url))
                } else {
                    episodes.append(Episode(title: "正片", url: trimmed))
                }
            }
            guard !episodes.isEmpty else { continue }
            lines.append(PlayLine(flag: flag, episodes: episodes))
        }
        return lines
    }

    /// 线路优选: 优先挑"标识暗示直链"且"确实是直链"的线路.
    /// 这样能绕开需要二次解析的网页播放页线路, 省掉整条 parses 解析链路的移植成本.
    public static func rank(_ lines: [PlayLine]) -> [PlayLine] {
        lines.sorted { a, b in
            score(a) > score(b)
        }
    }

    private static func score(_ line: PlayLine) -> Int {
        var s = 0
        if line.isDirectPlayable { s += 100 }
        if line.flagSuggestsDirect { s += 50 }
        // 有 m3u8 的集数越多越稳
        let m3u8Count = line.episodes.filter { $0.url.lowercased().contains(".m3u8") }.count
        s += min(m3u8Count, 20)
        return s
    }

    public static func best(_ lines: [PlayLine]) -> PlayLine? {
        rank(lines).first
    }
}
