import Foundation

// MARK: - 宽松字符串解码
// 苹果CMS 各资源站同一字段的类型并不统一(如 vod_year 可能是 2026 也可能是 "2026"),
// 用 AnyString 统一吸收 String / Int / Double / Bool, 避免解码失败。

public struct AnyString: Codable, Sendable, Hashable, CustomStringConvertible {
    public let value: String?

    public init(_ s: String?) { self.value = s }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { value = nil; return }
        if let s = try? c.decode(String.self) { value = s; return }
        if let i = try? c.decode(Int.self) { value = String(i); return }
        if let d = try? c.decode(Double.self) { value = String(d); return }
        if let b = try? c.decode(Bool.self) { value = b ? "1" : "0"; return }
        value = nil
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        if let v = value { try c.encode(v) } else { try c.encodeNil() }
    }

    public var description: String { value ?? "" }
}

// MARK: - 站点源定义 (对应 Android: bean/Site.java)

public struct Site: Codable, Sendable, Hashable, Identifiable {
    public var key: String
    public var name: String
    /// 0=xml采集 1=json采集(苹果CMS) 3=jar爬虫 4=drpy js爬虫
    public var type: Int
    public var api: String
    public var searchable: Int?
    public var quickSearch: Int?
    public var filterable: Int?
    public var ext: String?

    public var id: String { key }

    public init(key: String, name: String, type: Int, api: String,
                searchable: Int? = 1, quickSearch: Int? = 1, filterable: Int? = nil, ext: String? = nil) {
        self.key = key
        self.name = name
        self.type = type
        self.api = api
        self.searchable = searchable
        self.quickSearch = quickSearch
        self.filterable = filterable
        self.ext = ext
    }

    /// 是否为爬虫站点(jar / js) —— iOS 无法运行
    public var isSpider: Bool { type == 3 || type == 4 }
    /// 是否为苹果CMS 采集站点 —— iOS 可原生支持
    public var isCMS: Bool { type == 0 || type == 1 }
}

// MARK: - 分类

public struct VodClass: Codable, Sendable, Hashable {
    public var type_id: AnyString?
    public var type_name: AnyString?
    public var type_pid: AnyString?

    public var id: String { type_id?.value ?? "" }
    public var name: String { type_name?.value ?? "" }
    public var parentID: String { type_pid?.value ?? "" }
}

// MARK: - 影片 (对应 Android: bean/Vod.java)

public struct Vod: Codable, Sendable {
    public var vod_id: AnyString?
    public var vod_name: AnyString?
    public var vod_pic: AnyString?
    public var vod_pic_thumb: AnyString?
    public var vod_remarks: AnyString?
    public var vod_year: AnyString?
    public var vod_area: AnyString?
    public var vod_lang: AnyString?
    public var vod_actor: AnyString?
    public var vod_director: AnyString?
    public var vod_content: AnyString?
    public var vod_blurb: AnyString?
    public var vod_play_from: AnyString?
    public var vod_play_url: AnyString?
    public var vod_time: AnyString?
    public var vod_score: AnyString?
    public var vod_tag: AnyString?
    public var type_name: AnyString?

    public var id: String { vod_id?.value ?? "" }
    public var name: String { vod_name?.value ?? "" }
    public var pic: String { vod_pic?.value ?? vod_pic_thumb?.value ?? "" }
    public var remarks: String { vod_remarks?.value ?? "" }
    public var year: String { vod_year?.value ?? "" }
    public var area: String { vod_area?.value ?? "" }
    public var actor: String { vod_actor?.value ?? "" }
    public var director: String { vod_director?.value ?? "" }
    public var content: String { vod_content?.value ?? vod_blurb?.value ?? "" }
    public var playFrom: String { vod_play_from?.value ?? "" }
    public var playURL: String { vod_play_url?.value ?? "" }
    public var typeName: String { type_name?.value ?? "" }
    /// 评分 (海报左下角黄色角标)
    public var score: String { (vod_score?.value ?? "").trimmingCharacters(in: .whitespaces) }
    /// 自定义标签 (海报左上角角标)
    public var tag: String { (vod_tag?.value ?? "").trimmingCharacters(in: .whitespaces) }

    /// 程序化构造 (网盘等场景没有接口数据, 需要手工造一个 Vod 交给播放页/历史记录)
    public init(vod_id: String?, vod_name: String?,
                vod_pic: String? = nil, vod_remarks: String? = nil) {
        self.vod_id = AnyString(vod_id)
        self.vod_name = AnyString(vod_name)
        self.vod_pic = AnyString(vod_pic)
        self.vod_remarks = AnyString(vod_remarks)
    }
}

// MARK: - 接口响应

public struct CmsResponse<T: Codable & Sendable>: Codable, Sendable {
    public var code: AnyString?
    public var msg: AnyString?
    public var page: AnyString?
    public var pagecount: AnyString?
    public var limit: AnyString?
    public var total: AnyString?
    public var list: [T]?
    public var classes: [VodClass]?

    enum CodingKeys: String, CodingKey {
        case code, msg, page, pagecount, limit, total, list
        case classes = "class"
    }
}

// MARK: - 播放线路 / 剧集

public struct Episode: Sendable, Hashable {
    public let title: String
    public let url: String

    public init(title: String, url: String) {
        self.title = title
        self.url = url
    }
}

public struct PlayLine: Sendable {
    /// 线路标识, 来自 vod_play_from, 如 ffm3u8 / zuidam3u8
    public let flag: String
    public let episodes: [Episode]

    public init(flag: String, episodes: [Episode]) {
        self.flag = flag
        self.episodes = episodes
    }

    /// 线路名是否暗示是 m3u8 直链线路 (苹果CMS 生态惯例: 以 m3u8 结尾的播放器标识为直链)
    public var flagSuggestsDirect: Bool {
        let f = flag.lowercased()
        return f.hasSuffix("m3u8") || f.hasSuffix("mp4") || f.contains("m3u8")
    }

    /// 该线路是否所有剧集都是可直接播放的直链
    public var isDirectPlayable: Bool {
        guard !episodes.isEmpty else { return false }
        return episodes.allSatisfy { StreamResolver.isDirectURL($0.url) }
    }
}
