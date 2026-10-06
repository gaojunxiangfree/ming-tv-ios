import SwiftUI
import MingTVCore

/// 开屏页 (对应 Android: SplashActivity)
/// 深色背景 + 居中情话逐行淡入, 5.5 秒后进入首页.
struct SplashView: View {
    @Environment(AppModel.self) private var app
    let onFinish: () -> Void

    private var lines: [String] {
        app.splashPoem
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    @State private var visibleLines = 0
    @State private var heartScale: CGFloat = 0.6
    @State private var showSub = false

    var body: some View {
        ZStack {
            // 对应 bg_splash_overlay.xml: 270° 渐变 透明 → #40000000 → #CC0D1117
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: Color.black.opacity(0.25), location: 0.5),
                .init(color: Color(hex: 0x0D1117).opacity(0.8), location: 1),
            ], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 22) {
                Text("❤")
                    .font(.system(size: 44))
                    .foregroundStyle(Color(hex: 0xFF6B81))
                    .scaleEffect(heartScale)

                Text("致 · 小茗")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(SM.text)
                    .shadow(color: SM.primary.opacity(0.45), radius: 14)

                VStack(spacing: 12) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                        Text(line)
                            .font(.system(size: 17))
                            .foregroundStyle(idx == lines.count - 1 ? SM.primary : SM.text.opacity(0.92))
                            .opacity(idx < visibleLines ? 1 : 0)
                            .offset(y: idx < visibleLines ? 0 : 12)
                            .animation(.easeOut(duration: 0.7), value: visibleLines)
                    }
                }
                .padding(.top, 8)

                Text("—— 小高 同学 · 量身定制")
                    .font(SMFont.small)
                    .foregroundStyle(SM.textDim)
                    .opacity(showSub ? 1 : 0)
                    .padding(.top, 14)
            }
            .padding(.horizontal, 40)
        }
        .task {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.5)) { heartScale = 1.0 }

            if app.splashPoemOn {
                // 逐行错时淡入
                for i in 1...max(lines.count, 1) {
                    try? await Task.sleep(nanoseconds: 420_000_000)
                    visibleLines = i
                }
            } else {
                visibleLines = lines.count
            }
            try? await Task.sleep(nanoseconds: 600_000_000)
            withAnimation { showSub = true }
            try? await Task.sleep(nanoseconds: 900_000_000)
            onFinish()
        }
    }
}
