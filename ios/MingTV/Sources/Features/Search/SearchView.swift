import SwiftUI
import MingTVCore

/// 搜索页 (对应 Android: SearchActivity + FastSearchActivity)
struct SearchView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var model = FastSearchModel()
    @State private var keyword = ""
    @FocusState private var focused: Bool

    private let columns = [GridItem(.adaptive(minimum: 112, maximum: 180), spacing: 12)]

    var body: some View {
        ZStack {
            SM.bgGradient.ignoresSafeArea()
            VStack(spacing: 0) {
                TopBar(title: "搜索", onBack: { dismiss() })
                searchField

                if model.searching || !model.hits.isEmpty {
                    resultsArea
                } else {
                    historyArea
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { focused = true }
    }

    // MARK: - 输入

    private var searchField: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(SM.textDim)
                TextField("输入片名，全源秒搜", text: $keyword)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .foregroundStyle(SM.text)
                    .focused($focused)
                    .onSubmit { runSearch() }
                    .accessibilityIdentifier("search-field")
                if !keyword.isEmpty {
                    Button { keyword = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(SM.textDim)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(SM.surfaceLight, in: Capsule())

            Button("搜索") { runSearch() }
                .font(SMFont.body.weight(.semibold))
                .foregroundStyle(SM.bg)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(SM.accentGradient, in: Capsule())
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private func runSearch() {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else { return }
        app.addSearchKeyword(kw)
        focused = false
        Task { await model.search(keyword: kw, sites: app.sites) }
    }

    // MARK: - 搜索历史

    @ViewBuilder
    private var historyArea: some View {
        if app.searchHistory.isEmpty {
            EmptyState(icon: "magnifyingglass", text: "输入片名开始搜索\n当前 \(app.sites.count) 个可用源")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("搜索历史").font(SMFont.title).foregroundStyle(SM.text)
                        Spacer()
                        Button("清空") { app.clearSearchHistory() }
                            .font(SMFont.small).foregroundStyle(SM.textDim)
                    }
                    FlowChips(items: app.searchHistory) { kw in
                        keyword = kw
                        runSearch()
                    }
                }
                .padding(16)
            }
        }
    }

    // MARK: - 结果

    @ViewBuilder
    private var resultsArea: some View {
        VStack(spacing: 8) {
            HStack {
                if model.searching {
                    ProgressView().tint(SM.primary).scaleEffect(0.8)
                }
                Text(model.progress).font(SMFont.small).foregroundStyle(SM.textDim)
                Spacer()
            }
            .padding(.horizontal, 16)

            if model.sourceSites.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        CapsuleButton(title: "全部", selected: model.filterSiteKey == nil) {
                            model.filterSiteKey = nil
                        }
                        ForEach(model.sourceSites, id: \.key) { s in
                            CapsuleButton(title: s.name, selected: model.filterSiteKey == s.key) {
                                model.filterSiteKey = s.key
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }

            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(model.filteredHits) { hit in
                        NavigationLink(value: Route.detail(VodRef(siteKey: hit.siteKey,
                                                                  vodId: hit.vod.id,
                                                                  name: hit.vod.name,
                                                                  pic: hit.vod.pic))) {
                            VStack(alignment: .leading, spacing: 4) {
                                // 海报在此只做展示: 点击交给外层 NavigationLink
                                PosterCard(vod: hit.vod, width: 112)
                                Text(hit.siteName)
                                    .font(SMFont.tiny)
                                    .foregroundStyle(SM.primary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("search-hit-\(hit.vod.id)")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
    }
}

// MARK: - 自适应换行 chips

struct FlowChips: View {
    let items: [String]
    let onTap: (String) -> Void

    private let columns = [GridItem(.adaptive(minimum: 90, maximum: 220), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self) { item in
                CapsuleButton(title: item) { onTap(item) }
            }
        }
    }
}
