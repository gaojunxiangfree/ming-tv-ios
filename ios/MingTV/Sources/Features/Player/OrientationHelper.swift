import UIKit

/// 播放页「全屏」键的方向切换.
///
/// 对齐爱奇艺 / 腾讯视频: 竖屏下点右下角 `[]` 键 → 转横屏铺满; 横屏点左上返回键 → 回竖屏.
///
/// 实现要点: 光调 `requestGeometryUpdate` 会被重算覆盖, 必须同时收窄 `AppDelegate.orientationLock`,
/// 让"支持方向"和"请求方向"一致(详见 AppDelegate 的说明).
@MainActor
enum OrientationHelper {

    /// 转横屏。请求"任意横向"而不是写死 landscapeRight ——
    /// 写死会出现「画面相对用户转了 90°」: 手机实际是另一个横向方向时系统不会翻转过来。
    static func enterLandscape() {
        apply(lock: .landscape, request: .landscape)
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
        // 先让系统按新的锁重算"支持方向", 再请求几何方向。
        // 两者同帧下发时, 后到的重算会覆盖方向偏好(实测 (Pu Ll Lr) -> (Pu) 又被翻回),
        // 中间隔一小段时间可避开这个竞争。
        refresh()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 60_000_000)
            request(mask)

            // 首次请求偶尔仍被系统的"支持方向重算"吃掉, 复查一次: 没转过去就再请求一次。
            // 这样用户点一下就走完, 不用反复点。
            try? await Task.sleep(nanoseconds: 350_000_000)
            if let scene = activeScene, !allows(scene.interfaceOrientation, mask) {
                refresh()
                request(mask)
            }
        }
    }

    private static func request(_ mask: UIInterfaceOrientationMask) {
        guard let scene = activeScene else { return }
        let prefs = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: mask)
        scene.requestGeometryUpdate(prefs) { error in
            NSLog("[MingTV][Orientation] 方向请求被拒 mask=\(mask.rawValue): \(error)")
        }
    }

    private static func allows(_ orientation: UIInterfaceOrientation,
                              _ mask: UIInterfaceOrientationMask) -> Bool {
        switch orientation {
        case .portrait:           return mask.contains(.portrait)
        case .portraitUpsideDown: return mask.contains(.portraitUpsideDown)
        case .landscapeLeft:      return mask.contains(.landscapeLeft)
        case .landscapeRight:     return mask.contains(.landscapeRight)
        @unknown default:         return true
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
