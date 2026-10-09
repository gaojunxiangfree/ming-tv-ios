import UIKit

/// 提供 App 级方向锁.
///
/// 为什么需要它: 只调 `requestGeometryUpdate` 不够 —— SwiftUI/UIKit 在视图更新时
/// 会按 Info.plist 重新计算"支持方向", 把刚请求的方向偏好覆盖掉
/// (实测日志: `(Pu Ll Lr) -> (Pu)` 之后 0.5s 被翻回 `(Pu Ll Lr)`, 于是转不回竖屏).
/// 让 `supportedInterfaceOrientationsFor` 返回我们自己的锁, 重算结果才和请求一致.
final class AppDelegate: NSObject, UIApplicationDelegate {

    /// 默认允许自由旋转(与改造前行为一致), 播放页全屏切换时临时收窄
    static var orientationLock: UIInterfaceOrientationMask = .allButUpsideDown

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        AppDelegate.orientationLock
    }
}
