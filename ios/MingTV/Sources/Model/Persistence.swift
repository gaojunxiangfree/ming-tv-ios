import Foundation
import MingTVCore

// MARK: - 偏好设置键名 (照搬 Android: util/PrefUtils.java, SharedPreferences 名 sean_ming_pref)

enum PrefKey {
    static let apiURL = "api_url"
    static let apiSources = "api_sources"
    static let homeSite = "home_site"
    static let playSpeed = "play_speed"
    static let loopEnabled = "loop_enabled"
    /// m3u8 去广告开关
    static let adFilter = "ad_filter"
    static let playlistLayout = "playlist_layout"
    static let searchHistory = "search_history"
    static let liveGroupIndex = "live_group_index"
    static let liveChannelIndex = "live_channel_index"
    static let splashPoemOn = "splash_poem_on"
    static let splashPoem = "splash_poem"
    static let splashTTSOn = "splash_tts_on"
    static let splashTTSText = "splash_tts_text"

    static func introKey(vodId: String, flag: String, index: Int) -> String { "intro_\(vodId)_\(flag)_\(index)" }
    static func outroKey(vodId: String, flag: String, index: Int) -> String { "outro_\(vodId)_\(flag)_\(index)" }
}

// MARK: - 收藏 / 历史 (对应 Android Room: Favorite / HistoryRecord)

struct FavoriteItem: Codable, Identifiable, Hashable {
    var siteKey: String
    var vodId: String
    var vodName: String
    var vodPic: String
    var vodRemarks: String
    var createTime: Double

    /// 主键与 Android 一致: siteKey|vodId
    var id: String { "\(siteKey)|\(vodId)" }
}

struct HistoryItem: Codable, Identifiable, Hashable {
    var siteKey: String
    var vodId: String
    var vodName: String
    var vodPic: String
    var flag: String
    var episodeIndex: Int
    var episodeName: String
    var position: Double
    var duration: Double
    var updateTime: Double

    var id: String { "\(siteKey)|\(vodId)" }
}

// MARK: - 本地持久化

enum Persistence {

    private static let defaults = UserDefaults.standard

    // 列表数据存 Application Support 下的 JSON 文件 (对应 Room 表)
    private static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        if !FileManager.default.fileExists(atPath: base.path) {
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        }
        return base
    }

    private static func load<T: Decodable>(_ type: T.Type, from file: String) -> T? {
        let url = dir.appendingPathComponent(file)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func save<T: Encodable>(_ value: T, to file: String) {
        let url = dir.appendingPathComponent(file)
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // 收藏
    static func loadFavorites() -> [FavoriteItem] { load([FavoriteItem].self, from: "favorites.json") ?? [] }
    static func saveFavorites(_ v: [FavoriteItem]) { save(v, to: "favorites.json") }

    // 历史
    static func loadHistory() -> [HistoryItem] { load([HistoryItem].self, from: "history.json") ?? [] }
    static func saveHistory(_ v: [HistoryItem]) { save(v, to: "history.json") }

    // 网盘 (对应 Android: DriveStore, SharedPreferences key drive_list)
    static func loadDrives() -> [StorageDrive] { load([StorageDrive].self, from: "drives.json") ?? [] }
    static func saveDrives(_ v: [StorageDrive]) { save(v, to: "drives.json") }

    // MARK: 偏好读写

    static func string(_ key: String, default def: String = "") -> String {
        defaults.string(forKey: key) ?? def
    }
    static func set(_ key: String, _ value: String) { defaults.set(value, forKey: key) }

    static func double(_ key: String, default def: Double) -> Double {
        defaults.object(forKey: key) == nil ? def : defaults.double(forKey: key)
    }
    static func set(_ key: String, _ value: Double) { defaults.set(value, forKey: key) }

    static func int(_ key: String, default def: Int) -> Int {
        defaults.object(forKey: key) == nil ? def : defaults.integer(forKey: key)
    }
    static func set(_ key: String, _ value: Int) { defaults.set(value, forKey: key) }

    static func bool(_ key: String, default def: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? def : defaults.bool(forKey: key)
    }
    static func set(_ key: String, _ value: Bool) { defaults.set(value, forKey: key) }

    static func strings(_ key: String) -> [String] { defaults.stringArray(forKey: key) ?? [] }
    static func set(_ key: String, _ value: [String]) { defaults.set(value, forKey: key) }
}
