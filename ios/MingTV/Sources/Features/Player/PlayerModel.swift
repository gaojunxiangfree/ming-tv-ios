import AVFoundation
import Foundation
import MingTVCore
import Observation

/// 播放器内核 (对应 Android: PlayerKernel / ExoKernel)
/// iOS 上统一使用 AVPlayer, 并以「方案 D」注入防盗链请求头.
///
/// `@unchecked Sendable`: AVFoundation 的 KVO 回调可能落在任意线程,
/// 因此本类约定「所有可变状态只在主线程读写」—— 外部调用来自 SwiftUI(主线程),
/// KVO 回调统一经 DispatchQueue.main 回落后再改动状态, 故不存在跨线程数据竞争.
@Observable
final class PlayerModel: @unchecked Sendable {

    static let speeds: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    let player = AVPlayer()

    // MARK: 播放列表

    private(set) var episodes: [Episode] = []
    private(set) var index = 0
    private(set) var title: String = ""
    var lineFlag: String = ""

    private var site: Site?
    private var config: ApiConfig?
    private var extraHeaders: [String: String] = [:]
    private var pendingStart: Double = 0

    // MARK: 状态

    var isPlaying = false
    var isLoading = false
    var duration: Double = 0
    var position: Double = 0
    var errorText: String?
    var speed: Double = 1.0
    var loopEnabled = false
    var showControls = true

    // MARK: 音轨 (对应 Android: PlayerKernel.getAudioTracks / selectAudioTrack)

    struct AudioTrackOption: Identifiable, Hashable {
        let index: Int
        let label: String
        var id: Int { index }
    }

    private(set) var audioTracks: [AudioTrackOption] = []
    /// nil = 自动/默认音轨
    private(set) var selectedAudioIndex: Int?

    private var audibleGroup: AVMediaSelectionGroup?
    private var audibleOptions: [AVMediaSelectionOption] = []

    /// 去广告生效时的提示文案
    private(set) var adFilterNotice: String?
    private var adFilterEnabled = true

    var currentEpisodeName: String {
        guard episodes.indices.contains(index) else { return "" }
        return episodes[index].title
    }

    var hasNext: Bool { index + 1 < episodes.count }
    var hasPrev: Bool { index > 0 }

    // MARK: 观察器

    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?

    init() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            self.position = time.seconds.isFinite ? time.seconds : 0
            if let d = self.player.currentItem?.duration.seconds, d.isFinite, d > 0 {
                self.duration = d
            }
        }
        rateObservation = player.observe(\.timeControlStatus, options: [.new, .initial]) { [weak self] p, _ in
            let playing = (p.timeControlStatus == .playing)
            DispatchQueue.main.async { self?.isPlaying = playing }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleEnded()
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        statusObservation?.invalidate()
        rateObservation?.invalidate()
    }

    // MARK: - 装载

    func start(target: PlayTarget, site: Site?, config: ApiConfig?, speed: Double, loop: Bool,
               adFilterEnabled: Bool = true) async {
        self.site = site
        self.config = config
        self.extraHeaders = target.extraHeaders
        self.adFilterEnabled = adFilterEnabled
        self.title = target.vod.name
        self.lineFlag = target.line.flag
        self.episodes = target.line.episodes
        self.index = min(max(0, target.startIndex), max(0, target.line.episodes.count - 1))
        self.pendingStart = target.startPosition
        self.speed = speed
        self.loopEnabled = loop
        await loadCurrent()
    }

    func loadCurrent() async {
        guard episodes.indices.contains(index) else {
            errorText = "没有可播放的剧集"
            return
        }
        isLoading = true
        errorText = nil
        duration = 0
        position = 0
        resetTrackState()

        let ep = episodes[index]
        var request = await PlayUrlResolver.resolve(episodeURL: ep.url, site: site, config: config,
                                                   extraHeaders: extraHeaders)

        // m3u8 去广告: 先探测是否含广告, 命中则改走本地转发(边取边过滤)
        if adFilterEnabled, let playlistURL = URL(string: request.url),
           let removed = await AdFilter.probe(playlistURL, headers: request.headers), removed > 0,
           let proxied = await LocalPlaylistServer.shared.proxiedURL(for: playlistURL,
                                                                    headers: request.headers) {
            request.url = proxied.absoluteString
            adFilterNotice = "已过滤 \(removed) 行广告分片"
        }

        guard let url = URL(string: request.url) else {
            errorText = "播放地址非法"
            isLoading = false
            return
        }

        statusObservation?.invalidate()
        let item = PlaybackAsset.makeItem(url: url, headers: request.headers)
        statusObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            // KVO 可能不在主线程回调, 统一回落主线程再改 UI 状态
            DispatchQueue.main.async {
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    self.isLoading = false
                    let secs = item.duration.seconds
                    if secs.isFinite, secs > 0 { self.duration = secs }
                    if self.pendingStart > 1 {
                        self.player.seek(to: CMTime(seconds: self.pendingStart, preferredTimescale: 600),
                                         toleranceBefore: .zero, toleranceAfter: .zero)
                        self.pendingStart = 0
                    }
                    self.player.play()
                    self.player.rate = Float(self.speed)
                    Task { await self.loadAudioTracks() }
                case .failed:
                    self.isLoading = false
                    let ns = item.error as NSError?
                    self.errorText = ns.map { "播放失败: \($0.domain) \($0.code)" } ?? "播放失败"
                default:
                    break
                }
            }
        }

        player.replaceCurrentItem(with: item)
    }

    // MARK: - 音轨

    private func resetTrackState() {
        audibleGroup = nil
        audibleOptions = []
        audioTracks = []
        selectedAudioIndex = nil
        adFilterNotice = nil
    }

    /// 收集可用音轨 (多音轨源: 国语/粤语/原声 等)
    func loadAudioTracks() async {
        guard let item = player.currentItem else { return }
        let group = try? await item.asset.loadMediaSelectionGroup(for: .audible)
        let options = group?.options ?? []
        let tracks = options.enumerated().map { idx, opt in
            AudioTrackOption(index: idx, label: Self.label(for: opt, index: idx))
        }
        DispatchQueue.main.async {
            self.audibleGroup = group
            self.audibleOptions = options
            self.audioTracks = tracks
            self.syncSelectedAudio()
        }
    }

    /// 选择音轨, 传 nil 恢复默认(自动选择)
    func selectAudioTrack(_ index: Int?) {
        guard let group = audibleGroup, let item = player.currentItem else { return }
        if let index, audibleOptions.indices.contains(index) {
            item.select(audibleOptions[index], in: group)
        } else {
            item.selectMediaOptionAutomatically(in: group)
        }
        selectedAudioIndex = index
    }

    private func syncSelectedAudio() {
        guard let group = audibleGroup, let item = player.currentItem else {
            selectedAudioIndex = nil
            return
        }
        if let current = item.currentMediaSelection.selectedMediaOption(in: group),
           let idx = audibleOptions.firstIndex(of: current) {
            selectedAudioIndex = idx
        } else {
            selectedAudioIndex = nil
        }
    }

    /// 语言码 → 标签, 与 Android ExoKernel.labelForAudioLang 对齐
    private static func label(for option: AVMediaSelectionOption, index: Int) -> String {
        let code = (option.locale?.language.languageCode?.identifier ?? "").lowercased()
        switch code {
        case "zh", "chi", "zho", "cmn", "zh-hans": return "国语"
        case "yue", "zh-hant":                     return "粤语"
        case "en", "eng":                          return "English"
        case "ja", "jpn":                          return "日语"
        case "ko", "kor":                          return "韩语"
        default:                                   break
        }
        if !code.isEmpty { return code }
        // AVFoundation 对无语言信息的轨道会给 displayName = "Unknown", 与 Android 一样回落到"原声"
        let name = option.displayName
        if !name.isEmpty, name.caseInsensitiveCompare("unknown") != .orderedSame { return name }
        return index == 0 ? "原声" : "音轨 \(index + 1)"
    }

    // MARK: - 控制

    func togglePlay() {
        if isPlaying {
            player.pause()
        } else {
            if player.currentItem?.status == .readyToPlay { player.play(); player.rate = Float(speed) }
            else { Task { await loadCurrent() } }
        }
    }

    func seek(to seconds: Double) {
        let target = max(0, min(seconds, duration > 0 ? duration : seconds))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        position = target
    }

    func seek(by delta: Double) { seek(to: position + delta) }

    func applySpeed(_ value: Double) {
        speed = value
        if isPlaying { player.rate = Float(value) }
    }

    func next() {
        guard hasNext else { return }
        index += 1
        pendingStart = 0
        Task { await loadCurrent() }
    }

    func prev() {
        guard hasPrev else { return }
        index -= 1
        pendingStart = 0
        Task { await loadCurrent() }
    }

    func jump(to index: Int) {
        guard episodes.indices.contains(index) else { return }
        self.index = index
        pendingStart = 0
        Task { await loadCurrent() }
    }

    func reload() {
        let keep = position
        pendingStart = keep
        Task { await loadCurrent() }
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    private func handleEnded() {
        if loopEnabled {
            player.seek(to: .zero)
            player.play()
            player.rate = Float(speed)
        } else if hasNext {
            next()
        } else {
            isPlaying = false
        }
    }
}
