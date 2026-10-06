import Foundation

// MARK: - EPG 节目单 (对应 Android: bean/EpgProgram.java + util/EpgManager.java)

public struct EpgProgram: Sendable, Hashable {
    public let channel: String
    public let title: String
    public let start: Date
    public let end: Date

    public init(channel: String, title: String, start: Date, end: Date) {
        self.channel = channel
        self.title = title
        self.start = start
        self.end = end
    }

    public func isPlaying(at now: Date) -> Bool { now >= start && now < end }
    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// EPG 拉取与解析 (XMLTV). 支持 .xml 与 .xml.gz.
public enum EpgClient {

    /// 拉取并解析多个 EPG 地址, 合并结果
    public static func load(urls: [String], timeout: TimeInterval = 25) async -> [String: [EpgProgram]] {
        var merged: [String: [EpgProgram]] = [:]
        for url in urls {
            do {
                let text = try await MingNet.getText(url, timeout: timeout)
                let programs = parse(text: text)
                for (ch, list) in programs {
                    merged[ch, default: []].append(contentsOf: list)
                }
            } catch {
                continue   // 单个 EPG 源失败不影响其它
            }
        }
        for k in merged.keys {
            merged[k]?.sort { $0.start < $1.start }
        }
        return merged
    }

    /// 解析 XMLTV 文本
    public static func parse(text: String) -> [String: [EpgProgram]] {
        guard let data = text.data(using: .utf8) else { return [:] }
        let parser = XMLParser(data: data)
        let delegate = EpgXMLDelegate()
        parser.delegate = delegate
        parser.parse()
        return delegate.result
    }

    // MARK: - 频道名归一化 (CCTV1 与 CCTV1综合 视为同一频道)

    public static func normalize(_ name: String) -> String {
        let lowered = name.lowercased()
        let filtered = lowered.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        return String(String.UnicodeScalarView(filtered))
    }

    /// 在 EPG 表中按频道名模糊查找 (精确 → 归一化 → 前缀包含)
    public static func lookup(_ table: [String: [EpgProgram]], channelName: String, tvgID: String?) -> [EpgProgram] {
        if let id = tvgID, let hit = table[id], !hit.isEmpty { return hit }
        if let hit = table[channelName], !hit.isEmpty { return hit }

        let target = normalize(channelName)
        guard !target.isEmpty else { return [] }
        var best: [EpgProgram] = []
        for (k, v) in table {
            let nk = normalize(k)
            if nk == target { return v }
            if best.isEmpty, nk.hasPrefix(target) || target.hasPrefix(nk) { best = v }
        }
        return best
    }

    /// 当前正在播出的节目
    public static func current(_ programs: [EpgProgram], at now: Date = Date()) -> EpgProgram? {
        programs.first { $0.isPlaying(at: now) }
    }

    /// 下一档节目
    public static func next(_ programs: [EpgProgram], at now: Date = Date()) -> EpgProgram? {
        programs.first { $0.start > now }
    }
}

// MARK: - XMLParser 委托

private final class EpgXMLDelegate: NSObject, XMLParserDelegate {
    var result: [String: [EpgProgram]] = [:]

    private var currentChannel: String?
    private var currentTitle: String?
    private var currentStart: Date?
    private var currentEnd: Date?
    private var inProgramme = false
    private var inTitle = false

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyyMMddHHmmss Z"
        return f
    }()

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        switch elementName {
        case "programme":
            inProgramme = true
            currentChannel = attributeDict["channel"]
            currentStart = Self.parseDate(attributeDict["start"])
            currentEnd = Self.parseDate(attributeDict["stop"])
            currentTitle = nil
        case "title":
            if inProgramme { inTitle = true }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inTitle, currentTitle == nil { currentTitle = string } else if inTitle { currentTitle? += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "title":
            inTitle = false
        case "programme":
            if let ch = currentChannel, let s = currentStart {
                let e = currentEnd ?? s.addingTimeInterval(1800)
                let p = EpgProgram(channel: ch,
                                   title: (currentTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                                   start: s, end: e)
                result[ch, default: []].append(p)
            }
            inProgramme = false
            currentChannel = nil; currentTitle = nil; currentStart = nil; currentEnd = nil
        default:
            break
        }
    }

    /// XMLTV 时间形如 `20261006120000 +0800`
    private static func parseDate(_ s: String?) -> Date? {
        guard let s, s.count >= 14 else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if let d = dateFormatter.date(from: trimmed) { return d }
        // 容错: 只取前 14 位按本地时区解析
        let head = String(trimmed.prefix(14))
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMddHHmmss"
        f.timeZone = TimeZone.current
        return f.date(from: head)
    }
}
