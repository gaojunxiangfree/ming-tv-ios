import SwiftUI
import MingTVCore

/// 首页 (对应 Android: HomeActivity)
struct HomeView: View {
    @Environment(AppModel.self) private var app
    @State private var model = HomeModel()
    @State private var path: [Route] = []
    @State private var showSiteDialog = false
    @State private var playTarget: PlayTarget?

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                topBar
                functionRow
                tabRow
                content
            }
            .background(SM.bgGradient.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Route.self) { route in
                destination(for: route)
            }
        }
        .sheet(isPresented: $showSiteDialog) {
            SiteDialogView()
        }
        .fullScreenCover(item: $playTarget) { target in
            PlayerView(target: target) { updated in
                playTarget = updated
            }
        }
        .task(id: app.currentSiteKey) {
            guard let site = app.currentSite else { return }
            await model.load(site: site)
        }
    }

    // MARK: - 顶栏

    private var topBar: some View {
        HStack(spacing: 10) {
            // 对应 Android: ic_logo 38dp
            Image("ic_logo")
                .resizable()
                .scaledToFit()
                .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Button {
                    showSiteDialog = true
                } label: {
                    HStack(spacing: 6) {
                        Text(app.currentSite?.name ?? "未选择源")
                            .font(SMFont.title.weight(.bold))
                            .foregroundStyle(SM.text)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10))
                            .foregroundStyle(SM.textDim)
                    }
                }
                .buttonStyle(.plain)

                // 版权与免责声明 (对应 tvFreeTip, 位于站点名下方)
                Text("本应用由 Sean Gao 开源 · 仅供开发与测试使用 · 禁止商用 · 违者后果自负")
                    .font(.system(size: 10))
                    .foregroundStyle(SM.textDim)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(Self.clockFormatter.string(from: ctx.date))
                    .font(SMFont.tiny)
                    .foregroundStyle(SM.textDim)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年MM月dd日 HH:mm:ss"
        return f
    }()

    // MARK: - 功能行

    private var functionRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            // 顺序照搬 Android activity_home.xml 的 functionBar
            // (已去掉「配置」「推送」两项: 依赖本地 HTTP 服务/扫码/局域网推送, iOS 版未实现)
            HStack(spacing: 6) {
                functionButton("🕐", "历史") { path.append(.history) }
                functionButton("📺", "直播") { path.append(.live) }
                functionButton("🔍", "搜索") { path.append(.search) }
                functionButton("🛤️", "线路") { showSiteDialog = true }
                functionButton("☁️", "网盘") { path.append(.drive) }
                functionButton("⭐", "收藏") { path.append(.collect) }
                functionButton("⚙️", "设置") { path.append(.settings) }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 8)
        .accessibilityIdentifier("function-row")
    }

    private func functionButton(_ emoji: String, _ title: String,
                                action: @escaping () -> Void) -> some View {
        CapsuleButton(title: title, icon: emoji, style: .function, action: action)
    }

    // MARK: - 分类 Tab

    @ViewBuilder
    private var tabRow: some View {
        if !model.tabs.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.tabs) { tab in
                        CapsuleButton(title: tab.name,
                                      selected: tab.id == model.selectedTabID) {
                            guard let site = app.currentSite else { return }
                            Task { await model.selectTab(tab.id, site: site) }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 10)
        }
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if model.loading && model.items.isEmpty {
            LoadingState(text: "正在加载片库…")
        } else if let err = model.error, model.items.isEmpty {
            EmptyState(icon: "wifi.exclamationmark", text: err, actionTitle: "重试") {
                guard let site = app.currentSite else { return }
                Task { await model.load(site: site, force: true) }
            }
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 112, maximum: 180), spacing: 12)],
                          spacing: 16) {
                    ForEach(model.items, id: \.id) { vod in
                        PosterCard(vod: vod, width: 112) {
                            openDetail(vod)
                        }
                        .task {
                            guard let site = app.currentSite else { return }
                            await model.loadMoreIfNeeded(current: vod, site: site)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)

                if model.loadingMore {
                    ProgressView().tint(SM.primary).padding(.bottom, 24)
                }
            }
            .refreshable {
                guard let site = app.currentSite else { return }
                await model.load(site: site, force: true)
            }
        }
    }

    private func openDetail(_ vod: Vod) {
        path.append(.detail(VodRef(siteKey: app.currentSiteKey,
                                   vodId: vod.id,
                                   name: vod.name,
                                   pic: vod.pic)))
    }

    // MARK: - 路由

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .detail(let ref):
            DetailView(ref: ref, onPlay: { target in playTarget = target })
        case .search:
            SearchView()
        case .live:
            LiveView()
        case .history:
            HistoryView()
        case .collect:
            CollectView()
        case .drive:
            DriveView { target in playTarget = target }
        case .settings:
            SettingsView()
        }
    }
}

// MARK: - 换源弹窗 (对应 Android: HomeActivity.showSiteDialog)

struct SiteDialogView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 10)],
                          spacing: 10) {
                    ForEach(app.sites, id: \.key) { site in
                        CapsuleButton(title: site.name,
                                      selected: site.key == app.currentSiteKey) {
                            app.selectSite(site.key)
                            dismiss()
                        }
                    }
                }
                .padding(16)
            }
            .background(SM.bg.ignoresSafeArea())
            .navigationTitle("切换线路")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}
