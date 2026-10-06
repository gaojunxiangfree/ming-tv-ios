import SwiftUI

// MARK: - 配色 (照搬 Android res/values/colors.xml 的 sm_ 系列)

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

enum SM {
    /// 主背景
    static let bg = Color(hex: 0x0A0E1A)
    static let bgGradientEnd = Color(hex: 0x101630)
    /// 卡片面
    static let surface = Color(hex: 0x141A2E)
    static let surfaceLight = Color(hex: 0x1D2542)
    /// 主色 (青色)
    static let primary = Color(hex: 0x22D3EE)
    static let primaryDark = Color(hex: 0x0E9BB5)
    static let violet = Color(hex: 0x7C6CFF)
    static let gold = Color(hex: 0xFFC857)
    /// 文字
    static let text = Color(hex: 0xEDF2FF)
    static let textDim = Color(hex: 0x8A93B2)
    static let divider = Color(hex: 0x1F2745)
    /// 选集按钮
    static let episodeBg = Color(hex: 0x1A2140)
    /// 评分角标底色 (对应 bg_score.xml)
    static let scoreBg = Color(hex: 0xE6C857)
    /// 角标半透明底 (对应 bg_badge.xml)
    static let badgeBg = Color(hex: 0x99000000)

    /// 页面背景渐变
    static var bgGradient: LinearGradient {
        LinearGradient(colors: [bg, bgGradientEnd], startPoint: .top, endPoint: .bottom)
    }

    /// 主色渐变 (用于强调元素)
    static var accentGradient: LinearGradient {
        LinearGradient(colors: [primary, violet], startPoint: .leading, endPoint: .trailing)
    }
}

// MARK: - 字号
// Android 端是 TV 大屏规范 (标题 36sp / 正文 28sp / 小字 24sp),
// iOS 需要同时覆盖手机与 iPad, 因此统一按档位给出.

enum SMFont {
    static let pageTitle = Font.system(size: 24, weight: .bold)
    static let title = Font.system(size: 20, weight: .semibold)
    static let body = Font.system(size: 15)
    static let small = Font.system(size: 13)
    static let tiny = Font.system(size: 11)
}

// MARK: - 通用修饰

extension View {
    /// 卡片外观
    func smCard(cornerRadius: CGFloat = 12) -> some View {
        background(SM.surface,
                   in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// 选中态描边
    func smSelected(_ selected: Bool, cornerRadius: CGFloat = 10) -> some View {
        overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(selected ? SM.primary : .clear, lineWidth: 2)
        }
    }
}
