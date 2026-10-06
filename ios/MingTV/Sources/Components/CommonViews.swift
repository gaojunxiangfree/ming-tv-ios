import SwiftUI
import MingTVCore

// MARK: - 胶囊按钮 (对应 Android: item_tab.xml / bg_button_selector / bg_episode_selector)

struct CapsuleButton: View {
    /// function = 首页功能行 (bg_button_selector, 圆角10)
    /// chip     = 分类Tab/线路Tab/筛选 (item_tab → bg_episode_selector, 圆角8)
    enum Style { case chip, function }

    let title: String
    /// emoji 图标
    var icon: String? = nil
    /// SF Symbol 名
    var systemIcon: String? = nil
    var selected = false
    var style: Style = .chip
    var action: () -> Void

    private var cornerRadius: CGFloat { style == .function ? 10 : 8 }

    private var background: Color {
        if selected { return SM.primaryDark }
        return style == .function ? SM.surfaceLight : SM.episodeBg
    }

    private var horizontalPadding: CGFloat { style == .function ? 8 : 20 }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemIcon {
                    Image(systemName: systemIcon).font(.system(size: 12, weight: .medium))
                } else if let icon {
                    Text(icon).font(.system(size: 13))
                }
                Text(title)
                    .font(SMFont.small.weight(selected ? .semibold : .regular))
                    .lineLimit(1)
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, style == .function ? 6 : 8)
            .foregroundStyle(SM.text)
            .background(background, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("cap-\(title)")
    }
}

// MARK: - 海报卡 (对应 Android: item_vod.xml)

struct PosterCard: View {
    let vod: Vod
    var width: CGFloat
    /// 传 nil 时只做展示 —— 用于已包在 NavigationLink 内的场景,
    /// 否则内层 Button 会吞掉点击, 导致整格点不动.
    var onTap: (() -> Void)?

    private var height: CGFloat { width * 1.5 }

    var body: some View {
        if let onTap {
            Button(action: onTap) { card }
                .buttonStyle(.plain)
                .accessibilityIdentifier("poster-\(vod.id)")
        } else {
            card.accessibilityIdentifier("poster-\(vod.id)")
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                CachedAsyncImage(url: vod.pic)
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                // 左上角标签 (对应 tvTag): 源标签 → 分类名
                let tagText = vod.tag.isEmpty ? vod.typeName : vod.tag
                if !tagText.isEmpty {
                    Text(tagText)
                        .font(SMFont.tiny)
                        .foregroundStyle(SM.text)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(SM.badgeBg, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .padding(6)
                }
            }
            .overlay(alignment: .bottomLeading) {
                // 左下角评分 (对应 tvScore, 黄底深字)
                if !vod.score.isEmpty {
                    Text(vod.score)
                        .font(SMFont.tiny.weight(.bold))
                        .foregroundStyle(SM.surface)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(SM.scoreBg, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .padding(6)
                }
            }

            Text(vod.name)
                .font(SMFont.small)
                .foregroundStyle(SM.text)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .frame(width: width, alignment: .leading)

            // 与 Android 一致: 有备注(如"更新至32集")优先显示备注, 否则显示年份
            Text(vod.remarks.isEmpty ? (vod.year.isEmpty ? "" : vod.year + "年") : vod.remarks)
                .font(SMFont.tiny)
                .foregroundStyle(SM.textDim)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                .frame(width: width, alignment: .leading)
        }
    }
}

// MARK: - 选集按钮 (对应 Android: item_episode.xml)

struct EpisodeChip: View {
    let title: String
    var selected = false
    var width: CGFloat = 82
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(SMFont.small)
                .foregroundStyle(SM.text)
                .lineLimit(1)
                .frame(width: width, height: 36)
                .background(selected ? SM.primaryDark : SM.episodeBg,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ep-\(title)")
    }
}

// MARK: - 状态占位

struct LoadingState: View {
    var text = "加载中…"
    var body: some View {
        VStack(spacing: 10) {
            ProgressView().tint(SM.primary)
            Text(text).font(SMFont.small).foregroundStyle(SM.textDim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EmptyState: View {
    var icon = "tray"
    var text: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 34)).foregroundStyle(SM.textDim)
            Text(text).font(SMFont.body).foregroundStyle(SM.textDim).multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(SMFont.small)
                    .foregroundStyle(SM.primary)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 顶栏

struct TopBar<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var onBack: (() -> Void)? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            if let onBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(SM.text)
                        .frame(width: 34, height: 34)
                        .background(SM.surfaceLight, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("topbar-back")
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(SMFont.title).foregroundStyle(SM.text).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(SMFont.tiny).foregroundStyle(SM.textDim).lineLimit(1)
                }
            }

            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

extension TopBar where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, onBack: (() -> Void)? = nil) {
        self.init(title: title, subtitle: subtitle, onBack: onBack) { EmptyView() }
    }
}
