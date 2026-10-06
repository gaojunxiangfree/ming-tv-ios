import SwiftUI
import MingTVCore

/// 直播页 (对应 Android: LiveActivity)
struct LiveView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var model = LiveModel()

    var body: some View {
        ZStack {
            SM.bgGradient.ignoresSafeArea()

            VStack(spacing: 0) {
                TopBar(title: "直播", subtitle: model.status, onBack: { dismiss() })

                if model.loading && model.groups.isEmpty {
                    LoadingState(text: "正在加载直播源…")
                } else if let err = model.error, model.groups.isEmpty {
                    EmptyState(icon: "antenna.radiowaves.left.and.right", text: err, actionTitle: "重试") {
                        Task { await model.load(config: app.config) }
                    }
                } else {
                    videoArea
                    infoBar
                    if !model.todayPrograms.isEmpty { epgStrip }
                    groupRow
                    channelGrid
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .task { await model.load(config: app.config) }
        .onDisappear { model.stop() }
    }

    // MARK: - 视频

    private var videoArea: some View {
        ZStack {
            PlayerLayerView(player: model.player)
            if model.playError != nil || model.playingChannelName.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tv.slash")
                        .font(.system(size: 28))
                        .foregroundStyle(SM.textDim)
                    Text(model.playError ?? "选择一个频道开始播放")
                        .font(SMFont.small)
                        .foregroundStyle(SM.textDim)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .background(.black)
    }

    // MARK: - 频道信息

    private var infoBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(model.currentChannel?.name ?? "—")
                    .font(SMFont.title).foregroundStyle(SM.text)
                Spacer()
                Text("\(model.currentGroup?.name ?? "")")
                    .font(SMFont.tiny).foregroundStyle(SM.textDim)
            }
            HStack(spacing: 6) {
                Text("正在播")
                    .font(SMFont.tiny).foregroundStyle(SM.bg)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(SM.primary, in: Capsule())
                Text(model.currentProgram?.title ?? (model.epgLoading ? "节目单加载中…" : "暂无节目单"))
                    .font(SMFont.small).foregroundStyle(SM.text.opacity(0.9)).lineLimit(1)
            }
            if let next = model.nextProgram {
                Text("接下来 \(Self.timeText(next.start)) \(next.title)")
                    .font(SMFont.tiny).foregroundStyle(SM.textDim).lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - EPG 时间轴

    private var epgStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(model.todayPrograms.enumerated()), id: \.offset) { _, p in
                    let playing = p.isPlaying(at: Date())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.timeText(p.start))
                            .font(SMFont.tiny)
                            .foregroundStyle(playing ? SM.bg : SM.textDim)
                        Text(p.title)
                            .font(SMFont.tiny)
                            .foregroundStyle(playing ? SM.bg : SM.text)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(width: 132, alignment: .leading)
                    .background(playing ? AnyShapeStyle(SM.primary) : AnyShapeStyle(SM.surfaceLight),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 8)
    }

    // MARK: - 分组

    private var groupRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(model.groups.enumerated()), id: \.offset) { idx, g in
                    CapsuleButton(title: g.name, selected: idx == model.selectedGroupIndex) {
                        model.selectGroup(idx)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 8)
    }

    // MARK: - 频道列表

    private var channelGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 128, maximum: 180), spacing: 8)],
                      spacing: 8) {
                ForEach(Array((model.currentGroup?.channels ?? []).enumerated()), id: \.offset) { idx, ch in
                    let selected = idx == model.selectedChannelIndex
                    Button {
                        model.selectChannel(idx)
                    } label: {
                        HStack(spacing: 6) {
                            if let logo = ch.logo, !logo.isEmpty {
                                CachedAsyncImage(url: logo)
                                    .frame(width: 20, height: 20)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                            Text(ch.name)
                                .font(SMFont.tiny)
                                .foregroundStyle(selected ? SM.bg : SM.text)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 34)
                        .background(selected ? AnyShapeStyle(SM.primary) : AnyShapeStyle(SM.episodeBg),
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("channel-\(ch.name)")
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
    }

    private static func timeText(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}
