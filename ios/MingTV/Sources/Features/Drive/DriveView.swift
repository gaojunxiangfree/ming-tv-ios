import SwiftUI
import MingTVCore

/// 网盘页 (对应 Android: DriveActivity)
/// 支持 WebDAV (PROPFIND) 与 AList (账号登录 / 公共路径), 可直接播放网盘内的媒体文件.
struct DriveView: View {
    @Environment(\.dismiss) private var dismiss

    let onPlay: (PlayTarget) -> Void

    @State private var model = DriveModel()
    @State private var showAdd = false
    @State private var message: String?
    @State private var resolvingPath: String?

    var body: some View {
        ZStack {
            SM.bgGradient.ignoresSafeArea()

            VStack(spacing: 0) {
                TopBar(title: "网盘", subtitle: pathSubtitle, onBack: { dismiss() }) {
                    Button {
                        showAdd = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(SM.text)
                            .frame(width: 34, height: 34)
                            .background(SM.surfaceLight, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("drive-add")
                }

                if model.drives.isEmpty {
                    EmptyState(icon: "externaldrive.badge.icloud",
                               text: "还没有添加网盘\n支持 WebDAV 与 AList",
                               actionTitle: "添加网盘") { showAdd = true }
                } else {
                    driveRow
                    pathBar
                    fileList
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .task { await model.loadDrives() }
        .sheet(isPresented: $showAdd) {
            AddDriveSheet { model.addDrive($0) }
        }
        .alert("提示", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("知道了", role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    private var pathSubtitle: String? {
        guard let drive = model.currentDrive else { return nil }
        return "\(drive.isWebDAV ? "WebDAV" : "AList") · \(drive.name)"
    }

    // MARK: - 网盘切换

    private var driveRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(model.drives.enumerated()), id: \.element.id) { idx, drive in
                    CapsuleButton(title: drive.name, selected: idx == model.selectedDriveIndex) {
                        Task { await model.selectDrive(idx) }
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            model.removeDrive(drive)
                        } label: { Label("删除网盘", systemImage: "trash") }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 8)
    }

    // MARK: - 路径栏

    private var pathBar: some View {
        HStack(spacing: 10) {
            Button {
                Task { await model.goUp() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.up")
                    Text("上级")
                }
                .font(SMFont.small)
                .foregroundStyle(model.canGoUp ? SM.text : SM.textDim)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(SM.surfaceLight, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!model.canGoUp)

            Text(model.path)
                .font(SMFont.tiny)
                .foregroundStyle(SM.textDim)
                .lineLimit(1)

            Spacer(minLength: 0)

            if model.loading {
                ProgressView().tint(SM.primary).scaleEffect(0.8)
            } else {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 13)).foregroundStyle(SM.textDim)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: - 文件列表

    @ViewBuilder
    private var fileList: some View {
        if let err = model.error, model.files.isEmpty {
            EmptyState(icon: "folder.badge.questionmark", text: err, actionTitle: "重试") {
                Task { await model.refresh() }
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(model.files) { file in
                        fileRow(file)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
    }

    private func fileRow(_ file: DriveFile) -> some View {
        Button {
            handleTap(file)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: iconName(for: file))
                    .font(.system(size: 18))
                    .foregroundStyle(file.isDirectory ? SM.primary : (file.isMedia ? SM.gold : SM.textDim))
                    .frame(width: 26)

                VStack(alignment: .leading, spacing: 3) {
                    Text(file.name)
                        .font(SMFont.small)
                        .foregroundStyle(SM.text)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        if !file.sizeText.isEmpty {
                            Text(file.sizeText).font(SMFont.tiny).foregroundStyle(SM.textDim)
                        }
                        if !file.isDirectory, !file.isAVPlayable, file.isMedia {
                            Text("iOS 不支持").font(SMFont.tiny).foregroundStyle(Color(hex: 0xFF8A8A))
                        }
                        if let d = file.modified {
                            Text(Self.dateText(d)).font(SMFont.tiny).foregroundStyle(SM.textDim)
                        }
                    }
                }

                Spacer(minLength: 0)

                if resolvingPath == file.path {
                    ProgressView().tint(SM.primary).scaleEffect(0.8)
                } else if !file.isDirectory {
                    Image(systemName: "play.circle")
                        .font(.system(size: 16))
                        .foregroundStyle(file.isMedia ? SM.primary : SM.textDim)
                }
            }
            .padding(12)
            .smCard(cornerRadius: 10)
        }
        .buttonStyle(.plain)
    }

    private func iconName(for file: DriveFile) -> String {
        if file.isDirectory { return "folder.fill" }
        if file.isMedia { return "film" }
        return "doc"
    }

    private func handleTap(_ file: DriveFile) {
        if file.isDirectory {
            Task { await model.enter(file) }
            return
        }
        guard file.isMedia else {
            message = "该文件不是媒体文件，无法播放"
            return
        }
        guard file.isAVPlayable else {
            message = "iOS 播放器不支持 .\(file.ext) 格式\n（安卓版由 IJK 内核兜底，iOS 无对应内核）"
            return
        }
        resolvingPath = file.path
        Task {
            let result = await model.makePlayTarget(for: file)
            resolvingPath = nil
            switch result {
            case .success(let target):
                onPlay(target)
            case .failure(let err):
                message = err.message
            }
        }
    }

    private static func dateText(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: d)
    }
}

// MARK: - 添加网盘 (对应 Android: dialog_drive_add.xml)

struct AddDriveSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onAdd: (StorageDrive) -> Void

    @State private var name = ""
    @State private var type = StorageDrive.typeWebDAV
    @State private var url = ""
    @State private var username = ""
    @State private var password = ""
    @State private var initPath = "/"
    @State private var validation: String?

    var body: some View {
        NavigationStack {
            ZStack {
                SM.bg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        field("名称", text: $name, placeholder: "我的网盘")

                        VStack(alignment: .leading, spacing: 8) {
                            Text("类型").font(SMFont.small).foregroundStyle(SM.textDim)
                            Picker("", selection: $type) {
                                Text("WebDAV").tag(StorageDrive.typeWebDAV)
                                Text("AList").tag(StorageDrive.typeAList)
                            }
                            .pickerStyle(.segmented)
                        }

                        field("地址", text: $url, placeholder: type == StorageDrive.typeWebDAV
                              ? "https://dav.example.com/dav/" : "https://alist.example.com/")
                        field("用户名", text: $username, placeholder: "可留空（公开访问）")
                        field("密码", text: $password, placeholder: "可留空", secure: true)
                        field("初始目录", text: $initPath, placeholder: "/")

                        if let validation {
                            Text(validation)
                                .font(SMFont.tiny)
                                .foregroundStyle(Color(hex: 0xFF8A8A))
                        }

                        Button("保存") { save() }
                            .font(SMFont.body.weight(.semibold))
                            .foregroundStyle(SM.bg)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(SM.accentGradient, in: Capsule())
                            .buttonStyle(.plain)

                        Text("WebDAV 使用 PROPFIND 列目录并走 Basic 认证；AList 会先尝试账号登录，失败则回退公共路径。")
                            .font(SMFont.tiny)
                            .foregroundStyle(SM.textDim)
                    }
                    .padding(16)
                }
            }
            .navigationTitle("添加网盘")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private func field(_ label: String, text: Binding<String>,
                       placeholder: String, secure: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(SMFont.small).foregroundStyle(SM.textDim)
            Group {
                if secure {
                    SecureField(placeholder, text: text)
                } else {
                    TextField(placeholder, text: text)
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .foregroundStyle(SM.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(SM.surfaceLight, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func save() {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { validation = "请填写地址"; return }
        let finalName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        onAdd(StorageDrive(name: finalName.isEmpty ? trimmedURL : finalName,
                           type: type,
                           url: trimmedURL,
                           username: username.trimmingCharacters(in: .whitespaces),
                           password: password,
                           initPath: initPath.trimmingCharacters(in: .whitespaces)))
        dismiss()
    }
}
