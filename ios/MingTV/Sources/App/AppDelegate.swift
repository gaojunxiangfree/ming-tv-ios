import AVFoundation
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
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        configureAudioSession()
        return true
    }

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        AppDelegate.orientationLock
    }

    /// 修复「扬声器无声、只有戴耳机才有声音」: 默认的 .soloAmbient 会话类别会跟随
    /// 静音开关 —— 手机静音时视频通过扬声器播放被静音, 而耳机不受影响, 表现为只有耳机有声。
    /// 视频 App 必须使用 .playback 类别(忽略静音开关且走扬声器, 与主流播放器一致)。
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
    }
}
