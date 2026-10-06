import Foundation
import MingTVCore
import Observation

/// 详情页数据 (对应 Android: DetailActivity)
@MainActor
@Observable
final class DetailModel {

    private(set) var vod: Vod?
    private(set) var lines: [PlayLine] = []
    var selectedLineIndex = 0
    var reversed = false
    var contentExpanded = false
    private(set) var loading = false
    private(set) var error: String?

    /// 选集按 30 个一页收纳 (对应 Android EPISODE_RANGE_SIZE)
    static let rangeSize = 30
    var rangeIndex = 0

    var currentLine: PlayLine? {
        guard lines.indices.contains(selectedLineIndex) else { return nil }
        return lines[selectedLineIndex]
    }

    var episodes: [Episode] {
        guard let eps = currentLine?.episodes else { return [] }
        return reversed ? eps.reversed() : eps
    }

    var rangeCount: Int {
        max(1, Int(ceil(Double(episodes.count) / Double(Self.rangeSize))))
    }

    var pagedEpisodes: [Episode] {
        let all = episodes
        guard all.count > Self.rangeSize else { return all }
        let start = rangeIndex * Self.rangeSize
        guard start < all.count else { return [] }
        return Array(all[start..<min(all.count, start + Self.rangeSize)])
    }

    func load(ref: VodRef, site: Site, preferredFlag: String? = nil) async {
        loading = true
        error = nil
        defer { loading = false }
        let client = CmsClient(base: site.api)
        do {
            let d = try await client.detail(ids: ref.vodId)
            vod = d
            let parsed = StreamResolver.parseLines(from: d)
            lines = StreamResolver.rank(parsed)   // 直链线路优先
            if let flag = preferredFlag,
               let idx = lines.firstIndex(where: { $0.flag == flag }) {
                selectedLineIndex = idx
            } else {
                selectedLineIndex = 0
            }
            rangeIndex = 0
        } catch {
            self.error = "\(error)"
        }
    }

    func selectLine(_ index: Int) {
        guard lines.indices.contains(index) else { return }
        selectedLineIndex = index
        rangeIndex = 0
    }

    /// 站点不存在等前置错误
    func fail(_ message: String) {
        loading = false
        error = message
    }
}
