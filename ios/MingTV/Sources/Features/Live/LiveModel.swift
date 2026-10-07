import AVFoundation
import Foundation
import MingTVCore
import Observation

/// 直播 (对应 Android: LiveActivity + M3uParser + EpgManager)
/// 同 PlayerModel: 约定可变状态只在主线程读写, KVO 回调经 DispatchQueue.main 回落.
@Observable
final class LiveModel: @unchecked Sendable {

    private(set) var groups: [LiveGroup] = []
    private(set) var loading = false
    private(set) var status = ""
    private(set) var error: String?

    var selectedGroupIndex = 0
    var selectedChannelIndex = 0

    // EPG
    private(set) var epg: [String: [EpgProgram]] = [:]
    private(set) var epgLoading = false

    // 播放
    let player = AVPlayer()
    private(set) var isPlaying = false
    private(set) var playingChannelName = ""
    var httpHeaders: [String: String] = [:]
    private(set) var playError: String?
    /// 横屏全屏时控制层的显隐 (与播放页一致)
    var showControls = true

    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var now: Date = Date()

    init() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main
        ) { [weak self] _ in
            self?.now = Date()
        }
        rateObservation = player.observe(\.timeControlStatus, options: [.new, .initial]) { [weak self] p, _ in
            let playing = (p.timeControlStatus == .playing)
            DispatchQueue.main.async { self?.isPlaying = playing }
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        statusObservation?.invalidate()
        rateObservation?.invalidate()
    }

    // MARK: 频道

    var currentGroup: LiveGroup? {
        groups.indices.contains(selectedGroupIndex) ? groups[selectedGroupIndex] : nil
    }

    var currentChannel: LiveChannel? {
        guard let g = currentGroup, g.channels.indices.contains(selectedChannelIndex) else { return nil }
        return g.channels[selectedChannelIndex]
    }

    // MARK: - 装载直播源

    func load(config: ApiConfig?) async {
        loading = true
        error = nil
        defer { loading = false }

        var decls: [(url: String, ua: String?)] = []
        for d in config?.lives ?? [] where d.type == 0 {
            if let u = d.url { decls.append((u, d.ua)) }
        }
        // 接口自带源加载失败时回退内置公开源 (与 Android 一致)
        for url in BuiltinLive.urls where !decls.contains(where: { $0.url == url }) {
            decls.append((url, nil))
        }

        var built: [LiveGroup] = []
        var epgURLs: [String] = []
        var alive = 0

        for decl in decls {
            do {
                let result = try await M3uParser.parseFromURL(decl.url, userAgent: decl.ua)
                guard !result.groups.isEmpty else { continue }
                alive += 1
                epgURLs.append(contentsOf: result.epgURLs)
                built.append(contentsOf: result.groups)
            } catch {
                continue
            }
        }

        // 同名分组合并
        var merged: [String: [LiveChannel]] = [:]
        var order: [String] = []
        for g in built {
            if merged[g.name] == nil { order.append(g.name) }
            merged[g.name, default: []].append(contentsOf: g.channels)
        }
        groups = order.map { LiveGroup(name: $0, channels: merged[$0] ?? []) }

        if groups.isEmpty {
            self.error = "直播源加载失败，请检查网络或接口配置"
            return
        }
        status = "\(alive) 个直播源 · \(groups.reduce(0) { $0 + $1.channels.count }) 个频道"

        // 恢复上次观看的分组
        let savedGroup = Persistence.int(PrefKey.liveGroupIndex, default: 0)
        selectedGroupIndex = groups.indices.contains(savedGroup) ? savedGroup : 0
        selectedChannelIndex = 0

        // EPG 异步加载 (不阻塞频道播放)
        let urls = epgURLs.isEmpty ? BuiltinLive.epgURLs : epgURLs
        Task { await loadEPG(urls: urls) }

        playCurrent()
    }

    private func loadEPG(urls: [String]) async {
        epgLoading = true
        defer { epgLoading = false }
        let table = await EpgClient.load(urls: urls)
        guard !table.isEmpty else { return }
        epg = table
        now = Date()
    }

    var currentProgram: EpgProgram? {
        guard let ch = currentChannel else { return nil }
        let list = EpgClient.lookup(epg, channelName: ch.name, tvgID: ch.tvgID)
        return EpgClient.current(list, at: now)
    }

    var nextProgram: EpgProgram? {
        guard let ch = currentChannel else { return nil }
        let list = EpgClient.lookup(epg, channelName: ch.name, tvgID: ch.tvgID)
        return EpgClient.next(list, at: now)
    }

    /// 当前频道的今日节目单
    var todayPrograms: [EpgProgram] {
        guard let ch = currentChannel else { return [] }
        let list = EpgClient.lookup(epg, channelName: ch.name, tvgID: ch.tvgID)
        let cal = Calendar.current
        return list.filter { cal.isDate($0.start, inSameDayAs: now) || cal.isDate($0.end, inSameDayAs: now) }
    }

    // MARK: - 播放

    func selectGroup(_ index: Int) {
        guard groups.indices.contains(index) else { return }
        selectedGroupIndex = index
        selectedChannelIndex = 0
        Persistence.set(PrefKey.liveGroupIndex, index)
        playCurrent()
    }

    func selectChannel(_ index: Int) {
        guard let g = currentGroup, g.channels.indices.contains(index) else { return }
        selectedChannelIndex = index
        Persistence.set(PrefKey.liveChannelIndex, index)
        playCurrent()
    }

    func playCurrent() {
        guard let ch = currentChannel else { return }
        play(ch)
    }

    /// 同组内切上一台 / 下一台 (横屏全屏时用, 循环)
    func stepChannel(_ delta: Int) {
        guard let g = currentGroup, !g.channels.isEmpty else { return }
        let count = g.channels.count
        selectChannel(((selectedChannelIndex + delta) % count + count) % count)
    }

    func play(_ channel: LiveChannel) {
        guard let url = URL(string: channel.primaryURL) else {
            playError = "频道地址非法"
            return
        }
        playError = nil
        playingChannelName = channel.name

        // 每个频道独立 UA (Android: 错误 UA 会被源 404, 因此不做全局设置)
        var headers: [String: String] = [:]
        if let ua = channel.httpUserAgent, !ua.isEmpty { headers["User-Agent"] = ua }
        httpHeaders = headers

        statusObservation?.invalidate()
        let item = PlaybackAsset.makeItem(url: url, headers: headers)
        statusObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if item.status == .failed {
                    let ns = item.error as NSError?
                    self.playError = ns.map { "播放失败: \($0.domain) \($0.code)" } ?? "播放失败"
                } else if item.status == .readyToPlay {
                    self.playError = nil
                }
            }
        }
        player.replaceCurrentItem(with: item)
        player.play()
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    func refreshNow() { now = Date() }
}
