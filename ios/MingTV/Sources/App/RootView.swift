import SwiftUI

/// 根视图: 开屏 → 首页
///
/// 开屏页可在「设置 → 开屏页」里关掉, 关闭后冷启动直接进首页。
struct RootView: View {
    @Environment(AppModel.self) private var app
    @State private var showSplash = true

    var body: some View {
        ZStack {
            SM.bgGradient.ignoresSafeArea()
            if showSplash && app.splashEnabled {
                SplashView { withAnimation(.easeInOut(duration: 0.5)) { showSplash = false } }
                    .transition(.opacity)
            } else {
                HomeView()
                    .transition(.opacity)
            }
        }
    }
}
