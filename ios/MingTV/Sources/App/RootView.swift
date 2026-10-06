import SwiftUI

/// 根视图: 开屏 → 首页
struct RootView: View {
    @Environment(AppModel.self) private var app
    @State private var showSplash = true

    var body: some View {
        ZStack {
            SM.bgGradient.ignoresSafeArea()
            if showSplash {
                SplashView { withAnimation(.easeInOut(duration: 0.5)) { showSplash = false } }
                    .transition(.opacity)
            } else {
                HomeView()
                    .transition(.opacity)
            }
        }
    }
}
