import AVFoundation
import Foundation
import MingTVCore
import UniformTypeIdentifiers

/// 给 AVPlayer / AVURLAsset 的请求注入自定义请求头 (Referer / User-Agent / Cookie).
///
/// 背景: AVPlayer 没有 ExoPlayer 那样的 `setDefaultRequestProperties(headers)`,
/// 而部分苹果CMS 资源站的 m3u8 有防盗链 —— 不带 Referer 直接请求会返回 text/html 而非 m3u8.
///
/// 方案: 自定义 scheme 中转.
///   1. 把真实 URL 换成 `mingtv://relay?u=<百分号编码的真实URL>`
///   2. 注册 AVAssetResourceLoaderDelegate 拦截请求, 由我们带头重新发起
///   3. 若响应是 m3u8, 把里面所有子 URL(分片/子清单/密钥) 递归改写成同样的包装 URL,
///      保证 HLS 多级加载的每一跳都会经过拦截器
///
/// AVAssetResourceLoaderDelegate 在 macOS 与 iOS 是同一套 API, 因此本验证结论可直接用于 iOS.
public final class HeaderedAssetLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {

    public static let scheme = "mingtv"
    public static let host = "relay"

    private let headers: [String: String]
    private let session: URLSession
    private let queue = DispatchQueue(label: "mingtv.resource-loader")
    private let log: (@Sendable (String) -> Void)?
    /// 打印改写后清单的前后几行, 用于排查
    public var dumpPlaylist = false

    /// 统计
    private let lock = NSLock()
    private var _interceptCount = 0
    private var _playlistCount = 0
    public var interceptCount: Int { lock.withLock { _interceptCount } }
    public var playlistCount: Int { lock.withLock { _playlistCount } }

    public init(headers: [String: String],
                timeout: TimeInterval = 20,
                log: (@Sendable (String) -> Void)? = nil) {
        var h = headers
        if h["User-Agent"] == nil { h["User-Agent"] = CmsClient.defaultUA }
        self.headers = h
        self.log = log
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout
        cfg.httpAdditionalHeaders = h
        self.session = URLSession(configuration: cfg)
        super.init()
    }

    // MARK: - URL 包装 / 还原

    /// 关键: 包装 URL 必须保留原始 host 与 path(尤其是 .m3u8 扩展名),
    /// 否则 AVFoundation 无法推断这是 HLS 清单, 会报 -11828 "media format not supported".
    /// 真实地址完整塞进 query 的 u 参数, 还原时直接取用(无需再拼 host/port, 避免拼接歧义).
    public static func wrap(_ real: URL) -> URL? {
        guard var c = URLComponents(url: real, resolvingAgainstBaseURL: false) else { return nil }
        let full = real.absoluteString
        c.scheme = scheme
        c.query = nil
        c.fragment = nil
        c.queryItems = [URLQueryItem(name: "u", value: full)]
        return c.url
    }

    public static func unwrap(_ wrapped: URL) -> URL? {
        guard wrapped.scheme == scheme,
              let c = URLComponents(url: wrapped, resolvingAgainstBaseURL: false),
              let raw = c.queryItems?.first(where: { $0.name == "u" })?.value,
              let real = URL(string: raw) else { return nil }
        return real
    }

    public static func isWrapped(_ url: URL) -> Bool { url.scheme == scheme }

    /// 构造注入了请求头的 asset. 返回的 URL 已是包装后的 URL.
    public func makeAsset(for realURL: URL) -> (asset: AVURLAsset, assetURL: URL)? {
        guard let wrapped = Self.wrap(realURL) else { return nil }
        let asset = AVURLAsset(url: wrapped)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return (asset, wrapped)
    }

    // MARK: - AVAssetResourceLoaderDelegate

    public func resourceLoader(_ rl: AVAssetResourceLoader,
                               shouldWaitForLoadingOfRequestedResource req: AVAssetResourceLoadingRequest) -> Bool {
        guard let wrapped = req.request.url else { return false }
        guard let real = Self.unwrap(wrapped) else {
            log?("  非包装请求(放行): \(wrapped.absoluteString.prefix(70))")
            return false
        }
        lock.withLock { _interceptCount += 1 }
        log?("  拦截 → \(real.absoluteString.prefix(95))")

        Task { [weak self] in
            guard let self else { return }
            do {
                var r = URLRequest(url: real)
                for (k, v) in self.headers { r.setValue(v, forHTTPHeaderField: k) }
                let (data, resp) = try await self.session.data(for: r)

                guard let http = resp as? HTTPURLResponse else {
                    throw CmsError.network("非 HTTP 响应")
                }
                guard (200..<300).contains(http.statusCode) else {
                    throw CmsError.http(http.statusCode)
                }

                let mime = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
                let isPlaylist = real.path.lowercased().hasSuffix(".m3u8")
                    || mime.contains("mpegurl")
                    || data.starts(with: Array("#EXTM3U".utf8))

                // 诊断: 记录本次请求的 range 意图, 用于排查 -12881
                if let dr = req.dataRequest {
                    self.log?("  [诊断] range offset=\(dr.requestedOffset) len=\(dr.requestedLength) 服务器返回 \(data.count)B")
                }

                var body = data
                if isPlaylist, let text = String(data: data, encoding: .utf8) {
                    self.lock.withLock { self._playlistCount += 1 }
                    let rewritten = Self.rewritePlaylist(text, base: real)
                    body = Data(rewritten.utf8)
                    self.log?("  响应 \(http.statusCode) ct=\(mime.isEmpty ? "-" : mime) \(data.count)B [清单] 已改写子URL → \(rewritten.count) 字符")
                    if self.dumpPlaylist {
                        let head = rewritten.split(separator: "\n").prefix(6).joined(separator: "\n         ")
                        let tail = rewritten.split(separator: "\n").suffix(3).joined(separator: "\n         ")
                        self.log?("  ┌ 改写后前几行:\n         \(head)\n         …\n         \(tail)")
                    }
                } else {
                    self.log?("  响应 \(http.statusCode) ct=\(mime.isEmpty ? "-" : mime) \(data.count)B")
                }

                self.respond(req, body: body, mime: mime, isPlaylist: isPlaylist)
                req.finishLoading()
            } catch {
                self.log?("  加载失败: \(error)")
                req.finishLoading(with: error)
            }
        }
        return true
    }

    private func respond(_ req: AVAssetResourceLoadingRequest, body: Data, mime: String, isPlaylist: Bool) {
        if let ci = req.contentInformationRequest {
            ci.contentLength = Int64(body.count)
            // 必须声明"不支持字节范围请求": 我们在内存中持有完整内容并按偏移切片返回,
            // 若声明支持 range, AVFoundation 会对 AES 密钥(仅 16B)等小资源发出 range 请求,
            // 拿到切片后无法正确解密.
            ci.isByteRangeAccessSupported = false
            // 仅对清单声明 contentType; 分片/密钥等二进制资源不强行指定,
            // 避免错误的 UTI 让 AVFoundation 判定 "media format not supported" (-11828 / -12881).
            if isPlaylist {
                ci.contentType = Self.uti(mime: mime, isPlaylist: true)
            } else if let t = UTType(mimeType: mime), mime.contains("mp2t") || mime.contains("mp4") {
                ci.contentType = t.identifier
            }
        }
        if let dr = req.dataRequest {
            let start = Int(dr.requestedOffset)
            let requested = dr.requestedLength
            let from = min(max(0, start), body.count)
            let to: Int
            if requested <= 0 || requested > body.count {
                to = body.count
            } else {
                to = min(body.count, from + requested)
            }
            if from < to {
                dr.respond(with: body.subdata(in: from..<to))
            }
        }
    }

    private static func uti(mime: String, isPlaylist: Bool) -> String {
        if isPlaylist {
            return UTType(filenameExtension: "m3u8")?.identifier ?? "public.m3u-playlist"
        }
        if !mime.isEmpty, let t = UTType(mimeType: mime) { return t.identifier }
        switch mime {
        case let m where m.contains("mpegurl"): return "public.m3u-playlist"
        case let m where m.contains("mp2t"):    return UTType(filenameExtension: "ts")?.identifier ?? "public.data"
        case let m where m.contains("mp4"):     return UTType(filenameExtension: "mp4")?.identifier ?? "public.data"
        default:                                 return "public.data"
        }
    }

    // MARK: - m3u8 子 URL 改写

    static func rewritePlaylist(_ text: String, base: URL) -> String {
        let lines = text.components(separatedBy: "\n")
        var out: [String] = []
        out.reserveCapacity(lines.count)
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { out.append(raw); continue }
            if line.hasPrefix("#") {
                out.append(rewriteURIAttributes(in: raw, base: base))
            } else if let abs = URL(string: line, relativeTo: base)?.absoluteURL,
                      let wrapped = wrap(abs) {
                out.append(wrapped.absoluteString)
            } else {
                out.append(raw)
            }
        }
        return out.joined(separator: "\n")
    }

    /// 改写 #EXT-X-KEY / #EXT-X-MAP / #EXT-X-MEDIA / #EXT-X-I-FRAME-STREAM-INF 里的 URI="..."
    private static func rewriteURIAttributes(in line: String, base: URL) -> String {
        guard line.contains("URI=") else { return line }
        guard let re = try? NSRegularExpression(pattern: #"URI="([^"]+)""#) else { return line }
        let matches = re.matches(in: line, range: NSRange(line.startIndex..., in: line))
        guard !matches.isEmpty else { return line }

        var result = line
        for m in matches.reversed() {
            guard let r = Range(m.range(at: 1), in: line),
                  let full = Range(m.range(at: 0), in: result) else { continue }
            let uri = String(line[r])
            guard let abs = URL(string: uri, relativeTo: base)?.absoluteURL,
                  let wrapped = wrap(abs) else { continue }
            result.replaceSubrange(full, with: "URI=\"\(wrapped.absoluteString)\"")
        }
        return result
    }
}
