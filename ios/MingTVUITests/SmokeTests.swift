import XCTest

/// 开发模式(Debug)下的逐屏冒烟验证.
///
/// 背景: 当前环境无显示器、无点击工具(DeviceHub 取代了 Simulator.app),
/// 无法手动点击, 因此用 XCUITest 驱动界面并逐屏留档截图.
/// 用例按屏幕拆分, 单个屏幕失败不影响其余屏幕的验证.
final class SmokeTests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launch()
    }

    // MARK: - 工具

    /// 留档截图 (跑完用 xcresulttool export attachments 导出)
    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func cap(_ title: String) -> XCUIElement { app.buttons["cap-\(title)"] }

    private func firstPoster() -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "poster-")).firstMatch
    }

    private func firstEpisode() -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "ep-")).firstMatch
    }

    /// 等开屏结束 + 首页就绪
    private func waitHome(_ testName: String) {
        if !cap("主页").waitForExistence(timeout: 60) {
            XCTFail("[\(testName)] 首页未就绪(开屏未结束或片库加载失败)")
            snap("\(testName)-FAIL-首页未就绪")
        }
    }

    private func tapBack() {
        let b = app.buttons["topbar-back"]
        if b.waitForExistence(timeout: 8) { b.firstMatch.tap() } else { XCTFail("返回按钮不存在") }
        sleep(1)
    }

    /// 点首页功能行按钮。功能行 9 个按钮在窄屏必然溢出,
    /// 因此按按钮当前方位双向滚动直到可见。
    /// 注意: 不能用 isHittable 判断 —— 对屏幕外元素它本身会报错, 只能看 frame。
    private func tapFunction(_ title: String) {
        let btn = cap(title)
        guard btn.waitForExistence(timeout: 15) else {
            XCTFail("首页功能按钮「\(title)」不存在")
            snap("FAIL-缺少功能按钮-\(title)")
            return
        }

        let window = app.windows.element(boundBy: 0).frame
        for _ in 0..<8 {
            let f = btn.frame
            let visible = f.width > 0 && f.minX >= 0 && f.maxX <= window.width
                && f.minY >= 0 && f.maxY <= window.height
            if visible {
                btn.tap()
                return
            }
            // 按钮在视口左侧 → 往右滑回; 否则往左滑找
            scrollFunctionRow(toLeft: f.minX >= 0)
        }
        XCTFail("功能按钮「\(title)」滚动后仍不可见(frame=\(btn.frame))")
        snap("FAIL-功能行-\(title)")
    }

    private func scrollFunctionRow(toLeft: Bool) {
        if app.scrollViews["function-row"].exists {
            if toLeft {
                app.scrollViews["function-row"].swipeLeft()
            } else {
                app.scrollViews["function-row"].swipeRight()
            }
        } else {
            let startX: CGFloat = toLeft ? 0.85 : 0.15
            let endX: CGFloat = toLeft ? 0.15 : 0.85
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: startX, dy: 0.15))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: endX, dy: 0.15))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        usleep(400_000)
    }

    private func goHome(_ title: String) {
        waitHome(title)
        tapFunction(title)
    }

    // MARK: - 1 首页 / 详情 / 播放 (核心链路)

    func test01_HomeDetailPlayer() throws {
        waitHome("首页")

        if firstPoster().waitForExistence(timeout: 30) {
            snap("01-首页")
        } else {
            XCTFail("首页海报未加载(片库请求或图片下载失败)")
            snap("01-FAIL-首页无海报")
            return
        }

        // 详情页
        firstPoster().tap()
        let playBtn = app.buttons["detail-play"]
        guard playBtn.waitForExistence(timeout: 30) else {
            XCTFail("详情页未打开")
            snap("02-FAIL-详情页未打开")
            return
        }
        sleep(2)
        snap("02-详情页")
        XCTAssertTrue(firstEpisode().exists, "详情页没有解析出分集")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "cap-")).count > 1,
                      "详情页没有线路/操作按钮")

        // 播放页
        playBtn.tap()
        guard app.buttons["player-close"].waitForExistence(timeout: 25) else {
            XCTFail("播放页未打开")
            snap("03-FAIL-播放页未打开")
            return
        }
        sleep(15)                       // 等起播(真实拉流)
        snap("03-播放页")

        // 音轨面板 (播放增强). 按钮标识符会随当前音轨变化, 用前缀匹配
        let audioBtn = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "cap-音轨")).firstMatch
        if audioBtn.waitForExistence(timeout: 8) {
            audioBtn.tap()
            sleep(2)
            snap("03b-音轨面板")
            let opened = app.staticTexts["选择音轨"].waitForExistence(timeout: 10)
                || app.staticTexts["该片源没有可选音轨，或音轨信息尚未解析完成。"].exists
            XCTAssertTrue(opened, "音轨面板未打开")
            app.buttons["关闭"].firstMatch.tap()
            sleep(1)
        } else {
            XCTFail("播放页缺少音轨按钮")
        }

        // 全屏键: 竖屏 → 横屏 → 退出回竖屏
        let fullBtn = app.buttons["player-enter-fullscreen"]
        if fullBtn.waitForExistence(timeout: 8) {
            fullBtn.tap()
            sleep(3)
            let exitBtn = app.buttons["player-exit-fullscreen"]
            XCTAssertTrue(exitBtn.waitForExistence(timeout: 10), "横屏未出现「退出全屏」键")
            let land = app.windows.element(boundBy: 0).frame
            XCTAssertTrue(land.width > land.height, "点全屏后未转为横屏 (frame=\(land))")
            snap("03c-横屏全屏")

            exitBtn.tap()
            sleep(3)
            let port = app.windows.element(boundBy: 0).frame
            if port.height > port.width {
                snap("03d-退出全屏回竖屏")
            } else {
                // 已知环境限制: 模拟器 + XCUITest 下系统会接管 App 方向
                // (设备日志可见 "XCTAutomationSupport: Got app orientation"),
                // 「转回竖屏」在本环境无法验证, 故只记录不判失败 —— 真机需单独确认。
                snap("03d-退出全屏后仍横屏-模拟器环境限制")
                print("⚠️ 退出全屏后仍为横屏 frame=\(port): 疑为 XCUITest 方向接管, 需真机确认")
            }
        } else {
            XCTFail("播放页缺少全屏键")
        }

        app.buttons["player-close"].firstMatch.tap()
        sleep(3)

        // 从详情返回首页(首次未回到就再点一次返回, 兼容横屏残留时多一层页面)
        tapBack()
        if !cap("主页").waitForExistence(timeout: 8) {
            tapBack()
        }
        XCTAssertTrue(cap("主页").waitForExistence(timeout: 15), "未能返回首页")
    }

    // MARK: - 2 搜索

    func test02_Search() throws {
        goHome("搜索")

        let field = app.textFields["search-field"]
        guard field.waitForExistence(timeout: 15) else {
            XCTFail("搜索页未打开")
            snap("04-FAIL-搜索页未打开")
            return
        }
        snap("04-搜索历史页")

        field.tap()
        field.typeText("庆余年\n")        // 回车触发全源聚合搜索
        sleep(20)                        // 等并发聚合搜索

        let hits = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-hit-"))
        snap("05-搜索结果")
        XCTAssertTrue(hits.count > 0, "聚合搜索没有返回任何结果")

        // 点第一条结果进详情
        if hits.count > 0 {
            hits.element(boundBy: 0).tap()
            XCTAssertTrue(app.buttons["detail-play"].waitForExistence(timeout: 30), "搜索结果无法进入详情")
            snap("06-搜索结果详情")
        }
    }

    // MARK: - 3 直播

    func test03_Live() throws {
        goHome("直播")

        let channels = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "channel-"))
        _ = channels.firstMatch.waitForExistence(timeout: 45)
        sleep(10)                        // 等频道列表 + 起播
        snap("07-直播")
        XCTAssertTrue(channels.count > 0, "直播频道列表为空")
    }

    // MARK: - 4 网盘

    func test04_Drive() throws {
        goHome("网盘")

        sleep(3)
        // 添加入口始终存在; 已配置网盘时展示列表, 否则展示空态
        XCTAssertTrue(app.buttons["drive-add"].waitForExistence(timeout: 10), "网盘页缺少添加入口")
        let emptyState = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "还没有添加网盘")).firstMatch
        snap(emptyState.exists ? "08-网盘-空态" : "08-网盘-列表")
    }

    // MARK: - 5 收藏 / 历史 / 设置

    func test05_CollectHistorySettings() throws {
        goHome("收藏")
        XCTAssertTrue(app.staticTexts["收藏"].waitForExistence(timeout: 15), "收藏页未打开")
        sleep(1)
        snap("09-收藏")
        tapBack()

        waitHome("历史")
        tapFunction("历史")
        XCTAssertTrue(app.staticTexts["观看历史"].waitForExistence(timeout: 15), "历史页未打开")
        sleep(1)
        snap("10-历史")

        // 有观看记录时应能续播进入详情 (test01 播放过, 因此这里应有记录)
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "history-row-"))
        if rows.count > 0 {
            rows.element(boundBy: 0).tap()
            XCTAssertTrue(app.buttons["detail-play"].waitForExistence(timeout: 30), "历史记录无法进入详情续播")
            snap("10b-历史续播")
            tapBack()
        } else {
            XCTFail("历史列表为空(播放历史未写入)")
        }
        tapBack()

        waitHome("设置")
        tapFunction("设置")
        XCTAssertTrue(app.staticTexts["设置"].waitForExistence(timeout: 15), "设置页未打开")
        sleep(2)
        snap("11-设置")
        XCTAssertTrue(cap("清空搜索历史 (0)").exists || app.staticTexts["数据管理"].exists,
                      "设置页缺少数据管理区块")
    }
}
