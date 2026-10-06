// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MingTViOS",
    // macOS 用于跑 Validate 验证链路; iOS 17 供 SwiftUI App 复用同一份核心逻辑
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [
        .library(name: "MingTVCore", targets: ["MingTVCore"]),
        .executable(name: "validate", targets: ["Validate"]),
    ],
    targets: [
        // 核心逻辑层: 对应 Android 版 bean/ + api/ + util/, iOS App 直接复用
        .target(name: "MingTVCore"),

        // 技术验证入口: 在 macOS 上跑真实链路 (AVFoundation 与 iOS 同 API)
        .executableTarget(name: "Validate", dependencies: ["MingTVCore"]),
    ]
)
