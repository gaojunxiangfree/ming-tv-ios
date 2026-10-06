import Foundation
import MingTVCore
import Observation

/// 首页数据 (对应 Android: HomeActivity + loadHome/loadCategory/loadMore)
///
/// `@MainActor`: 每个海报格都挂了一个 `.task` 调 `loadMoreIfNeeded`,
/// 多个异步续体会并发进入这里改 `items` 数组 —— 不做 actor 隔离会触发
/// `_swift_release_dealloc` 段错误(实测崩溃)。钉在主 actor 上串行化。
@MainActor
@Observable
final class HomeModel {

    struct Tab: Identifiable, Hashable {
        let tid: String
        let name: String
        /// 空 tid = "主页" 推荐位
        var isHome: Bool { tid.isEmpty }
        var id: String { isHome ? "__home__" : tid }
    }

    private(set) var tabs: [Tab] = []
    private(set) var items: [Vod] = []
    var selectedTabID = "__home__"
    private(set) var loading = false
    private(set) var loadingMore = false
    private(set) var error: String?

    private var page = 1
    private var pageCount = 1
    private var loadedSiteKey = ""

    /// 首次进入或切换站点时装载
    func load(site: Site, force: Bool = false) async {
        if !force, loadedSiteKey == site.key, !items.isEmpty { return }
        loadedSiteKey = site.key
        loading = true
        error = nil
        tabs = []
        items = []
        page = 1
        pageCount = 1
        defer { loading = false }

        let client = CmsClient(base: site.api)
        let classes: [VodClass]
        do {
            classes = try await client.classes()
        } catch {
            classes = []
        }

        // Android 逻辑: 有推荐位时插入"主页" Tab, 这里始终保留"主页"(= 最新片库)
        var built: [Tab] = [Tab(tid: "", name: "主页")]
        built.append(contentsOf: classes.compactMap { c in
            c.id.isEmpty ? nil : Tab(tid: c.id, name: c.name.isEmpty ? c.id : c.name)
        })
        tabs = built
        selectedTabID = built.first?.id ?? "__home__"

        await loadTab(tid: "", page: 1, append: false, site: site)
    }

    func selectTab(_ id: String, site: Site) async {
        guard id != selectedTabID || items.isEmpty else { return }
        selectedTabID = id
        let tid = tabs.first { $0.id == id }?.tid ?? ""
        items = []
        page = 1
        pageCount = 1
        await loadTab(tid: tid, page: 1, append: false, site: site)
    }

    /// 滚动到接近底部时翻页
    func loadMoreIfNeeded(current vod: Vod, site: Site) async {
        guard !loading, !loadingMore, page < pageCount else { return }
        guard let idx = items.firstIndex(where: { $0.id == vod.id }),
              idx >= items.count - 5 else { return }
        let tid = tabs.first { $0.id == selectedTabID }?.tid ?? ""
        loadingMore = true
        await loadTab(tid: tid, page: page + 1, append: true, site: site)
        loadingMore = false
    }

    private func loadTab(tid: String, page: Int, append: Bool, site: Site) async {
        let client = CmsClient(base: site.api)
        do {
            let list: [Vod]
            if tid.isEmpty {
                list = try await client.latest(page: page)
            } else {
                let (_, l) = try await client.category(tid: tid, page: page)
                list = l
            }
            if append {
                items.append(contentsOf: list)
            } else {
                items = list
            }
            self.page = page
            // 苹果CMS 分页信息在响应里; 简化策略: 返回满页即认为还有下一页
            pageCount = list.count >= 20 ? max(pageCount, page + 1) : page
            error = list.isEmpty && !append ? "该分类暂无内容" : nil
        } catch {
            if !append { items = [] }
            self.error = "\(error)"
        }
    }
}
