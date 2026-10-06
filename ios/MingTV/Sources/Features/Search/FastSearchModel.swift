import Foundation
import MingTVCore
import Observation

struct SearchHit: Identifiable {
    let siteKey: String
    let siteName: String
    let vod: Vod
    var id: String { "\(siteKey)|\(vod.id)" }
}

/// 全源聚合搜索 (对应 Android: FastSearchActivity, 8 线程并发 + 增量回填)
@MainActor
@Observable
final class FastSearchModel {

    private(set) var hits: [SearchHit] = []
    private(set) var searching = false
    /// 搜索进度文案: 命中/已完成源数
    private(set) var progress = ""
    private(set) var error: String?

    /// nil = 全部来源
    var filterSiteKey: String?

    private var generation = 0

    var filteredHits: [SearchHit] {
        guard let key = filterSiteKey else { return hits }
        return hits.filter { $0.siteKey == key }
    }

    /// 出现在结果里的来源
    var sourceSites: [(key: String, name: String)] {
        var seen: [String: String] = [:]
        var order: [String] = []
        for h in hits where seen[h.siteKey] == nil {
            seen[h.siteKey] = h.siteName
            order.append(h.siteKey)
        }
        return order.compactMap { k in seen[k].map { (k, $0) } }
    }

    func search(keyword: String, sites: [Site], timeout: TimeInterval = 12) async {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty, !sites.isEmpty else { return }

        generation += 1
        let gen = generation
        hits = []
        searching = true
        error = nil
        filterSiteKey = nil
        progress = "搜索中 0/\(sites.count)"

        var done = 0
        await withTaskGroup(of: (Site, [Vod])?.self) { group in
            for site in sites {
                group.addTask {
                    let client = CmsClient(base: site.api, timeout: timeout)
                    let list = (try? await client.search(keyword: kw)) ?? []
                    return (site, list)
                }
            }
            for await result in group {
                guard gen == self.generation else { group.cancelAll(); return }
                done += 1
                if let (site, list) = result, !list.isEmpty {
                    let new = list.map { SearchHit(siteKey: site.key, siteName: site.name, vod: $0) }
                    // 增量回填: 每完成一个源就追加一批
                    self.hits.append(contentsOf: new)
                }
                self.progress = "搜索中 \(done)/\(sites.count)"
            }
        }

        guard gen == generation else { return }
        searching = false
        progress = hits.isEmpty ? "没有找到相关影片" : "共 \(hits.count) 条结果 · \(sites.count) 个来源"
    }

    func cancelSearch() {
        generation += 1
        searching = false
    }
}
