import MingTVCore
import SwiftUI
import UIKit

/// 内存级图片缓存 (对应 Android Glide 的职责)
final class PosterCache {
    static let shared = PosterCache()
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 400
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    func image(for url: String) -> UIImage? { cache.object(forKey: url as NSString) }

    func store(_ image: UIImage, for url: String) {
        cache.setObject(image, forKey: url as NSString, cost: image.pngData()?.count ?? 0)
    }
}

/// 带缓存的异步图片 (海报/频道图标)
struct CachedAsyncImage: View {
    let url: String
    var contentMode: ContentMode = .fill

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                ZStack {
                    SM.surfaceLight
                    if failed {
                        Image(systemName: "photo")
                            .font(.system(size: 22))
                            .foregroundStyle(SM.textDim)
                    } else {
                        ProgressView().tint(SM.textDim)
                    }
                }
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        guard !url.isEmpty, let u = URL(string: url) else { failed = true; return }
        if let cached = PosterCache.shared.image(for: url) { image = cached; return }
        failed = false
        var req = URLRequest(url: u)
        req.timeoutInterval = 15
        req.setValue(MingNet.sharedUA, forHTTPHeaderField: "User-Agent")
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let img = UIImage(data: data) else { failed = true; return }
            PosterCache.shared.store(img, for: url)
            image = img
        } catch {
            failed = true
        }
    }
}
