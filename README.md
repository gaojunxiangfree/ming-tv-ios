# 茗影院 iOS 版

与安卓版 [ming-tv](https://github.com/gaojunxiangfree/ming-tv) 同源的 iOS 客户端。
基于 **SwiftUI + AVPlayer**,兼容 TVBox / 苹果CMS 采集接口,自带直播、网盘与全源聚合搜索。

## 功能

| 模块 | 说明 |
| --- | --- |
| 首页 | 站点切换、分类 Tab、海报网格(自适应列数)、分页、下拉刷新 |
| 详情 | 线路优选(直链线路优先)、选集 30 集分区收纳、倒序、收藏 |
| 播放 | 选集抽屉、倍速 0.5–2.0x、±10s、上下集、循环、**音轨切换**、**横屏全屏键** |
| 直播 | 接口自带 + 内置兜底源、分组/频道、EPG 时间轴、每频道独立 UA |
| 搜索 | 全源并发聚合、增量回填、来源筛选、历史 20 条 |
| 网盘 | WebDAV(PROPFIND)/ AList(登录 + 公共路径),可直接播放网盘媒体 |
| 数据 | 观看历史(续播)、收藏、设置(接口源 / 播放 / 开屏页) |

## 技术要点

- **防盗链请求头**：AVPlayer 没有 ExoPlayer 的 `setDefaultRequestProperties`。
  实测四种方案后采用 `AVURLAssetHTTPHeaderFieldsKey` 注入 Referer / Cookie / Authorization,
  **播放列表与分片请求同样生效**,无需自定义 scheme 中转。
- **m3u8 去广告**：对齐安卓 `AdFilterDataSource` 的规则(SCTE-35 区间 + 广告关键字分片)。
  因 AVPlayer 不加载 `file://` 播放列表,采用**仅转发播放列表**的本地 HTTP 服务,
  分片仍由播放器直连远端以保留自适应码率;多码率主列表不改写。
- **工程组织**：核心逻辑层 `MingTVCore` 为独立 Swift Package,
  同时被 iOS App 与 macOS 命令行 `validate`(技术验证工具)复用。
- **Xcode 工程**由 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 从 `ios/project.yml` 生成。

## 目录结构

```
Sources/MingTVCore/     核心逻辑(接口/线路/直播/EPG/网盘/去广告),iOS 与 macOS 共用
Sources/Validate/       macOS 技术验证 CLI(源可用性、线路优选、播放链路)
ios/project.yml         XcodeGen 工程定义
ios/MingTV/Sources/     iOS App 源码(SwiftUI)
ios/MingTVUITests/      逐屏冒烟测试(XCUITest)
ios/icons/              App 图标矢量源文件
```

## 环境与构建

- 需要 **Xcode 16+**,部署目标 **iOS 17+**

```bash
cd ios
xcodegen generate        # 依据 project.yml 生成 MingTV.xcodeproj
open MingTV.xcodeproj    # 或 xcodebuild -scheme MingTV build
```

核心层单独验证(无需 Xcode 工程,直接跑真实链路):

```bash
swift run validate
```

跑逐屏冒烟测试:

```bash
cd ios && xcodebuild test -scheme MingTV \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

真机安装(需先提供 DEVELOPMENT_TEAM):

```bash
cd ios
xcodebuild build -project MingTV.xcodeproj -scheme MingTV \
  -destination 'platform=iOS,id=<设备UDID>' \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=<TeamID>
xcrun devicectl device install app --device <设备UDID> \
  build/Build/Products/Debug-iphoneos/MingTV.app
```

## 已知限制

- 仅支持 **type 0/1 的苹果CMS 采集源**;安卓版的 jar / drpy 爬虫源依赖
  DexClassLoader / QuickJS,iOS 无法运行
- iOS 无 FFmpeg 内核,网盘中的 **mkv / avi / flv / webm 无法播放**(已在界面标注)
- 局域网推送配置(9753)、扫码、DLNA 投屏接收、弹幕暂未实现
- 免费 Apple ID 签名 **7 天过期**,且只能安装在自己已信任的设备上

## 免责声明

本应用由 Sean Gao 开源,**仅供开发与测试使用,禁止商用,违者后果自负**。
所有影视内容均来自第三方采集接口,本项目不存储、不传播任何资源。
