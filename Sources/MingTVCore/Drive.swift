import Foundation

// MARK: - 网盘配置 (对应 Android: bean/StorageDrive.java)

public struct StorageDrive: Codable, Sendable, Hashable, Identifiable {
    public static let typeWebDAV = 1
    public static let typeAList = 2

    public var id: Int
    public var name: String
    /// 1 = WebDAV, 2 = AList
    public var type: Int
    public var url: String
    public var username: String
    public var password: String
    /// 登录后进入的初始目录
    public var initPath: String

    public init(id: Int = 0, name: String, type: Int, url: String,
                username: String = "", password: String = "", initPath: String = "/") {
        self.id = id
        self.name = name
        self.type = type
        self.url = url
        self.username = username
        self.password = password
        self.initPath = initPath.isEmpty ? "/" : initPath
    }

    public var isWebDAV: Bool { type == Self.typeWebDAV }
    public var isAList: Bool { type == Self.typeAList }

    /// 规范化根地址: 补协议、补尾斜杠 (对应 Android baseUrl())
    public var baseURL: String {
        var u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !u.lowercased().hasPrefix("http://") && !u.lowercased().hasPrefix("https://") {
            u = "http://" + u
        }
        if !u.hasSuffix("/") { u += "/" }
        return u
    }

    /// WebDAV Basic 认证头 (对应 Android basicAuth())
    public var basicAuth: String {
        let raw = "\(username):\(password)"
        let b64 = Data(raw.utf8).base64EncodedString()
        return "Basic \(b64)"
    }
}

// MARK: - 网盘文件 (对应 Android: bean/DriveFile.java)

public struct DriveFile: Sendable, Hashable, Identifiable {
    public var name: String
    /// 相对网盘根目录的路径, 以 / 开头
    public var path: String
    public var isDirectory: Bool
    public var size: Int64
    public var modified: Date?
    /// AList 直接返回的可播放地址 (优先使用)
    public var directURL: String?

    public var id: String { path }

    public var ext: String {
        let e = (name as NSString).pathExtension.lowercased()
        return e
    }

    /// 广义媒体文件 (用于列表展示/过滤)
    public var isMedia: Bool { Self.mediaExts.contains(ext) }

    /// AVPlayer 可直接播放的格式.
    /// 注意: iOS 无 FFmpeg 内核, mkv/avi/flv/webm 等无法播放 —— 安卓版靠 IJK 兜底, iOS 必须如实提示.
    public var isAVPlayable: Bool { Self.playableExts.contains(ext) }

    public var sizeText: String {
        if isDirectory { return "" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(size)
        var idx = 0
        while value >= 1024, idx < units.count - 1 { value /= 1024; idx += 1 }
        return idx == 0 ? "\(size) B" : String(format: "%.1f %@", value, units[idx])
    }

    private static let mediaExts: Set<String> = [
        "m3u8", "m3u", "mp4", "m4v", "mov", "ts", "mkv", "avi", "flv", "webm", "wmv", "rmvb", "rm",
        "mp3", "m4a", "aac", "flac", "wav", "ogg",
    ]
    private static let playableExts: Set<String> = [
        "m3u8", "m3u", "mp4", "m4v", "mov", "ts", "mp3", "m4a", "aac", "wav",
    ]
}

// MARK: - 网盘访问 (对应 Android: api/DriveApi.java)

public enum DriveError: Error, CustomStringConvertible {
    case unsupported(String)
    case auth(String)
    case api(String)
    case empty

    public var description: String {
        switch self {
        case .unsupported(let s): return "暂不支持: \(s)"
        case .auth(let s):        return "认证失败: \(s)"
        case .api(let s):         return "接口错误: \(s)"
        case .empty:              return "目录为空"
        }
    }
}

/// 网盘 API 客户端. 用 actor 隔离, 因为 AList 的 token 是有状态的可变字段.
public actor DriveApi {

    private let drive: StorageDrive
    private var token: String?

    public init(drive: StorageDrive) {
        self.drive = drive
    }

    public var driveInfo: StorageDrive { drive }

    // MARK: - 列目录

    public func list(_ path: String) async throws -> [DriveFile] {
        if drive.isWebDAV { return try await listWebDAV(path) }
        if drive.isAList { return try await listAList(path) }
        throw DriveError.unsupported("网盘类型 \(drive.type)")
    }

    // MARK: - 解析可播放地址

    /// 返回 (可直接播放的地址, 播放时需要附带的请求头)
    public func resolve(_ file: DriveFile) async throws -> (url: String, headers: [String: String]) {
        if drive.isWebDAV {
            return (drive.baseURL + Self.encodePath(file.path),
                    ["Authorization": drive.basicAuth])
        }
        // AList: 优先列表已给出的直链
        if let direct = file.directURL, !direct.isEmpty {
            return (normalizeAListURL(direct), [:])
        }
        let headers = alistHeaders()
        let json = try await MingNet.postJSON(drive.baseURL + "api/fs/get",
                                              body: ["path": file.path, "password": ""],
                                              headers: headers)
        guard let data = json["data"] as? [String: Any],
              let raw = data["raw_url"] as? String, !raw.isEmpty else {
            throw DriveError.api("未能获取直链 (该文件可能受网盘账号权限限制)")
        }
        return (normalizeAListURL(raw), [:])
    }

    // MARK: - WebDAV (PROPFIND + Depth:1)

    private func listWebDAV(_ path: String) async throws -> [DriveFile] {
        // 列目录时补尾斜杠: 部分 WebDAV 服务对集合路径缺尾斜杠会 301, URLSession 跟随重定向后 PROPFIND 语义可能变化
        var target = drive.baseURL + Self.encodePath(path)
        if !target.hasSuffix("/") { target += "/" }
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:">
          <d:prop>
            <d:displayname/>
            <d:getcontentlength/>
            <d:getlastmodified/>
            <d:resourcetype/>
          </d:prop>
        </d:propfind>
        """.data(using: .utf8)

        var headers = [
            "Depth": "1",
            "Content-Type": "application/xml; charset=utf-8",
            "User-Agent": MingNet.okhttpUA,
        ]
        if !drive.username.isEmpty { headers["Authorization"] = drive.basicAuth }

        let (data, http) = try await MingNet.request(target, method: "PROPFIND",
                                                     headers: headers, body: body, timeout: 20)
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw DriveError.auth("账号或密码错误") }
            throw CmsError.http(http.statusCode)
        }

        let entries = Self.parseWebDAV(data)
        let basePath = URL(string: drive.baseURL)?.path ?? "/"
        return Self.toDriveFiles(entries: entries, basePath: basePath, currentPath: path)
    }

    /// 解析 multistatus, 输出 (绝对路径, 显示名, 是否目录, 大小, 修改时间)
    static func parseWebDAV(_ data: Data) -> [WebDAVEntry] {
        let parser = XMLParser(data: data)
        let delegate = WebDAVDelegate()
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.parse()
        return delegate.entries
    }

    struct WebDAVEntry {
        var href: String = ""
        var displayName: String?
        var length: Int64 = 0
        var modified: String?
        var isCollection = false
    }

    /// 把服务端返回的绝对 href 归一到相对网盘根目录的路径
    static func toDriveFiles(entries: [WebDAVEntry], basePath: String, currentPath: String) -> [DriveFile] {
        let currentAbsolute = basePath + currentPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var out: [DriveFile] = []

        for e in entries {
            let href = e.href.removingPercentEncoding ?? e.href
            guard !href.isEmpty else { continue }
            // 跳过目录自身 (PROPFIND 会把当前目录也返回)
            let normalizedHref = href.hasSuffix("/") ? String(href.dropLast()) : href
            let normalizedCurrent = currentAbsolute.hasSuffix("/")
                ? String(currentAbsolute.dropLast()) : currentAbsolute
            if normalizedHref == normalizedCurrent { continue }

            // 相对路径: 去掉网盘根路径前缀
            var rel = href
            if rel.hasPrefix(basePath) { rel = String(rel.dropFirst(basePath.count)) }
            rel = rel.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !rel.isEmpty else { continue }

            let name = e.displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? e.displayName!
                : (rel as NSString).lastPathComponent
            guard !name.isEmpty else { continue }

            out.append(DriveFile(name: name,
                                 path: "/" + rel + (e.isCollection ? "/" : ""),
                                 isDirectory: e.isCollection,
                                 size: e.isCollection ? 0 : e.length,
                                 modified: Self.parseHTTPDate(e.modified),
                                 directURL: nil))
        }
        return out.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    // MARK: - AList

    private func alistHeaders() -> [String: String] {
        var h = ["User-Agent": MingNet.okhttpUA]
        if let token, !token.isEmpty { h["Authorization"] = token }
        return h
    }

    private func ensureAListLogin() async {
        guard token == nil, !drive.username.isEmpty else { return }
        let json = try? await MingNet.postJSON(drive.baseURL + "api/auth/login",
                                               body: ["username": drive.username, "password": drive.password])
        if let data = json?["data"] as? [String: Any], let t = data["token"] as? String {
            token = t
        }
    }

    private func listAList(_ path: String) async throws -> [DriveFile] {
        await ensureAListLogin()

        // 1) 标准列目录 (公开路径无需 token 也能读)
        if let json = try? await MingNet.postJSON(drive.baseURL + "api/fs/list",
                                                  body: ["path": path, "password": "", "page": 1,
                                                         "per_page": 0, "refresh": false],
                                                  headers: alistHeaders()),
           let data = json["data"] as? [String: Any] {
            let content = (data["content"] as? [[String: Any]]) ?? []
            let files = content.compactMap { aListFile($0, parent: path) }
            if !files.isEmpty { return files }
            if data["total"] != nil { return [] }
        }

        // 2) 回退到公共路径接口
        let json = try await MingNet.postJSON(drive.baseURL + "api/public/path",
                                              body: ["path": path, "password": ""],
                                              headers: alistHeaders())
        guard let data = json["data"] as? [String: Any] else {
            throw DriveError.api(Self.aListMessage(json))
        }
        let files = (data["files"] as? [[String: Any]]) ?? []
        return files.compactMap { aListFile($0, parent: path) }
    }

    private func aListFile(_ raw: [String: Any], parent: String) -> DriveFile? {
        guard let name = raw["name"] as? String, !name.isEmpty else { return nil }
        let isDir = (raw["is_dir"] as? Bool) ?? ((raw["type"] as? Int) == 1)
        let size = (raw["size"] as? NSNumber)?.int64Value ?? 0
        let rel = parent.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let full = "/" + (rel.isEmpty ? name : rel + "/" + name)
        return DriveFile(name: name,
                         path: full + (isDir ? "/" : ""),
                         isDirectory: isDir,
                         size: isDir ? 0 : size,
                         modified: Self.parseRawDate(raw["modified"] as? String),
                         directURL: (raw["raw_url"] as? String) ?? (raw["url"] as? String))
    }

    /// AList 的 raw_url 可能是相对路径, 需要拼回源站
    private func normalizeAListURL(_ raw: String) -> String {
        if raw.lowercased().hasPrefix("http://") || raw.lowercased().hasPrefix("https://") { return raw }
        guard let base = URL(string: drive.baseURL),
              let scheme = base.scheme, let host = base.host else { return raw }
        let port = base.port.map { ":\($0)" } ?? ""
        return raw.hasPrefix("/") ? "\(scheme)://\(host)\(port)\(raw)"
                                  : "\(scheme)://\(host)\(port)/\(raw)"
    }

    private static func aListMessage(_ json: [String: Any]) -> String {
        (json["message"] as? String) ?? "未知错误"
    }

    // MARK: - 工具

    /// 逐段百分号编码 (保留 / 分隔), 对应 Android encodePath()
    static func encodePath(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
    }

    private static func parseHTTPDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: s)
    }

    private static func parseRawDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: s)
    }
}

// MARK: - WebDAV multistatus 解析

private final class WebDAVDelegate: NSObject, XMLParserDelegate {
    var entries: [DriveApi.WebDAVEntry] = []

    private var current: DriveApi.WebDAVEntry?
    private var text = ""
    private var collecting: String?

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        text = ""
        switch elementName {
        case "response":
            current = DriveApi.WebDAVEntry()
        case "collection":
            current?.isCollection = true
        case "href", "displayname", "getcontentlength", "getlastmodified":
            collecting = elementName
        default:
            collecting = nil
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if collecting != nil { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "href":
            if current?.href.isEmpty ?? false { current?.href = value }
        case "displayname":
            if current?.displayName == nil { current?.displayName = value }
        case "getcontentlength":
            if let v = Int64(value) { current?.length = v }
        case "getlastmodified":
            current?.modified = value
        case "response":
            if let c = current, !c.href.isEmpty { entries.append(c) }
            current = nil
        default:
            break
        }
        collecting = nil
        text = ""
    }
}
