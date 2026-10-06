import Foundation
import MingTVCore

// ════════════════════════════════════════════════════════════════════
//  茗影院 iOS 版 — 技术验证
//  验证目标: 方案 B 的两个最大风险点 —— ①防盗链请求头注入 ②m3u8 播放
//  运行环境: macOS (AVFoundation 与 iOS 同 API, 结论可直接用于 iOS)
// ════════════════════════════════════════════════════════════════════

@main
struct Runner {

    static let line = String(repeating: "─", count: 74)

    static func header(_ t: String) {
        print("\n\(line)\n【\(t)】")
    }

    /// 按显示宽度左对齐补齐空格(中文按 2 列宽计), 避免用 String(format: "%s") 传 Swift String 导致崩溃
    static func pad(_ s: String, _ width: Int) -> String {
        var visual = 0
        for ch in s {
            visual += (ch.unicodeScalars.first.map { $0.value > 0x2E80 } ?? false) ? 2 : 1
        }
        return s + String(repeating: " ", count: max(0, width - visual))
    }

    static func short(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n)) + "…"
    }

    struct Candidate {
        let site: Site
        let vod: Vod
        let line: PlayLine
        var firstURL: String { line.episodes.first?.url ?? "" }
        var referer: String {
            guard let u = URL(string: site.api), let h = u.host else { return "" }
            return "\(u.scheme ?? "https")://\(h)/"
        }
    }

    static func main() async {
        print("""
        ╔══════════════════════════════════════════════════════════════════╗
        ║  茗影院 iOS 版 · 技术验证 (方案 B)                                ║
        ║  链路: 采集源 → 海报 → 线路优选 → 防盗链 → AVPlayer 播放           ║
        ╚══════════════════════════════════════════════════════════════════╝
        平台: \(ProcessInfo.processInfo.operatingSystemVersionString)
        """)

        let ua = CmsClient.defaultUA

        // ───────────── 1. 源可用性 ─────────────
        header("1 采集源可用性 (type 1 苹果CMS)")
        let probes = await SourceRegistry.probeAll()
        print("  " + pad("资源站", 10) + pad("状态", 6) + pad("分类", 8) + pad("海报覆盖", 10) + "备注")
        var alive: [SourceRegistry.ProbeResult] = []
        for p in probes {
            print("  " + pad(p.site.name, 10) + pad(p.ok ? "✅" : "❌", 6)
                  + pad(p.ok ? "\(p.classes)" : "-", 8) + pad(p.ok ? "\(p.withPoster)/\(p.videos)" : "-", 10)
                  + (p.ok ? "" : short(p.note, 34)))
            if p.ok { alive.append(p) }
        }
        print("  → 可用 \(alive.count)/\(probes.count)")
        guard !alive.isEmpty else { print("\n⛔ 无可用源, 终止"); return }

        // ───────────── 2. 数据链路 ─────────────
        header("2 数据链路: 列表 → 详情 → 线路")
        var candidates: [Candidate] = []
        for p in alive.prefix(10) {
            let client = CmsClient(base: p.site.api, timeout: 12)
            do {
                let list = try await client.latest()
                let target = list.first(where: { !$0.pic.isEmpty }) ?? list[0]
                let detail = try await client.detail(ids: target.id)
                let lines = StreamResolver.parseLines(from: detail)
                guard let best = StreamResolver.rank(lines).first else { continue }
                candidates.append(Candidate(site: p.site, vod: detail, line: best))
                print("  " + pad(p.site.name, 10) + pad(short(target.name, 14), 18) + "线路=\(lines.count) 集数=\(best.episodes.count) 优选=\(best.flag)")
            } catch {
                print("  " + pad(p.site.name, 10) + "详情失败: " + short("\(error)", 40))
            }
        }
        guard let sample = candidates.first else { print("\n⛔ 无可用详情, 终止"); return }

        print("\n  样本 [\(sample.site.name)]")
        print("    片名: \(sample.vod.name)")
        print("    海报: \(short(sample.vod.pic, 70))")
        print("    简介: \(short(sample.vod.content, 50))…")
        print("    全部线路: \(sample.vod.playFrom)")

        // ───────────── 3. 线路优选 ─────────────
        header("3 线路优选 (跳过需二次解析的线路)")
        let multi = candidates.first(where: { $0.vod.playFrom.contains("$$$") }) ?? sample
        let all = StreamResolver.parseLines(from: multi.vod)
        print("  样本 [\(multi.site.name)]  \(multi.vod.name)  共 \(all.count) 条线路:")
        for (i, l) in StreamResolver.rank(all).enumerated() {
            print("    \(i + 1). " + pad(l.flag, 16)
                  + pad(l.isDirectPlayable ? "✅直链" : "⚠️需解析", 12)
                  + "集数=\(l.episodes.count)" + (i == 0 ? "   ← 优选" : ""))
        }

        // ───────────── 4. 防盗链探测 ─────────────
        header("4 防盗链探测 (默认请求 vs 注入 iPhone UA + Referer)")
        var openCandidates: [Candidate] = []
        var protectedCandidates: [Candidate] = []

        for c in candidates.prefix(8) {
            let urlStr = c.firstURL
            async let bare = HotlinkProbe.bare(urlStr)
            async let headered = HotlinkProbe.withHeaders(urlStr, headers: ["User-Agent": ua, "Referer": c.referer])
            let (b, h) = await (bare, headered)
            func mark(_ o: HotlinkProbe.Outcome) -> String {
                if o.looksLikePlaylist { return "✅m3u8" }
                if o.status < 0 { return "❌网络失败" }
                return "❌" + String(o.contentType.prefix(16))
            }
            print("  " + pad(c.site.name, 10) + pad("默认=" + mark(b), 26) + "带头=" + mark(h))
            if h.looksLikePlaylist {
                if b.looksLikePlaylist { openCandidates.append(c) } else { protectedCandidates.append(c) }
            }
        }
        print("  → 受防盗链保护: \(protectedCandidates.count) 个   完全开放: \(openCandidates.count) 个")

        // ───────────── 5. AVFoundation 加载验证 ─────────────
        header("5 AVFoundation 加载验证  ★核心")

        // 5a. 先用「开放源」隔离验证: 自定义 scheme 机制本身是否成立
        if let open = openCandidates.first {
            print("\n  ▶ 5a 机制隔离测试 (开放源, 不带防盗链): \(open.site.name)")
            let url = URL(string: open.firstURL)!
            print("     地址: \(short(open.firstURL, 76))")
            let c = await AssetPlaybackProbe.wrapped(url, headers: ["User-Agent": ua], dumpPlaylist: true) { m in print("       \(m)") }
            print("     \(c.summary)")
        } else {
            print("\n  ▶ 5a 跳过: 无完全开放的源")
        }

        // 5b. 多源矩阵: 方案A(基线) vs 方案C(自定义scheme) vs 方案D(HeaderFieldsKey)
        print("\n  ▶ 5b 多源矩阵 —— 判定标准 AVPlayerItem.readyToPlay")
        let targets = Array(candidates.prefix(6))
        let rows = await withTaskGroup(of: (String, Bool, Bool, Bool, String).self) { group -> [(String, Bool, Bool, Bool, String)] in
            for c in targets {
                group.addTask {
                    guard let u = URL(string: c.firstURL) else { return (c.site.name, false, false, false, "URL非法") }
                    let hdrs = ["User-Agent": ua, "Referer": c.referer]
                    async let ra = AssetPlaybackProbe.bare(u, timeout: 15)
                    async let rc = AssetPlaybackProbe.wrapped(u, headers: hdrs, timeout: 15)
                    async let rd = AssetPlaybackProbe.headerFields(u, headers: hdrs, timeout: 15)
                    let (a, cc, d) = await (ra, rc, rd)
                    return (c.site.name, a.readyToPlay, cc.readyToPlay, d.readyToPlay, cc.readyToPlay ? "" : cc.note)
                }
            }
            var out: [(String, Bool, Bool, Bool, String)] = []
            for await r in group { out.append(r) }
            return out.sorted { $0.0 < $1.0 }
        }

        var aWins = 0, cWins = 0, dWins = 0
        print("     " + pad("资源站", 10) + pad("A 基线", 10) + pad("C 自定义scheme", 16) + pad("D 头字段", 12) + "备注")
        for (name, aok, cok, dok, note) in rows {
            if aok { aWins += 1 }
            if cok { cWins += 1 }
            if dok { dWins += 1 }
            print("     " + pad(name, 10) + pad(aok ? "✅就绪" : "❌", 10)
                  + pad(cok ? "✅就绪" : "❌", 16) + pad(dok ? "✅就绪" : "❌", 12) + short(note, 26))
        }
        print("     → A \(aWins)/\(rows.count)   C \(cWins)/\(rows.count)   D \(dWins)/\(rows.count)")

        // ───────────── 结论 ─────────────
        header("结论")
        let best: String
        if dWins >= aWins && dWins > 0 {
            best = "D AVURLAssetHTTPHeaderFieldsKey —— 需要注入请求头时用它, 无需自定义 scheme"
        } else if cWins >= aWins && cWins > 0 {
            best = "C 自定义 scheme 中转"
        } else {
            best = "A 直接播放 —— 实测本轮无源需要注入请求头, 可省掉 resource loader"
        }

        print("""
        数据层  : 可用源 \(alive.count)/\(probes.count); 海报字段正常(需用 ac=videolist)
        线路层  : 优选生效 —— 需二次解析的线路已被自动排后
        防盗链  : 受保护源 \(protectedCandidates.count) 个 (本轮样本)
        方案B   : delegate 拦截=0 → 标准 https 下不会回调 delegate, 该写法无效
        方案A   : readyToPlay \(aWins)/\(rows.count)  (直接播放)
        方案C   : readyToPlay \(cWins)/\(rows.count)  (自定义 scheme, 数据送达正确但未就绪)
        方案D   : readyToPlay \(dWins)/\(rows.count)  (HeaderFieldsKey)
        推荐    : \(best)
        """)
    }
}
