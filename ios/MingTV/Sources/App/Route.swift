import Foundation
import MingTVCore

/// 详情页入参快照 (vod 对象本身无法直接作为导航值)
struct VodRef: Hashable {
    let siteKey: String
    let vodId: String
    let name: String
    let pic: String
}

/// 全局路由
enum Route: Hashable {
    case detail(VodRef)
    case search
    case live
    case history
    case collect
    case drive
    case settings
}

/// 播放请求 (通过 fullScreenCover 呈现)
struct PlayTarget: Identifiable, Hashable {
    let id = UUID()
    /// 站点 key (历史/收藏写回用)
    let siteKey: String
    let vod: Vod
    let line: PlayLine
    let startIndex: Int
    /// 续播位置(秒)
    var startPosition: Double = 0
    /// 额外播放请求头 —— 网盘 (WebDAV Basic / AList) 走这里注入
    var extraHeaders: [String: String] = [:]

    static func == (lhs: PlayTarget, rhs: PlayTarget) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
