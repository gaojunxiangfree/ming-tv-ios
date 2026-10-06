import SwiftUI
import MingTVCore

/// 播放页 (对应 Android: PlayActivity)
/// 双方向布局: 竖屏「视频在上、选集在下」, 横屏全屏播放.
struct PlayerView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    let target: PlayTarget
    let onSwitch: (PlayTarget) -> Void

    @State private var model = PlayerModel()
    @State private var showEpisodes = false
    @State private var showAudioPicker = false
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubbing: Double?

    /// 音轨按钮文案: 未选择时只显示"音轨"
    private var audioTitle: String {
        guard let idx = model.selectedAudioIndex, model.audioTracks.indices.contains(idx) else { return "音轨" }
        return "音轨 \(model.audioTracks[idx].label)"
    }

    var body: some View {
        GeometryReader { geo in
            let portrait = geo.size.height >= geo.size.width
            Group {
                if portrait { portraitLayout(geo) } else { landscapeLayout(geo) }
            }
                .background { Color.black.ignoresSafeArea() }
        }
        .statusBarHidden()
        .task {
            await model.start(target: target,
                              site: app.site(for: target.siteKey),
                              config: app.config,
                              speed: app.playSpeed,
                              loop: app.loopEnabled,
                              adFilterEnabled: app.adFilterEnabled)
            scheduleAutoHide()
        }
        .sheet(isPresented: $showAudioPicker) { audioPicker }
        .onDisappear {
            hideTask?.cancel()
            saveHistory()
            model.stop()
            // 退出播放页后放开方向限制, 恢复自由旋转
            OrientationHelper.restoreFreeRotation()
        }
    }

    // MARK: - 竖屏: 视频在上, 选集在下

    private func portraitLayout(_ geo: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            ZStack {
                PlayerLayerView(player: model.player)
                portraitVideoOverlay
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .background(.black)

            portraitInfo
            episodeList
        }
        .background(SM.bgGradient.ignoresSafeArea())
    }

    private var portraitInfo: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(model.title)
                    .font(SMFont.title).foregroundStyle(SM.text).lineLimit(1)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(SM.text)
                        .frame(width: 30, height: 30)
                        .background(SM.surfaceLight, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("player-close")
            }

            Text(model.currentEpisodeName)
                .font(SMFont.small).foregroundStyle(SM.primary)

            if let notice = model.adFilterNotice {
                Text(notice)
                    .font(SMFont.tiny)
                    .foregroundStyle(SM.gold)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    CapsuleButton(title: audioTitle, systemIcon: "waveform") { showAudioPicker = true }
                    CapsuleButton(title: "倍速 \(formatSpeed(model.speed))", systemIcon: "speedometer") { cycleSpeed() }
                    CapsuleButton(title: "−10s", systemIcon: "gobackward.10") { model.seek(by: -10) }
                    CapsuleButton(title: "+10s", systemIcon: "goforward.10") { model.seek(by: 10) }
                    CapsuleButton(title: model.loopEnabled ? "循环开" : "循环关",
                                  systemIcon: "repeat",
                                  selected: model.loopEnabled) {
                        model.loopEnabled.toggle()
                        app.loopEnabled = model.loopEnabled
                    }
                    CapsuleButton(title: "刷新", systemIcon: "arrow.clockwise") { model.reload() }
                }
            }
            .padding(.top, 4)
        }
        .padding(16)
    }

    private var episodeList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("选集 (\(model.episodes.count))")
                .font(SMFont.title).foregroundStyle(SM.text)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 76, maximum: 130), spacing: 8)],
                          spacing: 8) {
                    ForEach(Array(model.episodes.enumerated()), id: \.offset) { idx, ep in
                        EpisodeChip(title: ep.title, selected: idx == model.index) {
                            model.jump(to: idx)
                            saveHistory()
                        }
                    }
                }
                .padding(.bottom, 20)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SM.surface.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    // MARK: - 横屏: 全屏

    private func landscapeLayout(_ geo: GeometryProxy) -> some View {
        ZStack {
            PlayerLayerView(player: model.player)
                .ignoresSafeArea()
            // 点击层只垫在视频上方、按钮下方: 避免容器手势把顶部按钮的点击吞掉
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { toggleControls() }
            VStack {
                landscapeTopBar
                Spacer()
            }
            controlsOverlay()
            if showEpisodes {
                episodeDrawer
            }
        }
    }

    // MARK: - 竖屏控制层 (对齐爱奇艺/腾讯视频: 左上关闭、中央播放、右下全屏键)

    private var portraitVideoOverlay: some View {
        ZStack {
            Color.black.opacity(model.showControls ? 0.22 : 0)

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    if model.showControls {
                        roundButton("xmark", id: "player-close", size: 32) { dismiss() }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)

                Spacer(minLength: 0)

                if model.isLoading {
                    ProgressView().tint(.white)
                } else if let err = model.errorText {
                    VStack(spacing: 6) {
                        Text(err)
                            .font(SMFont.tiny).foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                        Button("重试") { model.reload() }
                            .font(SMFont.tiny).foregroundStyle(SM.primary)
                    }
                    .padding(.horizontal, 16)
                } else if model.showControls {
                    Button { model.togglePlay() } label: {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 54, height: 54)
                            .background(.black.opacity(0.32), in: Circle())
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 0)

                // 底部进度条常驻 + 右下角全屏键 (竖屏下也一直可见, 保证可发现)
                HStack(spacing: 8) {
                    Text(timeText(model.position)).font(SMFont.tiny).foregroundStyle(.white)
                    Slider(value: Binding(
                        get: { scrubbing ?? model.position },
                        set: { scrubbing = $0 }
                    ), in: 0...max(model.duration, 1), onEditingChanged: { editing in
                        if !editing, let v = scrubbing { model.seek(to: v); scrubbing = nil }
                    })
                    .tint(SM.primary)
                    Text(timeText(model.duration)).font(SMFont.tiny).foregroundStyle(.white)

                    roundButton("arrow.up.left.and.arrow.down.right",
                                id: "player-enter-fullscreen", size: 32) {
                        // 转横屏后把控制层显示出来并重置自动隐藏计时
                        model.showControls = true
                        scheduleAutoHide()
                        OrientationHelper.enterLandscape()
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.showControls)
    }

    private func roundButton(_ symbol: String, id: String,
                             size: CGFloat = 34, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(.black.opacity(0.35), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    // MARK: - 横屏控制层

    @ViewBuilder
    private func controlsOverlay() -> some View {
        if model.showControls || model.isLoading || model.errorText != nil {
            ZStack {
                Color.black.opacity(0.28).ignoresSafeArea()

                VStack {
                    Spacer()

                    if model.isLoading {
                        ProgressView().tint(.white).scaleEffect(1.2)
                    } else if let err = model.errorText {
                        VStack(spacing: 8) {
                            Text(err).font(SMFont.small).foregroundStyle(.white)
                            Button("重试") { model.reload() }
                                .font(SMFont.small).foregroundStyle(SM.primary)
                        }
                    } else {
                        Button { model.togglePlay() } label: {
                            Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 30, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 66, height: 66)
                                .background(.black.opacity(0.4), in: Circle())
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer()
                    bottomControls()
                }
            }
            .transition(.opacity)
        }
    }

    /// 横屏顶部条: 退出全屏 / 关闭 / 标题 —— 常驻显示(对齐爱奇艺, 避免控制层隐藏后找不到返回键)
    private var landscapeTopBar: some View {
        HStack(spacing: 10) {
            roundButton("arrow.down.right.and.arrow.up.left",
                        id: "player-exit-fullscreen") {
                OrientationHelper.enterPortrait()
            }
            roundButton("xmark", id: "player-close") { dismiss() }

            VStack(alignment: .leading, spacing: 2) {
                Text(model.title).font(SMFont.small).foregroundStyle(.white).lineLimit(1)
                Text(model.currentEpisodeName)
                    .font(SMFont.tiny).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
    }

    private func bottomControls() -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text(timeText(model.position)).font(SMFont.tiny).foregroundStyle(.white)
                Slider(value: Binding(
                    get: { scrubbing ?? model.position },
                    set: { scrubbing = $0 }
                ), in: 0...max(model.duration, 1), onEditingChanged: { editing in
                    if !editing, let v = scrubbing { model.seek(to: v); scrubbing = nil }
                })
                .tint(SM.primary)
                Text(timeText(model.duration)).font(SMFont.tiny).foregroundStyle(.white)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    pill("上一集", "backward.end.fill", enabled: model.hasPrev) { saveHistory(); model.prev() }
                    pill("−10s", "gobackward.10") { model.seek(by: -10) }
                    pill("+10s", "goforward.10") { model.seek(by: 10) }
                    pill("下一集", "forward.end.fill", enabled: model.hasNext) { saveHistory(); model.next() }
                    pill("选集 \(model.index + 1)/\(model.episodes.count)", "list.bullet") {
                        withAnimation { showEpisodes.toggle() }
                    }
                    pill(audioTitle, "waveform") { showAudioPicker = true }
                    pill("倍速 \(formatSpeed(model.speed))", "speedometer") { cycleSpeed() }
                    pill(model.loopEnabled ? "循环开" : "循环关", "repeat",
                         highlighted: model.loopEnabled) {
                        model.loopEnabled.toggle(); app.loopEnabled = model.loopEnabled
                    }
                    pill("刷新", "arrow.clockwise") { model.reload() }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
    }

    private func pill(_ title: String, _ icon: String, enabled: Bool = true,
                      highlighted: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            scheduleAutoHide()
            action()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 12))
                Text(title).font(SMFont.tiny)
            }
            .foregroundStyle(highlighted ? SM.bg : (enabled ? .white : Color.white.opacity(0.4)))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(highlighted ? AnyShapeStyle(SM.primary) : AnyShapeStyle(.black.opacity(0.4)),
                        in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: - 选集抽屉 (横屏)

    private var episodeDrawer: some View {
        VStack {
            Spacer()
            VStack(spacing: 12) {
                HStack {
                    Text("选集 (\(model.episodes.count))")
                        .font(SMFont.title).foregroundStyle(SM.text)
                    Spacer()
                    Button { withAnimation { showEpisodes = false } } label: {
                        Image(systemName: "chevron.down").foregroundStyle(SM.textDim)
                    }
                    .buttonStyle(.plain)
                }
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 76, maximum: 130), spacing: 8)],
                              spacing: 8) {
                        ForEach(Array(model.episodes.enumerated()), id: \.offset) { idx, ep in
                            EpisodeChip(title: ep.title, selected: idx == model.index) {
                                saveHistory()
                                model.jump(to: idx)
                                withAnimation { showEpisodes = false }
                            }
                        }
                    }
                    .padding(.bottom, 12)
                }
                .frame(maxHeight: 220)
            }
            .padding(16)
            .background(SM.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(12)
        }
        .transition(.move(edge: .bottom))
    }

    // MARK: - 音轨选择 (对应 Android: PlayerActivity.showAudioTrackDialog)

    private var audioPicker: some View {
        NavigationStack {
            ZStack {
                SM.bg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if model.audioTracks.isEmpty {
                            Text("该片源没有可选音轨，或音轨信息尚未解析完成。")
                                .font(SMFont.small)
                                .foregroundStyle(SM.textDim)
                                .padding(.top, 20)
                        } else {
                            audioRow(title: "默认（自动）", selected: model.selectedAudioIndex == nil) {
                                model.selectAudioTrack(nil)
                                showAudioPicker = false
                            }
                            ForEach(model.audioTracks) { track in
                                audioRow(title: track.label,
                                         selected: model.selectedAudioIndex == track.index) {
                                    model.selectAudioTrack(track.index)
                                    showAudioPicker = false
                                }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(16)
                }
            }
            .navigationTitle("选择音轨")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { showAudioPicker = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func audioRow(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(SMFont.body).foregroundStyle(SM.text)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SM.primary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(selected ? SM.surfaceLight : SM.surface,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("audio-\(title)")
    }

    // MARK: - 辅助

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

    private func cycleSpeed() {
        let all = PlayerModel.speeds
        let idx = all.firstIndex(where: { abs($0 - model.speed) < 0.001 }) ?? 2
        let next = all[(idx + 1) % all.count]
        model.applySpeed(next)
        app.playSpeed = next
        scheduleAutoHide()
    }

    private func saveHistory() {
        guard let vod = currentVod else { return }
        app.recordHistory(siteKey: target.siteKey,
                          vod: vod,
                          flag: model.lineFlag,
                          episodeIndex: model.index,
                          episodeName: model.currentEpisodeName,
                          position: model.position,
                          duration: model.duration)
    }

    private var currentVod: Vod? { target.vod }

    private func timeText(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "00:00" }
        let total = Int(s)
        let h = total / 3600, m = (total % 3600) / 60, sec = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }

    private func formatSpeed(_ s: Double) -> String {
        s == floor(s) ? "\(Int(s))x" : String(format: "%.2gx", s)
    }
}
