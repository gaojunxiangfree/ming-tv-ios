import SwiftUI
import MingTVCore

/// 详情页 (对应 Android: DetailActivity)
struct DetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass

    let ref: VodRef
    let onPlay: (PlayTarget) -> Void

    @State private var model = DetailModel()

    private var site: Site? { app.site(for: ref.siteKey) }
    private var isWide: Bool { sizeClass == .regular }

    var body: some View {
        ZStack {
            SM.bgGradient.ignoresSafeArea()

            VStack(spacing: 0) {
                TopBar(title: ref.name, subtitle: site?.name, onBack: { dismiss() })
                content
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .task { await load() }
    }

    private func load() async {
        guard let site else {
            model.fail("站点不存在")
            return
        }
        let record = app.historyRecord(vodId: ref.vodId, siteKey: ref.siteKey)
        await model.load(ref: ref, site: site, preferredFlag: record?.flag)
    }

    @ViewBuilder
    private var content: some View {
        if model.loading && model.vod == nil {
            LoadingState(text: "正在获取详情…")
        } else if let err = model.error, model.vod == nil {
            EmptyState(icon: "exclamationmark.triangle", text: err, actionTitle: "重试") {
                Task { await load() }
            }
        } else if let vod = model.vod {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    hero(vod)
                    actionRow(vod)
                    if !model.lines.isEmpty { episodeSection(vod) }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 30)
            }
        }
    }

    // MARK: - 海报 + 简介

    @ViewBuilder
    private func hero(_ vod: Vod) -> some View {
        let poster = CachedAsyncImage(url: vod.pic)
            .frame(width: isWide ? 200 : 132, height: isWide ? 300 : 198)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

        let info = VStack(alignment: .leading, spacing: 8) {
            Text(vod.name)
                .font(SMFont.pageTitle)
                .foregroundStyle(SM.text)

            let meta = [vod.year, vod.area, vod.director.isEmpty ? "" : "导演 \(vod.director)"]
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
            if !meta.isEmpty {
                Text(meta).font(SMFont.small).foregroundStyle(SM.textDim)
            }

            if !vod.actor.isEmpty {
                Text("主演 \(vod.actor)")
                    .font(SMFont.small)
                    .foregroundStyle(SM.textDim)
                    .lineLimit(2)
            }

            Text(vod.content.isEmpty ? "暂无简介" : vod.content)
                .font(SMFont.small)
                .foregroundStyle(SM.text.opacity(0.86))
                .lineLimit(model.contentExpanded ? nil : 5)
                .animation(.easeInOut(duration: 0.2), value: model.contentExpanded)

            if !vod.content.isEmpty {
                Button(model.contentExpanded ? "收起" : "展开全部") {
                    model.contentExpanded.toggle()
                }
                .font(SMFont.tiny)
                .foregroundStyle(SM.primary)
            }

            Spacer(minLength: 0)
        }

        if isWide {
            HStack(alignment: .top, spacing: 18) { poster; info }
        } else {
            HStack(alignment: .top, spacing: 14) { poster; info }
        }
    }

    // MARK: - 操作行

    @ViewBuilder
    private func actionRow(_ vod: Vod) -> some View {
        HStack(spacing: 10) {
            Button {
                play(from: 0)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill")
                    Text("播放").font(SMFont.body.weight(.semibold))
                }
                .foregroundStyle(SM.bg)
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
                .background(SM.accentGradient, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("detail-play")

            CapsuleButton(title: app.isFavorite(vodId: vod.id, siteKey: ref.siteKey) ? "已收藏" : "收藏",
                          icon: "⭐",
                          selected: app.isFavorite(vodId: vod.id, siteKey: ref.siteKey)) {
                app.toggleFavorite(vod: vod, siteKey: ref.siteKey)
            }

            CapsuleButton(title: "倒序", systemIcon: "arrow.up.arrow.down", selected: model.reversed) {
                model.reversed.toggle()
                model.rangeIndex = 0
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - 选集

    @ViewBuilder
    private func episodeSection(_ vod: Vod) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.lines.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(model.lines.enumerated()), id: \.offset) { idx, line in
                            CapsuleButton(title: line.flag,
                                          selected: idx == model.selectedLineIndex) {
                                model.selectLine(idx)
                            }
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                Text("选集").font(SMFont.title).foregroundStyle(SM.text)
                Text("\(model.episodes.count) 集")
                    .font(SMFont.tiny).foregroundStyle(SM.textDim)
                Spacer()
            }

            // 分段收纳 (>30 集时按区间分页, 与 Android EPISODE_RANGE_SIZE 一致)
            if model.rangeCount > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(0..<model.rangeCount, id: \.self) { r in
                            let from = r * DetailModel.rangeSize + 1
                            let to = min((r + 1) * DetailModel.rangeSize, model.episodes.count)
                            CapsuleButton(title: "\(from)-\(to)", selected: r == model.rangeIndex) {
                                model.rangeIndex = r
                            }
                        }
                    }
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 76, maximum: 130), spacing: 8)],
                      spacing: 8) {
                ForEach(Array(model.pagedEpisodes.enumerated()), id: \.offset) { idx, ep in
                    EpisodeChip(title: ep.title) {
                        let absolute = model.reversed
                            ? model.episodes.count - 1 - (model.rangeIndex * DetailModel.rangeSize + idx)
                            : model.rangeIndex * DetailModel.rangeSize + idx
                        play(from: absolute)
                    }
                }
            }
        }
    }

    // MARK: - 播放

    private func play(from index: Int) {
        guard let vod = model.vod, let line = model.currentLine else { return }
        let record = app.historyRecord(vodId: ref.vodId, siteKey: ref.siteKey)
        let start = (record?.flag == line.flag) ? (record?.position ?? 0) : 0
        onPlay(PlayTarget(siteKey: ref.siteKey,
                          vod: vod,
                          line: line,
                          startIndex: index,
                          startPosition: start))
    }
}
