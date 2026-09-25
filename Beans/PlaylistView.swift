import SwiftUI

/// 歌单内排序方式
enum PlaylistSortMode: String, CaseIterable, Identifiable {
    case original = "默认"
    case name = "歌名"
    case artist = "歌手"
    case duration = "时长"
    var id: String { rawValue }
}

struct PlaylistView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var theme: ThemeStore
    @ObservedObject private var favorites = FavoritesStore.shared
    @ObservedObject private var localLibrary = LocalLibraryStore.shared

    let playlist: Playlist
    @State private var tracks: [Song] = []
    /// 搜索 + 排序后的结果。
    ///
    /// 原先它是个计算属性，body 每重算一次就要跑一遍 filter（O(n)）加 sort
    /// （O(n log n)）—— 搜索框每敲一个字符都会触发，千首歌单上就是肉眼可见的
    /// 输入延迟。改为跟着输入源的变化刷新一次。
    @State private var displayedTracks: [Song] = []
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var sortMode: PlaylistSortMode = .original
    @AppStorage("beans.homeHeaderHideSort") private var hideSortButton = false
    @AppStorage("beans.uiStyle") private var uiStyleRaw = BeansUIStyle.liquid.rawValue

    // MARK: 多选（照网易云歌单页：顶部汇总条 + 底部操作条）
    @State private var multiSelectMode = false
    @State private var selectedSongKeys: Set<String> = []
    @State private var showDeleteConfirm = false
    @State private var showCollectDialog = false
    @State private var downloading = false
    @State private var deleting = false

    /// 播放上下文令牌。整张歌单只登记一份，cell 之间只传这段短字符串。
    private var playbackContextKey: String { "playlist-\(playlist.source.rawValue)-\(playlist.id)" }

    /// 只有网易云支持把曲目从云端歌单里删掉（QQ / 酷狗只有创建与删除歌单的接口）。
    private var canDeleteFromCloud: Bool {
        playlist.source == .netease && auth.isLoggedIn
    }

    private var isNativeClean: Bool {
        BeansUIStyle(rawValue: uiStyleRaw) == .nativeClean
    }

    private var cacheAccountID: String {
        switch playlist.source {
        case .netease:
            return "\(auth.user?.uid ?? 0)"
        case .qq:
            let qqAuth = QQMusicAuth.shared
            return qqAuth.rawUin.isEmpty ? qqAuth.playlistUin : qqAuth.rawUin
        case .kugou:
            return KugouMusicAuth.shared.userId
        case .plugin:
            // 插件音源曲目不属于任何账号歌单，缓存键用平台名兜底。
            return "plugin"
        }
    }

    /// 多选按钮的无障碍标签。抽成 `String` 属性，避免两个字符串字面量的三元式
    /// 在 `Text`-类 init 之间撞出重载歧义。
    private var multiSelectToggleLabel: String {
        multiSelectMode ? "退出多选" : "多选编辑"
    }

    private var cloudDeleteConfirmMessage: String {
        "将从「\(playlist.name)」删除选中的 \(selectedSongKeys.count) 首歌曲，云端歌单也会同步变化。"
    }

    /// 「收藏到歌单」可选的本机歌单。
    private var collectableLocalPlaylists: [LocalPlaylist] {
        localLibrary.playlists
    }

    /// 可选的其他云端歌单。不是本人创建的歌单加歌必回 502，
    /// 所以昵称对得上时只列自己的；昵称拿不到就全列，宁可让用户看到真实报错。
    private var collectableCloudPlaylists: [Playlist] {
        guard playlist.source == .netease, auth.isLoggedIn else { return [] }
        let list = auth.playlists.filter { $0.id != playlist.id }
        guard let nickname = auth.user?.nickname, !nickname.isEmpty else { return list }
        let mine = list.filter { $0.creatorName.isEmpty || $0.creatorName == nickname }
        return mine.isEmpty ? list : mine
    }

    var body: some View {
        let _ = theme.accent
        ZStack {
                GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
                Group {
                if loading {
                    LoadingStateView()
                } else if let errorMessage {
                    ErrorStateView(message: errorMessage) {
                        Task { await load(force: true) }
                    }
                } else {
                    List {
                        header
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        if multiSelectMode {
                            Section {
                                PlaylistSelectionSummaryBar(
                                    selectedCount: selectedSongKeys.count,
                                    totalCount: displayedTracks.count,
                                    onToggleAll: toggleSelectAll
                                )
                            }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }
                        Section {
                            ForEach(Array(displayedTracks.enumerated()), id: \.element.identityKey) { index, song in
                                if multiSelectMode {
                                    HStack(spacing: 10) {
                                        Image(systemName: selectedSongKeys.contains(song.identityKey) ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 20, weight: .semibold))
                                            .foregroundStyle(selectedSongKeys.contains(song.identityKey) ? Color.beansAmber : Color.beansComment)
                                        SongCell(song: song, glassRow: true) {
                                            toggleSelection(song)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        toggleSelection(song)
                                    }
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                                } else {
                                    SongCell(song: song, glassRow: true, playbackContextKey: playbackContextKey, playbackIndex: index) {
                                        player.play(songs: displayedTracks, startAt: index)
                                    }
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        if canDeleteFromCloud {
                                            Button(role: .destructive) {
                                                BeansHaptics.tap()
                                                selectedSongKeys = [song.identityKey]
                                                showDeleteConfirm = true
                                            } label: {
                                                Label("从歌单删除", systemImage: "trash")
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .beansScrollContentBackgroundHidden()
                    .listStyle(.plain)
                    .safeAreaInset(edge: .bottom) {
                        if multiSelectMode {
                            PlaylistSelectionActionBar(
                                selectedCount: selectedSongKeys.count,
                                canDelete: canDeleteFromCloud,
                                onPlayNext: playSelectedNext,
                                onCollect: { showCollectDialog = true },
                                onDownload: downloadSelectedSongs,
                                onDelete: { showDeleteConfirm = true }
                            )
                            .padding(.horizontal, 12)
                            .padding(.bottom, 4)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    // 二次确认挂在 List 上：同一视图节点上叠两个 alert /
                    // confirmationDialog 只会有一个能弹出来，所以「删除确认」放 List、
                    // 「收藏到歌单」放外层 ZStack。
                    .alert("从歌单删除", isPresented: $showDeleteConfirm) {
                        Button("删除", role: .destructive) { deleteSelectedSongs() }
                        Button("取消", role: .cancel) {
                            if !multiSelectMode { selectedSongKeys.removeAll() }
                        }
                    } message: {
                        Text(cloudDeleteConfirmMessage)
                    }
                }
            }
            }
            .navigationTitle(playlist.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // 多选做成一步直达的独立按钮：埋在菜单里要点两下，用户根本不会去找。
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        BeansHaptics.tap()
                        multiSelectMode.toggle()
                        if !multiSelectMode { selectedSongKeys.removeAll() }
                    } label: {
                        Image(systemName: multiSelectMode ? "xmark.circle" : "checklist")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .accessibilityLabel(multiSelectToggleLabel)
                    .disabled(loading || errorMessage != nil)
                }
            }
            .confirmationDialog(
                "收藏 \(selectedSongKeys.count) 首歌曲到",
                isPresented: $showCollectDialog,
                titleVisibility: .visible
            ) {
                ForEach(collectableLocalPlaylists) { target in
                    Button("本机：\(target.name)") {
                        Task { await collectSelectedSongs(toLocal: target.id) }
                    }
                }
                ForEach(collectableCloudPlaylists) { target in
                    Button("云端：\(target.name)") {
                        Task { await collectSelectedSongs(toCloud: target.id) }
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("云端收藏只对网易云歌单有效，QQ / 酷狗的曲目写不回去。")
            }
        .task { await load() }
        .onChange(of: tracks) { _ in refreshDisplayedTracks() }
        .onChange(of: searchText) { _ in refreshDisplayedTracks() }
        .onChange(of: sortMode) { _ in refreshDisplayedTracks() }
    }

    /// 重算「搜索 + 排序」结果。只在输入源变化时调用一次，不在 body 里跑。
    ///
    /// 播放上下文的登记也放在这里 —— 原先它写在 `body` 的求值路径上，
    /// 等于每次页面重算都要把整张歌单往注册表里写一遍（数组是逐元素比较的，
    /// 几百首就是几百次 `Song` 比较），滑动时会持续触发。
    private func refreshDisplayedTracks() {
        var list = tracks
        let kw = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !kw.isEmpty {
            list = list.filter { song in
                song.name.lowercased().contains(kw)
                    || song.artists.lowercased().contains(kw)
                    || song.album.lowercased().contains(kw)
            }
        }
        switch sortMode {
        case .original: break
        case .name:
            list.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .artist:
            list.sort { $0.artists.localizedStandardCompare($1.artists) == .orderedAscending }
        case .duration:
            list.sort { $0.duration < $1.duration }
        }
        displayedTracks = list
        PlaybackContextRegistry.shared.register(list, key: playbackContextKey)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: isNativeClean ? 18 : 14) {
                CoverImage(url: playlist.coverURL, size: 96, cornerRadius: 18)
                VStack(alignment: .leading, spacing: 6) {
                    Text(playlist.name)
                        .font(BeansFont.appFont(18, .bold))
                        .foregroundStyle(Color.beansLabel)
                        .lineLimit(2)
                    if !playlist.creatorName.isEmpty {
                        Text(playlist.creatorName)
                            .font(BeansFont.appFont(12))
                            .foregroundStyle(Color.beansComment)
                    }
                    Text(beansSongCountText(tracks.count))
                        .font(BeansFont.appFont(12))
                        .foregroundStyle(Color.beansComment)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                GlassButton(title: playAllTitle, systemName: "play.fill", prominent: true) {
                    player.play(songs: displayedTracks, startAt: 0)
                }
                GlassButton(title: "随机播放", systemName: "shuffle") {
                    if !displayedTracks.isEmpty {
                        player.play(songs: displayedTracks, startAt: Int.random(in: 0..<displayedTracks.count))
                    }
                }
            }
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.beansComment)
                    TextField(beansLocalized("搜索歌单内歌曲", "Search songs in playlist"), text: $searchText)
                        .font(BeansFont.appFont(14))
                        .autocorrectionDisabled()
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.beansComment)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background { BeansSurface(shape: RoundedRectangle(cornerRadius: 14, style: .continuous)) }

                if !hideSortButton {
                    Menu {
                        Picker("排序", selection: $sortMode) {
                            ForEach(PlaylistSortMode.allCases) { mode in
                                Text(LocalizedStringKey(mode.rawValue)).tag(mode)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.beansAmber)
                            .frame(width: 38, height: 38)
                            .background { BeansSurface(shape: Circle()) }
                    }
                    .buttonStyle(GlassPressButtonStyle())
                }
            }
        }
        .padding(14)
        .background { BeansSurface(shape: RoundedRectangle(cornerRadius: 24, style: .continuous)) }
    }

    /// 「播放全部（N）」跟网易云一致，让用户不点进去也知道这个歌单有多少首。
    private var playAllTitle: String {
        "播放全部 (\(displayedTracks.count))"
    }

    // MARK: - 多选动作

    private func toggleSelection(_ song: Song) {
        BeansHaptics.select()
        if selectedSongKeys.contains(song.identityKey) {
            selectedSongKeys.remove(song.identityKey)
        } else {
            selectedSongKeys.insert(song.identityKey)
        }
    }

    /// 全选只作用于当前搜索出来的结果，免得把没搜到的歌一起选上。
    private func toggleSelectAll() {
        BeansHaptics.select()
        let keys = Set(displayedTracks.map(\.identityKey))
        guard !keys.isEmpty else { return }
        if keys.isSubset(of: selectedSongKeys) {
            selectedSongKeys.subtract(keys)
        } else {
            selectedSongKeys.formUnion(keys)
        }
    }

    private func selectedSongs() -> [Song] {
        guard !selectedSongKeys.isEmpty else { return [] }
        return tracks.filter { selectedSongKeys.contains($0.identityKey) }
    }

    private func playSelectedNext() {
        let picked = selectedSongs()
        guard !picked.isEmpty else { return }
        for song in picked { player.playNext(song) }
        BeansHaptics.success()
        ToastCenter.shared.show("已把 \(picked.count) 首歌曲排到下一首")
        selectedSongKeys.removeAll()
        multiSelectMode = false
    }

    @MainActor
    private func downloadSelectedSongs() {
        let picked = selectedSongs()
        guard !picked.isEmpty, !downloading else { return }
        downloading = true
        selectedSongKeys.removeAll()
        multiSelectMode = false
        ToastCenter.shared.show("开始下载 \(picked.count) 首歌曲")
        Task {
            var success = 0
            for song in picked {
                let result = await DownloadManager.shared.download(song: song, quality: ThirdPartyAudioQuality.current)
                if case .success = result { success += 1 }
            }
            downloading = false
            BeansHaptics.success()
            ToastCenter.shared.show("下载完成：\(success)/\(picked.count) 首", duration: 3)
        }
    }

    @MainActor
    private func collectSelectedSongs(toLocal id: UUID) async {
        let picked = selectedSongs()
        guard !picked.isEmpty else { return }
        let added = localLibrary.addSongs(picked, to: id)
        let name = localLibrary.playlists.first(where: { $0.id == id })?.name ?? "本机歌单"
        selectedSongKeys.removeAll()
        multiSelectMode = false
        BeansHaptics.success()
        ToastCenter.shared.show(added == picked.count
                                ? "已收藏 \(added) 首到「\(name)」"
                                : "已收藏 \(added) 首到「\(name)」（重复歌曲已跳过）")
    }

    @MainActor
    private func collectSelectedSongs(toCloud id: Int) async {
        let picked = selectedSongs()
        guard !picked.isEmpty else { return }
        let ids = picked.map(\.id)
        let result = await NetEaseAPI.shared.addToPlaylistDetailed(playlistID: id, songIDs: ids)
        selectedSongKeys.removeAll()
        multiSelectMode = false
        if result.ok {
            BeansHaptics.success()
            ToastCenter.shared.show("已收藏 \(ids.count) 首到云端歌单")
        } else {
            ToastCenter.shared.show("收藏失败：\(result.message ?? "未知错误")", duration: 3)
        }
    }

    /// 从云端歌单删除。网易云这个接口和加歌一样换过协议，见
    /// `NetEaseAPI.removeFromPlaylistDetailed` —— 失败时把服务端原话显示出来，
    /// 别一律写成"删除失败"，否则下次还是查不动。
    @MainActor
    private func deleteSelectedSongs() {
        guard canDeleteFromCloud, !deleting else {
            selectedSongKeys.removeAll()
            multiSelectMode = false
            return
        }
        let picked = selectedSongs()
        guard !picked.isEmpty else {
            selectedSongKeys.removeAll()
            multiSelectMode = false
            return
        }
        deleting = true
        let ids = picked.map(\.id)
        let keys = Set(picked.map(\.identityKey))
        Task {
            let result = await NetEaseAPI.shared.removeFromPlaylistDetailed(playlistID: playlist.id, songIDs: ids)
            deleting = false
            if result.ok {
                tracks.removeAll { keys.contains($0.identityKey) }
                selectedSongKeys.removeAll()
                multiSelectMode = false
                SyncedPlaylistCache.shared.saveSongs(tracks, playlist: playlist, accountID: cacheAccountID)
                BeansHaptics.success()
                ToastCenter.shared.show("已从歌单删除 \(ids.count) 首歌曲")
            } else {
                selectedSongKeys.removeAll()
                multiSelectMode = false
                ToastCenter.shared.show("删除失败：\(result.message ?? "未知错误")", duration: 3)
            }
        }
    }

    private func load(force: Bool = false) async {
        let cache = SyncedPlaylistCache.shared
        if let cached = cache.cachedSongs(playlist: playlist, accountID: cacheAccountID) {
            tracks = cached.songs
            loading = false
            if !force, cache.isFresh(cached) {
                return
            }
        } else {
            loading = true
        }
        errorMessage = nil
        BeansLogger.shared.log("歌单页面打开 source=\(playlist.source.rawValue) id=\(playlist.id) name=\(playlist.name) advertisedCount=\(playlist.trackCount)", level: .info)
        do {
            if playlist.source == .kugou {
                tracks = try await KugouMusicAPI.shared.playlistSongs(listID: playlist.id)
            } else if playlist.source == .qq {
                tracks = try await QQMusicAPI.shared.playlistSongs(listID: playlist.id)
                // 云端收藏接口临时被风控或返回空时，至少展示已同步到本机的 QQ 收藏，
                // 避免“我的喜欢”进入后变成空白页面。
                if tracks.isEmpty, playlist.id == QQMusicAPI.qqLikedPlaylistID {
                    tracks = favorites.qqFavoriteSongs
                    BeansLogger.shared.log("QQ 我的喜欢页面网络结果为空，使用本地收藏回退 count=\(tracks.count)", level: tracks.isEmpty ? .warn : .info)
                }
            } else {
                tracks = try await NetEaseAPI.shared.playlistTracks(id: playlist.id)
            }
            if !tracks.isEmpty {
                cache.saveSongs(tracks, playlist: playlist, accountID: cacheAccountID)
            }
            BeansLogger.shared.log("歌单页面加载完成 source=\(playlist.source.rawValue) id=\(playlist.id) name=\(playlist.name) count=\(tracks.count) error=无", level: tracks.isEmpty ? .warn : .info)
            loading = false
        } catch {
            if tracks.isEmpty {
                errorMessage = error.localizedDescription
            } else {
                BeansLogger.shared.log("歌单页面刷新失败，继续使用缓存 source=\(playlist.source.rawValue) id=\(playlist.id) error=\(error.localizedDescription)", level: .warn)
            }
            BeansLogger.shared.log("歌单页面加载失败 source=\(playlist.source.rawValue) id=\(playlist.id) name=\(playlist.name) error=\(error.localizedDescription)", level: .error)
            loading = false
        }
    }
}
