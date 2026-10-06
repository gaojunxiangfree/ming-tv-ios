import AVFoundation
import Foundation
import MingTVCore

/// AVFoundation 加载验证.
/// 对比三种"给 AVPlayer 注入请求头"的方案, 判断哪种在防盗链场景下真正可用.
/// 该 API 在 macOS 与 iOS 完全一致, 因此结论可直接作为 iOS 实现依据.
public enum AssetPlaybackProbe {

    public struct Outcome: Sendable {
        public let approach: String
        public let loaded: Bool
        public let isPlayable: Bool
        public let readyToPlay: Bool
        public let durationSec: Double
        public let tracks: Int
        public let intercepted: Int
        public let playlists: Int
        public let note: String

        public var summary: String {
            guard loaded else { return "❌ 失败  \(note)" }
            let ready = readyToPlay ? "readyToPlay" : "未就绪"
            var s = "✅ asset加载成功  playable=\(isPlayable)  \(ready)  时长=\(String(format: "%.1f", durationSec))s  轨道=\(tracks)  拦截=\(intercepted) 清单=\(playlists)"
            if !note.isEmpty { s += "\n              注: \(note)" }
            return s
        }
    }

    // MARK: - 方案 A: 裸 https, 不注入请求头 (基线)

    public static func bare(_ url: URL, timeout: TimeInterval = 25) async -> Outcome {
        let asset = AVURLAsset(url: url)
        return await load(asset, approach: "A 裸请求(不注入头)", loader: nil, timeout: timeout)
    }

    // MARK: - 方案 B: 标准 https URL + 设置 delegate
    // 目的: 验证 AVFoundation 对标准 http(s) scheme 会不会回调 delegate

    public static func standardWithDelegate(_ url: URL, headers: [String: String],
                                            timeout: TimeInterval = 25,
                                            log: (@Sendable (String) -> Void)? = nil) async -> Outcome {
        let loader = HeaderedAssetLoader(headers: headers, log: log)
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(loader, queue: DispatchQueue(label: "probe.std"))
        return await load(asset, approach: "B 标准 https + delegate", loader: loader, timeout: timeout)
    }

    // MARK: - 方案 C: 自定义 scheme 中转 + delegate

    public static func wrapped(_ url: URL, headers: [String: String],
                               dumpPlaylist: Bool = false,
                               timeout: TimeInterval = 25,
                               log: (@Sendable (String) -> Void)? = nil) async -> Outcome {
        let loader = HeaderedAssetLoader(headers: headers, log: log)
        loader.dumpPlaylist = dumpPlaylist
        guard let (asset, _) = loader.makeAsset(for: url) else {
            return Outcome(approach: "C 自定义 scheme 中转", loaded: false, isPlayable: false,
                           readyToPlay: false, durationSec: 0, tracks: 0, intercepted: 0,
                           playlists: 0, note: "URL 包装失败")
        }
        return await load(asset, approach: "C 自定义 scheme 中转", loader: loader, timeout: timeout)
    }

    // MARK: - 方案 D: AVURLAssetHTTPHeaderFieldsKey
    // AVFoundation 内置的请求头注入选项, 无需自定义 scheme 与 resource loader.
    // 非公开文档 API, 但在 HLS 场景被广泛使用.

    public static func headerFields(_ url: URL, headers: [String: String],
                                    timeout: TimeInterval = 25) async -> Outcome {
        let options: [String: Any] = ["AVURLAssetHTTPHeaderFieldsKey": headers]
        let asset = AVURLAsset(url: url, options: options)
        return await load(asset, approach: "D AVURLAssetHTTPHeaderFieldsKey", loader: nil, timeout: timeout)
    }

    // MARK: - 实际加载

    private static func load(_ asset: AVURLAsset,
                             approach: String,
                             loader: HeaderedAssetLoader?,
                             timeout: TimeInterval = 25) async -> Outcome {

        func make(_ loaded: Bool, _ playable: Bool, _ ready: Bool, _ dur: Double,
                  _ tracks: Int, _ note: String) -> Outcome {
            Outcome(approach: approach, loaded: loaded, isPlayable: playable, readyToPlay: ready,
                    durationSec: dur, tracks: tracks,
                    intercepted: loader?.interceptCount ?? 0,
                    playlists: loader?.playlistCount ?? 0,
                    note: note)
        }

        // 整体超时保护: CLI 下 AVFoundation 偶发不回调
        let work = Task<(Bool, Bool, Bool, Double, Int, String), Never> {
            do {
                let playable = try await asset.load(.isPlayable)
                let duration = try await asset.load(.duration)
                let tracks = try await asset.load(.tracks)
                let secs = CMTimeGetSeconds(duration)

                // 权威判定: 建 AVPlayerItem 等 readyToPlay
                let (ready, readyNote) = await waitReady(asset, timeout: timeout)

                return (true, playable, ready, secs.isFinite ? secs : 0, tracks.count, readyNote)
            } catch {
                return (false, false, false, 0, 0, "\(error)")
            }
        }

        let timeoutTask = Task { () -> (Bool, Bool, Bool, Double, Int, String) in
            try? await Task.sleep(nanoseconds: UInt64((timeout + 5) * 1_000_000_000))
            return (false, false, false, 0, 0, "整体超时")
        }

        let r = await withTaskGroup(of: (Bool, Bool, Bool, Double, Int, String).self) { group -> (Bool, Bool, Bool, Double, Int, String) in
            group.addTask { await work.value }
            group.addTask { await timeoutTask.value }
            let first = await group.next()!
            group.cancelAll()
            return first
        }
        work.cancel()
        timeoutTask.cancel()

        return make(r.0, r.1, r.2, r.3, r.4, r.5)
    }

    /// 建立 AVPlayerItem 并轮询 status, 等待 readyToPlay / failed.
    /// 这是"能不能播"的权威答案 —— 单看 isPlayable 会出现误判.
    private static func waitReady(_ asset: AVAsset, timeout: TimeInterval) async -> (Bool, String) {
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.rate = 0

        let deadline = Date().addingTimeInterval(timeout)
        var result: (Bool, String) = (false, "未就绪")
        while Date() < deadline {
            switch item.status {
            case .readyToPlay:
                result = (true, "")
                break
            case .failed:
                result = (false, item.error.map { "\($0)" } ?? "未知错误")
                break
            default:
                try? await Task.sleep(nanoseconds: 200_000_000)
                continue
            }
            break
        }
        if item.status != .readyToPlay && item.status != .failed {
            result = (false, "等待就绪超时")
        }
        _ = player.status
        return result
    }
}
