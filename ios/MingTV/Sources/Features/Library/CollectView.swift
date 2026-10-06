import SwiftUI
import MingTVCore

/// 收藏 (对应 Android: CollectActivity)
struct CollectView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 112, maximum: 180), spacing: 12)]

    var body: some View {
        ZStack {
            SM.bgGradient.ignoresSafeArea()
            VStack(spacing: 0) {
                TopBar(title: "收藏", subtitle: "\(app.favorites.count) 部", onBack: { dismiss() }) {
                    if !app.favorites.isEmpty {
                        Button("清空") { app.clearFavorites() }
                            .font(SMFont.small).foregroundStyle(SM.textDim)
                    }
                }

                if app.favorites.isEmpty {
                    EmptyState(icon: "star", text: "还没有收藏的影片")
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(app.favorites) { item in
                                NavigationLink(value: Route.detail(VodRef(siteKey: item.siteKey,
                                                                          vodId: item.vodId,
                                                                          name: item.vodName,
                                                                          pic: item.vodPic))) {
                                    VStack(alignment: .leading, spacing: 6) {
                                        CachedAsyncImage(url: item.vodPic)
                                            .frame(width: 112, height: 168)
                                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                        Text(item.vodName)
                                            .font(SMFont.small).foregroundStyle(SM.text).lineLimit(1)
                                        Text(item.vodRemarks)
                                            .font(SMFont.tiny).foregroundStyle(SM.textDim).lineLimit(1)
                                    }
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        app.removeFavorite(item)
                                    } label: { Label("取消收藏", systemImage: "star.slash") }
                                }
                            }
                        }
                        .padding(16)
                    }
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}
