import AVFoundation
import UIKit

/// 提供 App 级方向锁.
///
/// 为什么需要它: 只调 `requestGeometryUpdate` 不够 —— SwiftUI/UIKit 在视图更新时
/// 会按 Info.plist 重新计算"支持方向", 把刚请求的方向偏好覆盖掉
/// (实测日志: `(Pu Ll Lr) -> (Pu)` 之后 0.5s 被翻回 `(Pu Ll Lr)`, 于是转不回竖屏).
/// 让 `supportedInterfaceOrientationsFor` 返回我们自己的锁, 重算结果才和请求一致.
final class AppDelegate: NSObject, UIApplicationDelegate {

    /// 允许自由旋转(与改造前行为一致), 播放页全屏切换时临时收窄
    static var orientationLock: UIInterfaceOrientationMask = .allButUpsideDown

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        configureAudioSession()
        return true
    }

    /// 配置音频会话: 让 AVPlayer 外放有声, 且不受实体静音键影响, 也不被系统认为应走其它输出.
    /// 若不设置 .playback, 系统默认路由可能被静音键(物理拨杆)静音或切走,
    /// 典型症状即为「外放无声、插耳机才有声」.
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            NSLog("MingTV: 配置 AVAudioSession 失败 - \(error)")
        }
    }

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        AppDelegate.orientationLock
    }
}
