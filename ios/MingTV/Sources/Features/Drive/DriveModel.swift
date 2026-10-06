import Foundation
import MingTVCore
import Observation

/// 播放前置失败 (用于把原因直接展示给用户)
struct PlaybackFailure: Error {
    let message: String
}

/// 网盘浏览 (对应 Android: DriveActivity)
@MainActor
@Observable
final class DriveModel {

    private(set) var drives: [StorageDrive] = []
    private(set) var files: [DriveFile] = []
    private(set) var loading = false
    private(set) var error: String?

    /// 当前展开的网盘下标(-1 = 未选择)
    private(set) var selectedDriveIndex = -1
    /// 当前目录 (相对网盘根)
    private(set) var path = "/"
    /// 目录栈, 用于返回上级
    private var stack: [String] = []

    private var api: DriveApi?

    var currentDrive: StorageDrive? {
        drives.indices.contains(selectedDriveIndex) ? drives[selectedDriveIndex] : nil
    }

    var canGoUp: Bool { !stack.isEmpty }

    // MARK: - 网盘管理

    func loadDrives() async {
        drives = Persistence.loadDrives()
        guard !drives.isEmpty else {
            selectedDriveIndex = -1
            files = []
            return
        }
        await selectDrive(0)
    }

    func addDrive(_ drive: StorageDrive) {
        var d = drive
        d.id = (drives.map(\.id).max() ?? 0) + 1
        drives.append(d)
        save()
        Task { await selectDrive(drives.count - 1) }
    }

    func removeDrive(_ drive: StorageDrive) {
        drives.removeAll { $0.id == drive.id }
        save()
        if drives.isEmpty {
            selectedDriveIndex = -1
            files = []
            api = nil
            path = "/"
            stack = []
        } else {
            Task { await selectDrive(0) }
        }
    }

    private func save() { Persistence.saveDrives(drives) }

    // MARK: - 浏览

    func selectDrive(_ index: Int) async {
        guard drives.indices.contains(index) else { return }
        selectedDriveIndex = index
        api = DriveApi(drive: drives[index])
        path = drives[index].initPath
        if !path.hasPrefix("/") { path = "/" + path }
        stack = []
        await reload()
    }

    func enter(_ file: DriveFile) async {
        guard file.isDirectory else { return }
        stack.append(path)
        path = file.path
        await reload()
    }

    func goUp() async {
        guard let prev = stack.popLast() else { return }
        path = prev
        await reload()
    }

    func refresh() async {
        await reload()
    }

    private func reload() async {
        guard let api else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            files = try await api.list(path)
            if files.isEmpty { error = "该目录为空" }
        } catch {
            files = []
            self.error = "\(error)"
        }
    }

    // MARK: - 播放

    /// 解析网盘文件为播放请求. 返回错误文案而非抛出, 便于直接展示.
    func makePlayTarget(for file: DriveFile) async -> Result<PlayTarget, PlaybackFailure> {
        guard let api else { return .failure(PlaybackFailure(message: "未选择网盘")) }
        guard file.isAVPlayable else {
            return .failure(PlaybackFailure(
                message: "iOS 播放器不支持 .\(file.ext) 格式（安卓版由 IJK 内核兜底，iOS 无对应内核）"))
        }
        do {
            let resolved = try await api.resolve(file)
            let vod = Vod(vod_id: file.path, vod_name: file.name, vod_remarks: file.sizeText)
            let line = PlayLine(flag: "网盘", episodes: [Episode(title: file.name, url: resolved.url)])
            return .success(PlayTarget(siteKey: "_drive",
                                       vod: vod,
                                       line: line,
                                       startIndex: 0,
                                       extraHeaders: resolved.headers))
        } catch {
            return .failure(PlaybackFailure(message: "\(error)"))
        }
    }
}
