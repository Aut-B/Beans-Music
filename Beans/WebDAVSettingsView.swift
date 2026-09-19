import SwiftUI

// MARK: - WebDAV 歌单同步设置
//
// 本机歌单是整个 App 唯一的「跨平台歌单」：网易云、QQ音乐、酷狗音乐、插件音源
// 的歌曲都能放进去。这个页面把它备份到用户自己的 WebDAV 网盘（坚果云、群晖、
// NextCloud…），换机或重装后一键恢复；也能直接下载云端已有的 MusicFree 备份
// 或歌单 JSON 导入进来。

struct WebDAVSettingsView: View {
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var sync = WebDAVSyncStore.shared
    @ObservedObject private var library = LocalLibraryStore.shared

    @State private var showReplaceConfirm = false
    @State private var importingEntry: WebDAVEntry?

    private var songCount: Int {
        library.playlists.reduce(0) { $0 + $1.songs.count }
    }

    var body: some View {
        let _ = theme.accent
        NavigationView {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    introCard
                    connectionCard
                    actionCard
                    remoteFilesCard
                    statusCard
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
            }
            .background(GlassBackdrop())
            .navigationTitle(beansLocalized("歌单 WebDAV 同步", "Playlist WebDAV Sync"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(beansLocalized("完成", "Done")) {
                        sync.saveConfig()
                        dismiss()
                    }
                }
            }
            .onDisappear { sync.saveConfig() }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - 卡片

    private var introCard: some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                Text(beansLocalized("把本机歌单存到自己的网盘", "Back up local playlists to your own cloud"))
                    .font(BeansFont.appFont(15, .semibold))
                    .foregroundStyle(Color.beansLabel)
                Text(beansLocalized(
                    "本机歌单可以混装网易云、QQ音乐、酷狗音乐和插件音源的歌曲。填好 WebDAV 后上传一次，换设备或重装时用「从云端合并」就能拿回来。",
                    "A local playlist can mix NetEase, QQ, Kugou and plugin tracks. Upload once, then use “Merge from cloud” after switching devices."
                ))
                    .font(BeansFont.appFont(12))
                    .foregroundStyle(Color.beansComment)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Image(systemName: "music.note.list")
                    Text(beansLocalized("当前 \(library.playlists.count) 个歌单 · \(songCount) 首", "\(library.playlists.count) playlists · \(songCount) songs"))
                }
                    .font(BeansFont.appFont(12, .medium))
                    .foregroundStyle(Color.beansAmber)
            }
        }
    }

    private var connectionCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                Text(beansLocalized("服务器", "Server"))
                    .font(BeansFont.appFont(14, .semibold))
                    .foregroundStyle(Color.beansLabel)

                field(icon: "link", placeholder: "https://dav.jianguoyun.com/dav/", text: $sync.config.server, secure: false)
                field(icon: "person", placeholder: beansLocalized("账号", "Account"), text: $sync.config.username, secure: false)
                field(icon: "lock", placeholder: beansLocalized("密码 / 应用密码", "Password / App password"), text: $sync.config.password, secure: true)
                field(icon: "folder", placeholder: beansLocalized("目录名（默认 Beans）", "Folder name (default Beans)"), text: $sync.config.folder, secure: false)

                Toggle(isOn: $sync.autoSync) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(beansLocalized("改动后自动上传", "Auto upload after changes"))
                            .font(BeansFont.appFont(13, .medium))
                            .foregroundStyle(Color.beansLabel)
                        Text(beansLocalized("每次增删本机歌单后静默上传一次", "Silently uploads after each playlist change"))
                            .font(BeansFont.appFont(11))
                            .foregroundStyle(Color.beansComment)
                    }
                }
                .tint(Color.beansAmber)
                .onChange(of: sync.autoSync) { _ in sync.saveConfig() }

                Button {
                    BeansHaptics.tap()
                    sync.saveConfig()
                    Task { await sync.testConnection() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                        Text(beansLocalized("保存并测试连接", "Save & test connection"))
                    }
                    .font(BeansFont.appFont(13, .semibold))
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.black, in: Capsule())
                }
                .buttonStyle(GlassPressButtonStyle(scale: 0.97))
                .disabled(sync.status.isWorking)
            }
        }
    }

    private var actionCard: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                Text(beansLocalized("同步", "Sync"))
                    .font(BeansFont.appFont(14, .semibold))
                    .foregroundStyle(Color.beansLabel)

                // 重复歌曲的处理方式：跳过（反复导入不堆重复）或替换（把别处修好的条目带回来）。
                VStack(alignment: .leading, spacing: 6) {
                    Text(beansLocalized("导入时遇到重复的歌曲", "When importing duplicate songs"))
                        .font(BeansFont.appFont(13, .medium))
                        .foregroundStyle(Color.beansLabel)
                    Picker("", selection: $sync.duplicatePolicy) {
                        ForEach(LocalLibraryStore.ImportDuplicatePolicy.allCases, id: \.rawValue) { policy in
                            Text(policy.label).tag(policy)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(beansLocalized(
                        "同一首歌 = 来源标识相同，或歌名相同且时长差在 5 秒内。「跳过」保留本机版本，「替换」用导入的版本覆盖本机。",
                        "A duplicate is the same source ID, or same title within 5 seconds of duration. Skip keeps the local version; Replace overwrites it with the imported one."
                    ))
                        .font(BeansFont.appFont(11))
                        .foregroundStyle(Color.beansComment)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.bottom, 2)

                actionButton(
                    title: beansLocalized("上传本机歌单到云端", "Upload local playlists"),
                    icon: "arrow.up.to.line",
                    tint: Color.beansAmber
                ) {
                    await run {
                        let count = try await sync.upload()
                        return beansLocalized("已上传 \(count) 个歌单", "Uploaded \(count) playlists")
                    }
                }

                actionButton(
                    title: beansLocalized("从云端合并到本机", "Merge from cloud"),
                    icon: "arrow.down.to.line",
                    tint: Color.beansSage
                ) {
                    await run {
                        let result = try await sync.downloadAndMerge()
                        return beansLocalized(
                            "新增 \(result.playlists) 个歌单、\(result.songs) 首歌曲",
                            "Added \(result.playlists) playlists, \(result.songs) songs"
                        )
                    }
                }

                Button {
                    BeansHaptics.tap()
                    showReplaceConfirm = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                        Text(beansLocalized("用云端覆盖本机（会清空本机歌单）", "Replace local with cloud"))
                    }
                    .font(BeansFont.appFont(13, .medium))
                    .foregroundStyle(Color.red.opacity(0.85))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.red.opacity(0.10), in: Capsule())
                }
                .buttonStyle(GlassPressButtonStyle(scale: 0.97))
                .disabled(sync.status.isWorking)
            }
        }
        .confirmationDialog(
            beansLocalized("确定用云端快照替换本机歌单吗？本机歌单会被清空，且无法撤销。",
                           "Replace local playlists with the cloud snapshot? This cannot be undone."),
            isPresented: $showReplaceConfirm,
            titleVisibility: .visible
        ) {
            Button(beansLocalized("替换", "Replace"), role: .destructive) {
                Task {
                    await run {
                        let count = try await sync.downloadAndReplace()
                        return beansLocalized("已用云端 \(count) 个歌单替换本机", "Replaced local with \(count) playlists")
                    }
                }
            }
            Button(beansLocalized("取消", "Cancel"), role: .cancel) {}
        }
    }

    private var remoteFilesCard: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(beansLocalized("云端文件", "Cloud files"))
                        .font(BeansFont.appFont(14, .semibold))
                        .foregroundStyle(Color.beansLabel)
                    Spacer()
                    Button {
                        Task { await sync.refreshRemoteList() }
                    } label: {
                        Text(beansLocalized("刷新", "Refresh"))
                            .font(BeansFont.appFont(12, .medium))
                            .foregroundStyle(Color.beansAmber)
                    }
                    .buttonStyle(.plain)
                }
                Text(beansLocalized(
                    "可以把 MusicFree 导出的备份 / 歌单 JSON 放到这个目录，然后点一下导入。",
                    "Drop a MusicFree backup or playlist JSON in this folder, then tap to import."
                ))
                    .font(BeansFont.appFont(11))
                    .foregroundStyle(Color.beansComment)
                    .fixedSize(horizontal: false, vertical: true)

                if sync.remoteEntries.isEmpty {
                    Text(beansLocalized("还没有列出文件，点右上「刷新」或先测试连接。", "No files listed yet — tap Refresh."))
                        .font(BeansFont.appFont(12))
                        .foregroundStyle(Color.beansComment)
                } else {
                    VStack(spacing: 0) {
                        ForEach(sync.remoteEntries) { entry in
                            Button {
                                guard !entry.isDirectory else { return }
                                BeansHaptics.tap()
                                importingEntry = entry
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: entry.isDirectory ? "folder" : "doc.text")
                                        .font(.system(size: 14))
                                        .foregroundStyle(entry.isDirectory ? Color.beansAmber : Color.beansComment)
                                        .frame(width: 22)
                                    Text(entry.name)
                                        .font(BeansFont.appFont(13))
                                        .foregroundStyle(Color.beansLabel)
                                        .lineLimit(1)
                                    Spacer(minLength: 8)
                                    if let size = entry.size, !entry.isDirectory {
                                        Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                                            .font(BeansFont.appFont(11))
                                            .foregroundStyle(Color.beansComment)
                                    }
                                }
                                .padding(.vertical, 9)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(entry.isDirectory || sync.status.isWorking)
                            Divider().overlay(Color.beansComment.opacity(0.12))
                        }
                    }
                }
            }
        }
        .confirmationDialog(
            beansLocalized("把「\(importingEntry?.name ?? "")」导入本机歌单？", "Import this file into local playlists?"),
            isPresented: Binding(
                get: { importingEntry != nil },
                set: { if !$0 { importingEntry = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let entry = importingEntry {
                Button(beansLocalized("导入", "Import")) {
                    importingEntry = nil
                    Task {
                        await run {
                            let result = try await sync.importRemoteFile(entry)
                            return beansLocalized(
                                "已导入 \(result.playlists) 个歌单、\(result.songs) 首歌曲",
                                "Imported \(result.playlists) playlists, \(result.songs) songs"
                            )
                        }
                    }
                }
            }
            Button(beansLocalized("取消", "Cancel"), role: .cancel) { importingEntry = nil }
        }
    }

    @ViewBuilder
    private var statusCard: some View {
        switch sync.status {
        case .idle:
            EmptyView()
        case .working(let text):
            card {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(text)
                        .font(BeansFont.appFont(13))
                        .foregroundStyle(Color.beansComment)
                }
            }
        case .success(let text, _):
            card {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.beansSage)
                    Text(text)
                        .font(BeansFont.appFont(13))
                        .foregroundStyle(Color.beansLabel)
                }
            }
        case .failure(let text):
            card {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.red.opacity(0.8))
                    Text(text)
                        .font(BeansFont.appFont(13))
                        .foregroundStyle(Color.beansLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - 组件

    private func field(icon: String, placeholder: String, text: Binding<String>, secure: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(Color.beansComment)
                .frame(width: 18)
            if secure {
                SecureField(placeholder, text: text)
                    .font(BeansFont.appFont(13))
            } else {
                TextField(placeholder, text: text)
                    .font(BeansFont.appFont(13))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.beansComment.opacity(0.10))
        }
    }

    private func actionButton(title: String, icon: String, tint: Color,
                              action: @escaping () async -> Void) -> some View {
        Button {
            BeansHaptics.tap()
            sync.saveConfig()
            Task { await action() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                Text(title)
            }
            .font(BeansFont.appFont(13, .semibold))
            .foregroundStyle(Color.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(tint, in: Capsule())
        }
        .buttonStyle(GlassPressButtonStyle(scale: 0.97))
        .disabled(sync.status.isWorking)
    }

    private func card<Content: View>(@ViewBuilder _ builder: () -> Content) -> some View {
        builder()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                BeansGlass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            .beansCardShadow(radius: 8, y: 3)
    }

    /// 统一处理「进行中 → 成功 / 失败」的状态流转。
    private func run(_ operation: @escaping () async throws -> String) async {
        sync.setStatus(.working(beansLocalized("正在同步…", "Syncing…")))
        do {
            let message = try await operation()
            sync.setStatus(.success(message, Date()))
            BeansHaptics.success()
            ToastCenter.shared.show(message, duration: 3)
        } catch {
            sync.setStatus(.failure(error.localizedDescription))
        }
    }
}
