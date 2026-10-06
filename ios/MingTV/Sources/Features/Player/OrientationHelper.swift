import UIKit

/// 播放页「全屏」键的方向切换.
///
/// 对齐爱奇艺 / 腾讯视频: 竖屏下点右下角 `[]` 键 → 转横屏铺满; 横屏点左上返回键 → 回竖屏.
///
/// 实现要点: 光调 `requestGeometryUpdate` 会被重算覆盖, 必须同时收窄 `AppDelegate.orientationLock`,
/// 让"支持方向"和"请求方向"一致(详见 AppDelegate 的说明).
@MainActor
enum OrientationHelper {

    static func enterLandscape() {
        apply(lock: .landscape, request: .landscapeRight)
    }

    static func enterPortrait() {
        apply(lock: .portrait, request: .portrait)
    }

    static var isLandscape: Bool {
        activeScene?.interfaceOrientation.isLandscape ?? false
    }

    /// 播放页关闭时恢复自由旋转
    static func restoreFreeRotation() {
        AppDelegate.orientationLock = .allButUpsideDown
        refresh()
    }

    private static func apply(lock: UIInterfaceOrientationMask, request mask: UIInterfaceOrientationMask) {
        AppDelegate.orientationLock = lock
        // 先让系统按新的锁重算支持方向, 再请求几何方向
        refresh()
        guard let scene = activeScene else { return }
        let prefs = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: mask)
        scene.requestGeometryUpdate(prefs) { error in
            NSLog("[MingTV][Orientation] 方向请求被拒 mask=\(mask.rawValue): \(error)")
        }
    }

    private static func refresh() {
        activeScene?.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    private static var activeScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }
}
