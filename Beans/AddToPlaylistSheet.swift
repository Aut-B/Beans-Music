import SwiftUI

/// 统一的「添加到歌单」面板。
///
/// 两栏：
/// - **本机歌单**：任何来源的曲目都能进（网易云 / QQ / 酷狗 / 插件音源），
///   歌单存在设备里，可以随 WebDAV 同步。
/// - **网易云歌单**：写回网易云账号。只有**网易云来源**的曲目能入库——
///   云端接口按网易云 songId 认歌，把 QQ 或 B 站的 id 传进去只会写错歌，
///   所以非网易云曲目（以及未登录时）这一栏直接不显示。
///
/// 原先分成了两个面板（`AddToPlaylistSheet` 只管网易云、`AddToLocalPlaylistSheet`
/// 只管本机），从各入口点进去看到的东西不一样，容易以为"只能加进本机歌单"。
/// 现在合并成一个，两边的歌单同屏可选。
struct AddToPlaylistSheet: View {
    @ObservedObject private var store = LocalLibraryStore.shared
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var auth: AuthStore
    @Environment(\.dismiss) private var dismiss

    let song: Song

    @State private var showCreateLocal = false
    @State private var newLocalName = ""
    @State private var showCreateCloud = false
    @State private var newCloudName = ""
    @State private var message: String?
    @State private var busy = false

    /// 网易云曲目才允许写进网易云歌单。
    /// 插件音源里也有名字叫「网易云」的插件，但那些条目的 id 是插件自己的字符串 id，
    /// 云端接口不认，所以判据只看 `song.source`。
    private var canUseCloud: Bool { song.source == .netease }

    var body: some View {
        let _ = theme.accent
        BeansNavigationStack {
            List {
                localSection
                if canUseCloud { cloudSection }
                if !canUseCloud { cloudUnavailableHint }
                if let message {
                    Section {
                        Text(message)
                            .font(BeansFont.appFont(13))
                            .foregroundStyle(Color.beansSage)
                    }
                }
            }
            .navigationTitle("添加到歌单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .modifier(BeansSheetModifier(detents: [.medium, .large], dragIndicator: true))
        .onAppear {
            // 本机一个歌单都没有、又用不上云端歌单时，保持原来"一键存进我的收藏歌单"的便捷路径。
            guard store.playlists.isEmpty, !canUseCloud else { return }
            ToastCenter.shared.show(store.addToDefaultFavorites(song))
            BeansHaptics.success()
            dismiss()
        }
    }

    // MARK: - 本机歌单

    @ViewBuilder
    private var localSection: some View {
        if store.playlists.isEmpty {
            Section("本机歌单") {
                Text("还没有本机歌单，创建一个吧")
                    .font(BeansFont.appFont(13))
                    .foregroundStyle(Color.beansComment)
            }
        } else {
            Section {
                ForEach(store.playlists) { playlist in
                    Button {
                        store.addSong(song, to: playlist.id)
                        BeansHaptics.success()
                        ToastCenter.shared.show("已加入「\(playlist.name)」")
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(LinearGradient(
                                        colors: [Color.beansAmber.opacity(0.75), Color.beansAmber.opacity(0.35)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ))
                                    .frame(width: 40, height: 40)
                                Image(systemName: "music.note.list")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.white)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(playlist.name)
                                    .font(BeansFont.appFont(15, .medium))
                                    .foregroundStyle(Color.beansLabel)
                                    .lineLimit(1)
                                Text(beansLocalSongCountText(playlist.songs.count))
                                    .font(BeansFont.appFont(11))
                                    .foregroundStyle(Color.beansComment)
                            }
                            Spacer()
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 15))
                                .foregroundStyle(Color.beansAmber)
                        }
                    }
                    .disabled(busy)
                }
            } header: {
                Text("本机歌单")
            } footer: {
                Text("存在这台设备上，网易云 / QQ / 酷狗 / 插件音源的歌都能放进来。")
            }
        }

        if showCreateLocal {
            Section("新建本机歌单") {
                TextField("歌单名称", text: $newLocalName)
                    .submitLabel(.done)
                Button {
                    createLocalAndAdd()
                } label: {
                    Text("创建并加入")
                        .font(BeansFont.appFont(15, .semibold))
                        .foregroundStyle(Color.beansAmber)
                }
            }
        } else {
            Section {
                Button {
                    showCreateLocal = true
                } label: {
                    Label("新建本机歌单并加入", systemImage: "plus.circle")
                }
                .disabled(busy)
            }
        }
    }

    // MARK: - 网易云歌单

    @ViewBuilder
    private var cloudSection: some View {
        if !auth.isLoggedIn {
            Section("网易云歌单") {
                Text("登录网易云后，可以直接把这首歌存进你的网易云歌单。")
                    .font(BeansFont.appFont(13))
                    .foregroundStyle(Color.beansComment)
            }
        } else if auth.playlists.isEmpty {
            Section("网易云歌单") {
                Text("账号里还没有歌单，可以在下面新建一个")
                    .font(BeansFont.appFont(13))
                    .foregroundStyle(Color.beansComment)
            }
        } else {
            Section {
                ForEach(auth.playlists) { playlist in
                    Button {
                        Task { await add(to: playlist) }
                    } label: {
                        HStack(spacing: 12) {
                            CoverImage(url: playlist.coverURL, size: 40, cornerRadius: 10)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(playlist.name)
                                    .font(BeansFont.appFont(15, .medium))
                                    .foregroundStyle(Color.beansLabel)
                                    .lineLimit(1)
                                Text(beansSongCountText(playlist.trackCount))
                                    .font(BeansFont.appFont(11))
                                    .foregroundStyle(Color.beansComment)
                            }
                            Spacer()
                            Image(systemName: "icloud.and.arrow.up")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.beansSage)
                        }
                    }
                    .disabled(busy)
                }
            } header: {
                Text("网易云歌单")
            } footer: {
                Text("直接写回网易云账号，换设备登录后也能看到。")
            }
        }

        if auth.isLoggedIn {
            if showCreateCloud {
                Section("新建网易云歌单") {
                    TextField("歌单名称", text: $newCloudName)
                        .submitLabel(.done)
                    Button {
                        Task { await createCloudAndAdd() }
                    } label: {
                        Text("创建并加入")
                            .font(BeansFont.appFont(15, .semibold))
                            .foregroundStyle(Color.beansAmber)
                    }
                    .disabled(busy)
                }
            } else {
                Section {
                    Button {
                        showCreateCloud = true
                    } label: {
                        Label("新建网易云歌单并加入", systemImage: "plus.circle")
                    }
                    .disabled(busy)
                }
            }
        }
    }

    /// 分开写而不是直接塞进 `Text(...)` 的三元表达式：
    /// 两个字符串字面量的三元式会让 `Text(LocalizedStringKey)` 与
    /// `Text(StringProtocol)` 撞在一起，编译期报歧义。
    private var cloudUnavailableText: LocalizedStringKey {
        song.source == .plugin
            ? "这首歌来自插件音源（如哔哩哔哩），网易云歌单里没有对应曲目，只能存进本机歌单。"
            : "这首歌来自其他平台，网易云歌单里没有对应曲目，只能存进本机歌单。"
    }

    private var cloudUnavailableHint: some View {
        Section {
            Text(cloudUnavailableText)
                .font(BeansFont.appFont(12))
                .foregroundStyle(Color.beansComment)
        } header: {
            Text("关于网易云歌单")
        }
    }

    // MARK: - 动作

    private func createLocalAndAdd() {
        let name = newLocalName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let playlist = store.createPlaylist(name: name)
        store.addSong(song, to: playlist.id)
        BeansHaptics.success()
        ToastCenter.shared.show("已创建并加入「\(name)」")
        dismiss()
    }

    private func add(to playlist: Playlist) async {
        busy = true
        defer { busy = false }
        do {
            let ok = try await NetEaseAPI.shared.addToPlaylist(playlistID: playlist.id, songIDs: [song.id])
            if ok {
                BeansHaptics.success()
                ToastCenter.shared.show("已加入网易云歌单「\(playlist.name)」")
                await auth.loadLibrary(force: true)
                dismiss()
            } else {
                message = "添加失败，请确认这张网易云歌单是你自己创建的"
            }
        } catch {
            message = error.localizedDescription
        }
    }

    private func createCloudAndAdd() async {
        let name = newCloudName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        busy = true
        defer { busy = false }
        do {
            let playlistID = try await NetEaseAPI.shared.createPlaylist(name: name)
            let ok = try await NetEaseAPI.shared.addToPlaylist(playlistID: playlistID, songIDs: [song.id])
            if ok {
                BeansHaptics.success()
                ToastCenter.shared.show("已创建并加入「\(name)」")
                await auth.loadLibrary(force: true)
                dismiss()
            } else {
                message = "歌单已创建，但歌曲没有加进去，请稍后重试"
            }
        } catch {
            message = error.localizedDescription
        }
    }
}
