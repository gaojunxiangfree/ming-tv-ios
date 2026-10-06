import SwiftUI
import MingTVCore

/// 观看历史 (对应 Android: HistoryActivity)
struct HistoryView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            SM.bgGradient.ignoresSafeArea()
            VStack(spacing: 0) {
                TopBar(title: "观看历史", subtitle: "\(app.history.count) 条", onBack: { dismiss() }) {
                    if !app.history.isEmpty {
                        Button("清空") { app.clearHistory() }
                            .font(SMFont.small).foregroundStyle(SM.textDim)
                    }
                }

                if app.history.isEmpty {
                    EmptyState(icon: "clock", text: "还没有观看记录")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(app.history) { item in
                                row(item)
                            }
                        }
                        .padding(16)
                    }
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private func row(_ item: HistoryItem) -> some View {
        NavigationLink(value: Route.detail(VodRef(siteKey: item.siteKey,
                                                   vodId: item.vodId,
                                                   name: item.vodName,
                                                   pic: item.vodPic))) {
            HStack(spacing: 12) {
                CachedAsyncImage(url: item.vodPic)
                    .frame(width: 62, height: 88)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 5) {
                    Text(item.vodName)
                        .font(SMFont.body.weight(.semibold)).foregroundStyle(SM.text).lineLimit(1)
                    Text(item.episodeName.isEmpty ? "第 \(item.episodeIndex + 1) 集" : item.episodeName)
                        .font(SMFont.small).foregroundStyle(SM.primary).lineLimit(1)

                    if item.duration > 0 {
                        ProgressView(value: min(item.position, item.duration), total: item.duration)
                            .tint(SM.primary)
                        Text("已看 \(Self.timeText(item.position)) / \(Self.timeText(item.duration))")
                            .font(SMFont.tiny).foregroundStyle(SM.textDim)
                    }
                    Text(Self.dateText(item.updateTime))
                        .font(SMFont.tiny).foregroundStyle(SM.textDim)
                }

                Spacer(minLength: 0)

                Button {
                    app.removeHistory(item)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13))
                        .foregroundStyle(SM.textDim)
                        .frame(width: 32, height: 32)
                        .background(SM.surfaceLight, in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(10)
            .smCard()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("history-row-\(item.id)")
    }

    static func timeText(_ s: Double) -> String {
        guard s.isFinite, s > 0 else { return "00:00" }
        let t = Int(s)
        let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }

    static func dateText(_ ts: Double) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: ts))
    }
}
