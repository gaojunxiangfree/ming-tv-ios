import Foundation
import MingTVCore
import Observation

/// 全局状态: 接口源、站点、收藏、历史、偏好设置.
@Observable
final class AppModel {

    // MARK: 接口源

    private(set) var config: ApiConfig?
    private(set) var sites: [Site] = []
    private(set) var apiURL: String
    private(set) var apiSources: [String]
    /// 首页/详情当前使用的站点
    var currentSiteKey: String

    private(set) var configLoading = false
    private(set) var configError: String?
    /// 启动流程是否已跑完 (站点表已就绪).
    /// 关掉开机页时首页会先于 `bootstrap()` 出现, 需要据此判断能否取站点。
    private(set) var bootstrapped = false

    // MARK: 收藏 / 历史 / 搜索历史

    private(set) var favorites: [FavoriteItem] = []
    private(set) var history: [HistoryItem] = []
    private(set) var searchHistory: [String] = []

    // MARK: 设置

    var playSpeed: Double {
        didSet { Persistence.set(PrefKey.playSpeed, playSpeed) }
    }
    var loopEnabled: Bool {
        didSet { Persistence.set(PrefKey.loopEnabled, loopEnabled) }
    }
    /// m3u8 去广告 (对应 Android AdFilterDataSource, 默认开启)
    var adFilterEnabled: Bool {
        didSet { Persistence.set(PrefKey.adFilter, adFilterEnabled) }
    }
    /// grid / column
    var playlistLayout: String {
        didSet { Persistence.set(PrefKey.playlistLayout, playlistLayout) }
    }
    /// 开机页总开关 (默认开启; 关闭后冷启动直接进首页)
    var splashEnabled: Bool {
        didSet { Persistence.set(PrefKey.splashEnabled, splashEnabled) }
    }
    var splashPoemOn: Bool {
        didSet { Persistence.set(PrefKey.splashPoemOn, splashPoemOn) }
    }
    var splashPoem: String {
        didSet { Persistence.set(PrefKey.splashPoem, splashPoem) }
    }

    // MARK: - 初始化

    init() {
        apiURL = Persistence.string(PrefKey.apiURL)
        apiSources = Persistence.strings(PrefKey.apiSources)
        currentSiteKey = Persistence.string(PrefKey.homeSite)
        playSpeed = Persistence.double(PrefKey.playSpeed, default: 1.0)
        loopEnabled = Persistence.bool(PrefKey.loopEnabled, default: false)
        adFilterEnabled = Persistence.bool(PrefKey.adFilter, default: true)
        playlistLayout = Persistence.string(PrefKey.playlistLayout, default: "grid")
        splashEnabled = Persistence.bool(PrefKey.splashEnabled, default: true)
        splashPoemOn = Persistence.bool(PrefKey.splashPoemOn, default: true)
        splashPoem = Persistence.string(PrefKey.splashPoem, default: Self.defaultPoem)
    }

    /// 立即装载本地数据 (收藏/历史/搜索历史) —— 不依赖网络
    func loadLocal() {
        favorites = Persistence.loadFavorites()
        history = Persistence.loadHistory()
        searchHistory = Persistence.strings(PrefKey.searchHistory)
    }

    /// 启动流程: 优先已保存接口源, 失败回退内置已验证 CMS 源
    func bootstrap() async {
        defer { bootstrapped = true }
        loadLocal()
        if !apiURL.isEmpty {
            await loadConfig(from: apiURL)
            if config != nil { return }
        }
        // 回退: 内置已验证苹果CMS 源, 保证开箱可用
        applyFallbackSources()
    }

    private func applyFallbackSources() {
        let fallback = ApiConfig(sites: SourceRegistry.verified)
        config = fallback
        sites = fallback.nativeSites
        if currentSiteKey.isEmpty || !sites.contains(where: { $0.key == currentSiteKey }) {
            currentSiteKey = sites.first?.key ?? ""
            Persistence.set(PrefKey.homeSite, currentSiteKey)
        }
        configError = nil
    }

    // MARK: - 接口配置

    @discardableResult
    func loadConfig(from url: String) async -> Bool {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        configLoading = true
        configError = nil
        defer { configLoading = false }

        do {
            let cfg = try await ConfigLoader.fetch(urlString: trimmed)
            let native = cfg.nativeSites
            guard !native.isEmpty else {
                configError = "该接口没有可在 iOS 上运行的苹果CMS 源 (仅 jar/drpy 爬虫源)"
                return false
            }
            config = cfg
            sites = native
            apiURL = trimmed
            Persistence.set(PrefKey.apiURL, trimmed)
            if !apiSources.contains(trimmed) {
                apiSources.insert(trimmed, at: 0)
                Persistence.set(PrefKey.apiSources, apiSources)
            }
            if currentSiteKey.isEmpty || !sites.contains(where: { $0.key == currentSiteKey }) {
                currentSiteKey = sites.first?.key ?? ""
                Persistence.set(PrefKey.homeSite, currentSiteKey)
            }
            return true
        } catch {
            configError = "\(error)"
            return false
        }
    }

    var currentSite: Site? { sites.first { $0.key == currentSiteKey } }

    func site(for key: String) -> Site? { sites.first { $0.key == key } }

    func selectSite(_ key: String) {
        currentSiteKey = key
        Persistence.set(PrefKey.homeSite, key)
    }

    func addAPISource(_ url: String) {
        let t = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !apiSources.contains(t) else { return }
        apiSources.insert(t, at: 0)
        Persistence.set(PrefKey.apiSources, apiSources)
    }

    func removeAPISource(_ url: String) {
        apiSources.removeAll { $0 == url }
        Persistence.set(PrefKey.apiSources, apiSources)
    }

    // MARK: - 收藏

    func isFavorite(vodId: String, siteKey: String) -> Bool {
        let id = "\(siteKey)|\(vodId)"
        return favorites.contains { $0.id == id }
    }

    func toggleFavorite(vod: Vod, siteKey: String) {
        let id = "\(siteKey)|\(vod.id)"
        if let idx = favorites.firstIndex(where: { $0.id == id }) {
            favorites.remove(at: idx)
        } else {
            favorites.insert(FavoriteItem(siteKey: siteKey,
                                          vodId: vod.id,
                                          vodName: vod.name,
                                          vodPic: vod.pic,
                                          vodRemarks: vod.remarks,
                                          createTime: Date().timeIntervalSince1970), at: 0)
        }
        Persistence.saveFavorites(favorites)
    }

    func removeFavorite(_ item: FavoriteItem) {
        favorites.removeAll { $0.id == item.id }
        Persistence.saveFavorites(favorites)
    }

    func clearFavorites() {
        favorites.removeAll()
        Persistence.saveFavorites(favorites)
    }

    // MARK: - 历史

    /// 写入观看历史 (主键冲突即覆盖, 与 Android Room REPLACE 语义一致)
    func recordHistory(siteKey: String, vod: Vod, flag: String,
                       episodeIndex: Int, episodeName: String,
                       position: Double, duration: Double) {
        let id = "\(siteKey)|\(vod.id)"
        let record = HistoryItem(siteKey: siteKey,
                                 vodId: vod.id,
                                 vodName: vod.name,
                                 vodPic: vod.pic,
                                 flag: flag,
                                 episodeIndex: episodeIndex,
                                 episodeName: episodeName,
                                 position: position,
                                 duration: duration,
                                 updateTime: Date().timeIntervalSince1970)
        history.removeAll { $0.id == id }
        history.insert(record, at: 0)
        if history.count > 200 { history = Array(history.prefix(200)) }
        Persistence.saveHistory(history)
    }

    func historyRecord(vodId: String, siteKey: String) -> HistoryItem? {
        let id = "\(siteKey)|\(vodId)"
        return history.first { $0.id == id }
    }

    func removeHistory(_ item: HistoryItem) {
        history.removeAll { $0.id == item.id }
        Persistence.saveHistory(history)
    }

    func clearHistory() {
        history.removeAll()
        Persistence.saveHistory(history)
    }

    // MARK: - 搜索历史 (去重、最新在前、上限 20 条, 与 Android SearchActivity.MAX_HISTORY 一致)

    static let maxSearchHistory = 20

    func addSearchKeyword(_ keyword: String) {
        let k = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        searchHistory.removeAll { $0 == k }
        searchHistory.insert(k, at: 0)
        if searchHistory.count > Self.maxSearchHistory {
            searchHistory = Array(searchHistory.prefix(Self.maxSearchHistory))
        }
        Persistence.set(PrefKey.searchHistory, searchHistory)
    }

    func clearSearchHistory() {
        searchHistory.removeAll()
        Persistence.set(PrefKey.searchHistory, searchHistory)
    }

    // MARK: - 片头/片尾跳过

    func introSeconds(vodId: String, flag: String, index: Int) -> Int {
        Persistence.int(PrefKey.introKey(vodId: vodId, flag: flag, index: index), default: 0)
    }
    func setIntroSeconds(_ v: Int, vodId: String, flag: String, index: Int) {
        Persistence.set(PrefKey.introKey(vodId: vodId, flag: flag, index: index), v)
    }
    func outroSeconds(vodId: String, flag: String, index: Int) -> Int {
        Persistence.int(PrefKey.outroKey(vodId: vodId, flag: flag, index: index), default: 0)
    }
    func setOutroSeconds(_ v: Int, vodId: String, flag: String, index: Int) {
        Persistence.set(PrefKey.outroKey(vodId: vodId, flag: flag, index: index), v)
    }

    // MARK: - 开屏情话 (照搬 Android SplashActivity.DEFAULT_POEM)

    static let defaultPoem = """
    世间所有的浪漫
    都不及你在我身旁
    这方小小的屏幕
    装不下我满心的欢喜
    只好把每个夜晚
    都点亮成你的模样
    """
}
