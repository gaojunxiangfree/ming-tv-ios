import SwiftUI
import MingTVCore

/// 直播页 (对应 Android: LiveActivity)
/// 双方向布局: 竖屏「视频在上 + 频道列表」, 横屏全屏播放。方向切换与播放页共用 OrientationHelper。
struct LiveView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var model = LiveModel()
    @State private var isLandscape = false
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geo in
            let portrait = geo.size.height >= geo.size.width
            ZStack {
                SM.bgGradient.ignoresSafeArea()
                if portrait { portraitLayout } else { landscapeLayout }
            }
            .onAppear { isLandscape = !portrait }
            .onChange(of: portrait) { _, nowPortrait in isLandscape = !nowPortrait }
        }
        .statusBarHidden(isLandscape)
        .toolbar(.hidden, for: .navigationBar)
        .task { await model.load(config: app.config) }
        .onDisappear {
            hideTask?.cancel()
            model.stop()
            // 退出直播页后放开方向限制, 恢复自由旋转
            OrientationHelper.restoreFreeRotation()
        }
    }

    // MARK: - 竖屏

    private var portraitLayout: some View {
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

            // 右下角全屏键 (与播放页位置一致, 便于发现)
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    RoundIconButton(symbol: "arrow.up.left.and.arrow.down.right",
                                    id: "live-enter-fullscreen", size: 36) {
                        model.showControls = true
                        scheduleAutoHide()
                        OrientationHelper.enterLandscape()
                    }
                }
            }
            .padding(10)
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .background(.black)
    }

    // MARK: - 横屏全屏

    private var landscapeLayout: some View {
        ZStack {
            PlayerLayerView(player: model.player)
                .ignoresSafeArea()

            if model.playError != nil || model.playingChannelName.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tv.slash")
                        .font(.system(size: 30))
                        .foregroundStyle(.white.opacity(0.85))
                    Text(model.playError ?? "选择一个频道开始播放")
                        .font(SMFont.small)
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                }
                .padding(16)
            }

            // 点击层垫在视频之上、控件之下 (ZStack 里后面的视图盖在上面)
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { toggleControls() }

            if model.showControls {
                // 这层压暗色也会挡住下面的点击层, 所以自己接一次点击
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { toggleControls() }
                landscapeBottomBar
            }

            // 顶部条常驻: 控制层收起后也要能找到「收起」键
            VStack {
                landscapeTopBar
                Spacer()
            }
        }
    }

    private var landscapeTopBar: some View {
        HStack(spacing: 10) {
            RoundIconButton(symbol: "arrow.down.right.and.arrow.up.left",
                            id: "live-exit-fullscreen") {
                OrientationHelper.enterPortrait()
            }
            RoundIconButton(symbol: "xmark", id: "live-close") { dismiss() }

            VStack(alignment: .leading, spacing: 2) {
                Text(model.currentChannel?.name ?? "直播")
                    .font(SMFont.small).foregroundStyle(.white).lineLimit(1)
                Text(model.currentGroup?.name ?? "")
                    .font(SMFont.tiny).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
    }

    private var landscapeBottomBar: some View {
        VStack {
            Spacer()
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    landscapePill("上一台", "backward.end.fill") { model.stepChannel(-1) }
                    landscapePill("下一台", "forward.end.fill") { model.stepChannel(1) }
                    Spacer(minLength: 8)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(model.groups.enumerated()), id: \.offset) { idx, g in
                            groupChip(idx, g)
                        }
                    }
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array((model.currentGroup?.channels ?? []).enumerated()), id: \.offset) { idx, ch in
                            channelChip(idx, ch, width: 132)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
    }

    private func landscapePill(_ title: String, _ icon: String,
                               action: @escaping () -> Void) -> some View {
        Button {
            scheduleAutoHide()
            action()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 12))
                Text(title).font(SMFont.tiny)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.black.opacity(0.4), in: Capsule())
        }
        .buttonStyle(.plain)
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
                    groupChip(idx, g)
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 8)
    }

    private func groupChip(_ idx: Int, _ g: LiveGroup) -> some View {
        CapsuleButton(title: g.name, selected: idx == model.selectedGroupIndex) {
            model.selectGroup(idx)
        }
    }

    // MARK: - 频道列表

    private var channelGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 128, maximum: 180), spacing: 8)],
                      spacing: 8) {
                ForEach(Array((model.currentGroup?.channels ?? []).enumerated()), id: \.offset) { idx, ch in
                    channelChip(idx, ch, width: nil)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
    }

    /// 频道按钮。`width` 传 nil 时宽度交给外层网格决定 (竖屏网格), 传固定值用于横屏横滑条。
    private func channelChip(_ idx: Int, _ ch: LiveChannel, width: CGFloat?) -> some View {
        let selected = idx == model.selectedChannelIndex
        return Button {
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
            .frame(width: width, height: 34)
            .background(selected ? AnyShapeStyle(SM.primary) : AnyShapeStyle(SM.episodeBg),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("channel-\(ch.name)")
    }

    // MARK: - 控制层显隐

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) { model.showControls.toggle() }
        scheduleAutoHide()
    }

    private func scheduleAutoHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if Task.isCancelled { return }
            withAnimation(.easeInOut(duration: 0.25)) { model.showControls = false }
        }
    }

    private static func timeText(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}
