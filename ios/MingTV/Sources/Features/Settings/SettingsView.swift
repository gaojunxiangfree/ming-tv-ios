import SwiftUI
import MingTVCore

/// 设置页 (对应 Android: SettingsActivity)
struct SettingsView: View {
    @Environment(AppModel.self) private var appEnv
    @Environment(\.dismiss) private var dismiss

    @State private var apiInput = ""
    @State private var loadMessage: String?
    @State private var loading = false

    var body: some View {
        ZStack {
            SM.bgGradient.ignoresSafeArea()
            VStack(spacing: 0) {
                TopBar(title: "设置", onBack: { dismiss() })
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        apiSection(appEnv)
                        sourceSection(appEnv)
                        playSection(appEnv)
                        dataSection(appEnv)
                        splashSection(appEnv)
                        aboutSection
                    }
                    .padding(16)
                    .padding(.bottom, 30)
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { apiInput = appEnv.apiURL }
    }

    // MARK: - 接口配置

    private func apiSection(_ app: AppModel) -> some View {
        section("接口配置") {
            HStack(spacing: 10) {
                TextField("https://… 接口地址", text: $apiInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .foregroundStyle(SM.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(SM.surfaceLight, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                Button(loading ? "加载中…" : "加载") {
                    Task {
                        loading = true
                        let ok = await app.loadConfig(from: apiInput)
                        loadMessage = ok
                            ? "加载成功，共 \(app.sites.count) 个可用源"
                            : (app.configError ?? "加载失败")
                        loading = false
                    }
                }
                .font(SMFont.small.weight(.semibold))
                .foregroundStyle(SM.bg)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(SM.accentGradient, in: Capsule())
                .buttonStyle(.plain)
                .disabled(loading)
            }

            if let msg = loadMessage {
                Text(msg)
                    .font(SMFont.tiny)
                    .foregroundStyle(msg.contains("成功") ? SM.primary : Color(hex: 0xFF8A8A))
            }

            Text("iOS 版仅支持苹果CMS 采集源 (type 0/1)。jar / drpy 爬虫源依赖 Android 运行时，无法在 iOS 上运行。")
                .font(SMFont.tiny)
                .foregroundStyle(SM.textDim)
        }
    }

    // MARK: - 源管理

    private func sourceSection(_ app: AppModel) -> some View {
        section("接口源 (\(app.sites.count))") {
            if app.apiSources.isEmpty {
                Text("当前使用内置的 \(app.sites.count) 个已验证源")
                    .font(SMFont.tiny).foregroundStyle(SM.textDim)
            } else {
                ForEach(app.apiSources, id: \.self) { url in
                    HStack {
                        Text(url)
                            .font(SMFont.tiny)
                            .foregroundStyle(url == app.apiURL ? SM.primary : SM.textDim)
                            .lineLimit(1)
                        Spacer()
                        Button {
                            app.removeAPISource(url)
                        } label: {
                            Image(systemName: "trash").font(.system(size: 12)).foregroundStyle(SM.textDim)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Divider().overlay(SM.divider)

            Text("可用站点（点击切换首页线路）").font(SMFont.tiny).foregroundStyle(SM.textDim)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110, maximum: 200), spacing: 8)], spacing: 8) {
                ForEach(app.sites, id: \.key) { site in
                    CapsuleButton(title: site.name, selected: site.key == app.currentSiteKey) {
                        app.selectSite(site.key)
                    }
                }
            }
        }
    }

    // MARK: - 播放设置

    private func playSection(_ model: AppModel) -> some View {
        @Bindable var app = model
        return section("播放设置") {
            HStack {
                Text("默认倍速").font(SMFont.small).foregroundStyle(SM.text)
                Spacer()
                Picker("", selection: $app.playSpeed) {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { s in
                        Text(s == floor(s) ? "\(Int(s))x" : "\(s)x").tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
            }

            Toggle(isOn: $app.loopEnabled) {
                Text("循环播放").font(SMFont.small).foregroundStyle(SM.text)
            }
            .tint(SM.primary)

            Toggle(isOn: $app.adFilterEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("m3u8 去广告").font(SMFont.small).foregroundStyle(SM.text)
                    Text("过滤 SCTE-35 广告区间与广告分片；多码率主列表不改写")
                        .font(SMFont.tiny).foregroundStyle(SM.textDim)
                }
            }
            .tint(SM.primary)

            HStack {
                Text("选集布局").font(SMFont.small).foregroundStyle(SM.text)
                Spacer()
                Picker("", selection: $app.playlistLayout) {
                    Text("网格").tag("grid")
                    Text("列表").tag("column")
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200)
            }
        }
    }

    // MARK: - 数据

    private func dataSection(_ app: AppModel) -> some View {
        section("数据管理") {
            HStack(spacing: 10) {
                CapsuleButton(title: "清空搜索历史 (\(app.searchHistory.count))") { app.clearSearchHistory() }
                CapsuleButton(title: "清空观看历史 (\(app.history.count))") { app.clearHistory() }
                CapsuleButton(title: "清空收藏 (\(app.favorites.count))") { app.clearFavorites() }
            }
        }
    }

    // MARK: - 开屏

    private func splashSection(_ model: AppModel) -> some View {
        @Bindable var app = model
        return section("开屏页") {
            Toggle(isOn: $app.splashPoemOn) {
                Text("显示情话").font(SMFont.small).foregroundStyle(SM.text)
            }
            .tint(SM.primary)

            if app.splashPoemOn {
                TextEditor(text: $app.splashPoem)
                    .font(SMFont.small)
                    .foregroundStyle(SM.text)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 130)
                    .padding(8)
                    .background(SM.surfaceLight, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text("每行一句，逐行淡入").font(SMFont.tiny).foregroundStyle(SM.textDim)
            }
        }
    }

    private var aboutSection: some View {
        section("关于") {
            Text("茗影院 iOS 版 · v1.0.2")
                .font(SMFont.small).foregroundStyle(SM.text)
            Text("本应用由 Sean Gao 开源 · 仅供开发与测试使用 · 禁止商用 · 违者后果自负")
                .font(SMFont.tiny).foregroundStyle(SM.textDim)
            Text("播放内核 AVPlayer · 请求头注入方式 AVURLAssetHTTPHeaderFieldsKey")
                .font(SMFont.tiny).foregroundStyle(SM.textDim)
        }
    }

    // MARK: - 分组容器

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(SMFont.title).foregroundStyle(SM.text)
            VStack(alignment: .leading, spacing: 10) { content() }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SM.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}
