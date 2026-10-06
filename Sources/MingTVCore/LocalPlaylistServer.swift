import Foundation
import Network

/// 极简本地 HTTP 服务: 只做一件事 —— 把远端 m3u8 拉下来 → 过滤广告 →
/// 相对地址改绝对 → 以 http:// 返回给 AVPlayer.
///
/// 为什么不落本地文件: 实测 AVPlayer **不会加载 file:// 形式的播放列表**
/// (交给它一个本地 m3u8 后一个分片请求都不发, 直接卡在 loading).
/// 因此改写后的列表必须以 http:// 形式提供.
///
/// 只转发播放列表, **不转发分片** —— 分片仍由 AVPlayer 直连远端, 保留自适应码率,
/// 也避免在本地代理里处理 Range / 二进制流带来的风险.
public final class LocalPlaylistServer: @unchecked Sendable {

    public static let shared = LocalPlaylistServer()

    private let queue = DispatchQueue(label: "mingtv.playlist-server")
    private let lock = NSLock()
    private var listener: NWListener?
    private var port: UInt16?
    private var starting: Task<UInt16?, Never>?
    /// 远端地址 → 拉取播放列表时要带的请求头 (Referer / Authorization 等)
    private var headerStore: [String: [String: String]] = [:]

    private init() {}

    /// 生成给 AVPlayer 用的代理地址; 失败返回 nil(调用方应回退直连)
    public func proxiedURL(for remote: URL, headers: [String: String]) async -> URL? {
        guard let port = await start() else { return nil }

        let key = remote.absoluteString
        lock.withLock { headerStore[key] = headers }

        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = "127.0.0.1"
        comps.port = Int(port)
        comps.path = "/p"
        comps.queryItems = [URLQueryItem(name: "u", value: key)]
        return comps.url
    }

    // MARK: - 启停

    private func start() async -> UInt16? {
        if let port { return port }
        if let starting { return await starting.value }
        let task = Task<UInt16?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.doStart()
        }
        starting = task
        let value = await task.value
        lock.withLock { starting = nil }
        return value
    }

    private func doStart() async -> UInt16? {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            // 只绑回环地址: 代理没有鉴权, 不能暴露到局域网
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] conn in
                self?.handle(conn)
            }

            let once = Once()
            let readyPort: UInt16? = await withCheckedContinuation { (cont: CheckedContinuation<UInt16?, Never>) in
                l.stateUpdateHandler = { state in
                    once.run {
                        switch state {
                        case .ready:                       cont.resume(returning: l.port?.rawValue)
                        case .failed, .cancelled:          cont.resume(returning: nil)
                        default:                           break
                        }
                    }
                }
                l.start(queue: queue)
            }

            guard let p = readyPort else {
                l.cancel()
                return nil
            }
            listener = l
            port = p
            return p
        } catch {
            return nil
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        port = nil
    }

    // MARK: - 连接处理

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }

            if let range = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf[..<range.lowerBound], as: UTF8.self)
                self.respond(conn, head: head)
                return
            }
            if error != nil || isComplete || buf.count > 64 * 1024 {
                conn.cancel()
                return
            }
            self.receive(conn, buffer: buf)
        }
    }

    private func respond(_ conn: NWConnection, head: String) {
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { conn.cancel(); return }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { conn.cancel(); return }
        let method = String(parts[0]).uppercased()
        let path = String(parts[1])

        guard let comps = URLComponents(string: "http://127.0.0.1" + path),
              let target = comps.queryItems?.first(where: { $0.name == "u" })?.value,
              let remote = URL(string: target) else {
            send(conn, status: 400, body: Data("bad request".utf8), contentType: "text/plain")
            return
        }

        let headers = lock.withLock { headerStore[target] ?? [:] }

        Task { [weak self] in
            guard let self else { conn.cancel(); return }
            guard let (text, base) = await AdFilter.fetchPlaylist(remote, headers: headers) else {
                self.send(conn, status: 502, body: Data("upstream failed".utf8), contentType: "text/plain")
                return
            }
            let (filtered, _) = AdFilter.filter(text)
            let body = Data(AdFilter.absolutize(filtered, base: base).utf8)
            if method == "HEAD" {
                self.send(conn, status: 200, body: Data(),
                          contentType: "application/vnd.apple.mpegurl", contentLength: body.count)
            } else {
                self.send(conn, status: 200, body: body, contentType: "application/vnd.apple.mpegurl")
            }
        }
    }

    private func send(_ conn: NWConnection, status: Int,
                      body: Data, contentType: String, contentLength: Int? = nil) {
        var head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(contentLength ?? body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }
}

/// 保证只执行一次 (NWListener 的 stateUpdateHandler 可能回调多次)
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        if done { lock.unlock(); return }
        done = true
        lock.unlock()
        body()
    }
}
