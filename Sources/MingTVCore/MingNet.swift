import Foundation

/// 统一网络出口.
/// Android 版 `OkHttpUtil.UA = "okhttp/3.15"` —— 大量接口对非 okhttp UA 返回 302/403,
/// iOS 版照搬该 UA, 否则接口与直播源会大面积失败.
public enum MingNet {

    public static let okhttpUA = "okhttp/3.15"

    public static let sharedUA =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    /// 发起 GET, 返回 (数据, 响应). URLSession 会自动处理 gzip 的 Content-Encoding.
    public static func get(_ urlString: String,
                           headers: [String: String] = [:],
                           timeout: TimeInterval = 15) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw CmsError.badURL(urlString)
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        // 默认 UA 使用 okhttp, 可被 headers 覆盖
        req.setValue(okhttpUA, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw CmsError.network("非 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CmsError.http(http.statusCode)
        }
        return (data, http)
    }

    /// 发起 GET 并解码为文本, 自动处理 .gz 文件
    public static func getText(_ urlString: String,
                               headers: [String: String] = [:],
                               timeout: TimeInterval = 15) async throws -> String {
        let (data, http) = try await get(urlString, headers: headers, timeout: timeout)
        var body = data
        let isGzip = urlString.lowercased().hasSuffix(".gz")
            || (http.value(forHTTPHeaderField: "Content-Type") ?? "").contains("gzip")
            || data.starts(with: [0x1f, 0x8b])
        if isGzip, let un = Gzip.inflate(data) { body = un }
        return String(data: body, encoding: .utf8)
            ?? String(data: body, encoding: .isoLatin1)
            ?? ""
    }

    /// 发起任意 HTTP 方法 (WebDAV 需要 PROPFIND)
    public static func request(_ urlString: String,
                               method: String,
                               headers: [String: String] = [:],
                               body: Data? = nil,
                               timeout: TimeInterval = 15) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw CmsError.badURL(urlString)
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout
        req.httpBody = body
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw CmsError.network("非 HTTP 响应")
        }
        return (data, http)
    }

    /// POST JSON, 返回解析后的字典 (AList 网盘接口)
    public static func postJSON(_ urlString: String,
                                body: [String: Any],
                                headers: [String: String] = [:],
                                timeout: TimeInterval = 15) async throws -> [String: Any] {
        let payload = try JSONSerialization.data(withJSONObject: body)
        var h = headers
        h["Content-Type"] = "application/json; charset=utf-8"
        if h["User-Agent"] == nil { h["User-Agent"] = okhttpUA }

        let (data, http) = try await request(urlString, method: "POST", headers: h, body: payload, timeout: timeout)
        guard (200..<300).contains(http.statusCode) else { throw CmsError.http(http.statusCode) }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let preview = String(data: data.prefix(120), encoding: .utf8) ?? "<binary>"
            throw CmsError.decode("返回非 JSON: \(preview)")
        }
        return obj
    }
}

/// gzip 解压 (直播源 / EPG 常见 .xml.gz / .m3u.gz)
public enum Gzip {
    /// 处理标准 gzip 容器: 跳过 10 字节文件头后按 raw DEFLATE 解压
    public static func inflate(_ data: Data) -> Data? {
        guard data.count > 18 else { return nil }
        // gzip 魔数
        guard data[data.startIndex] == 0x1f, data[data.startIndex + 1] == 0x8b else { return nil }
        var offset = 10
        let flg = data[data.startIndex + 3]
        // FEXTRA
        if flg & 0x04 != 0 {
            guard data.count > offset + 2 else { return nil }
            let xlen = Int(data[offset]) | (Int(data[offset + 1]) << 8)
            offset += 2 + xlen
        }
        // FNAME / FCOMMENT: 以 0 结尾
        if flg & 0x08 != 0 { while offset < data.count && data[offset] != 0 { offset += 1 }; offset += 1 }
        if flg & 0x10 != 0 { while offset < data.count && data[offset] != 0 { offset += 1 }; offset += 1 }
        guard offset < data.count else { return nil }
        let raw = data.subdata(in: offset..<data.count)
        return raw.inflateRawDeflate()
    }
}
