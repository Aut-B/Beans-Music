import SwiftUI

// MARK: - 插件音源搜索
//
// 选定一个已启用的 MusicFree 插件，直接用它自己的曲库搜索。
// 播放时把结果整体作为播放队列，播放地址由 PlayerManager 向插件换取。

struct MFPluginSearchView: View {
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var auth: AuthStore
    @ObservedObject private var manager = MFPluginManager.shared

    @State private var platform: String = ""
    @State private var keyword = ""
    @State private var items: [MFPluginMusicItem] = []
    @State private var page = 1
    @State private var isEnd = false
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var searchTask: Task<Void, Never>?

    /// 已启用插件，没有时回退到全部已安装插件，避免进来就是空白页。
    private var availablePlatforms: [String] {
        let enabled = manager.enabledPlatforms
        return enabled.isEmpty ? manager.plugins.map(\.platform) : enabled
    }

    private var songs: [Song] { items.map { Song(pluginItem: $0) } }

    /// 播放上下文令牌，见 `PlaybackContextRegistry`。
    private var pluginSongsContextKey: String {
        "plugin-search-\(platform)-\(songs.count)-\(songs.first?.identityKey ?? "-")-\(songs.last?.identityKey ?? "-")"
    }

    var body: some View {
        NavigationView {
            ScrollView {
                LazyVStack(spacing: 12) {
                    platformPicker
                    searchBar
                    content
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
            }
            .background(GlassBackdrop())
            .navigationTitle(beansLocalized("插件搜歌", "Plugin Search"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .navigationViewStyle(.stack)
        .onAppear {
            if platform.isEmpty { platform = availablePlatforms.first ?? "" }
        }
        .onDisappear { searchTask?.cancel() }
    }

    // MARK: - 音源选择

    private var platformPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            if availablePlatforms.isEmpty {
                Text(beansLocalized(
                    "还没有可用的插件音源。请先在上一页安装一个插件。",
                    "No plugin sources available yet. Install one on the previous screen."
                ))
                    .font(BeansFont.appFont(13))
                    .foregroundStyle(Color.beansComment)
            } else {
                Text(beansLocalized("音源", "Source"))
                    .font(BeansFont.appFont(13, .semibold))
                    .foregroundStyle(Color.beansLabel)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(availablePlatforms, id: \.self) { name in
                            Button {
                                BeansHaptics.tap()
                                platform = name
                                if !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    startSearch(reset: true)
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: iconName(for: name))
                                        .font(.system(size: 12))
                                    Text(name)
                                        .font(BeansFont.appFont(13, .semibold))
                                }
                                .foregroundStyle(platform == name ? Color.white : Color.beansLabel)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(
                                    Capsule().fill(platform == name ? Color.black : Color.beansComment.opacity(0.14))
                                )
                            }
                            .buttonStyle(GlassPressButtonStyle(scale: 0.95))
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
        }
        .padding(16)
        .background {
            BeansGlass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .beansCardShadow(radius: 8, y: 3)
    }

    // MARK: - 搜索栏

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14))
                .foregroundStyle(Color.beansComment)
            TextField(beansLocalized("搜歌名 / 歌手，或粘贴 BV 号", "Search title / artist, or paste a BV id"), text: $keyword)
                .font(BeansFont.appFont(14))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { startSearch(reset: true) }
            if isLoading {
                ProgressView()
            } else if !keyword.isEmpty {
                Button {
                    keyword = ""
                    items = []
                    errorText = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.beansComment)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background {
            BeansGlass(shape: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    // MARK: - 结果

    @ViewBuilder
    private var content: some View {
        if let errorText {
            card {
                Text(errorText)
                    .font(BeansFont.appFont(13))
                    .foregroundStyle(Color.red.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if songs.isEmpty {
            card {
                VStack(alignment: .leading, spacing: 6) {
                    Text(beansLocalized("输入关键词开始搜索", "Type a keyword to search"))
                        .font(BeansFont.appFont(14))
                        .foregroundStyle(Color.beansLabel)
                    Text(beansLocalized(
                        "插件音源走的是它自己的曲库。比如哔哩哔哩音源可以直接搜视频，也可以粘贴 BV 号精确播放。",
                        "Plugin sources use their own catalog. For example, the Bilibili source can search videos or resolve a BV id directly."
                    ))
                        .font(BeansFont.appFont(12))
                        .foregroundStyle(Color.beansComment)
                }
            }
        } else {
            card {
                VStack(spacing: 0) {
                    let ctxKey = pluginSongsContextKey
                    let _ = PlaybackContextRegistry.shared.register(songs, key: ctxKey)
                    ForEach(songs.indices, id: \.self) { index in
                        let song = songs[index]
                        SongCell(
                            song: song,
                            playbackContextKey: ctxKey,
                            playbackIndex: index
                        )
                        if index != songs.count - 1 {
                            Divider().overlay(Color.beansComment.opacity(0.15))
                        }
                    }
                }
            }

            if !isEnd {
                Button {
                    startSearch(reset: false)
                } label: {
                    HStack(spacing: 8) {
                        if isLoading { ProgressView().tint(Color.beansLabel) }
                        Text(beansLocalized("加载更多", "Load more"))
                    }
                    .font(BeansFont.appFont(13, .semibold))
                    .foregroundStyle(Color.beansLabel)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background {
                        BeansGlass(shape: Capsule())
                    }
                }
                .buttonStyle(GlassPressButtonStyle(scale: 0.97))
                .disabled(isLoading)
            }
        }
    }

    private func card<Content: View>(@ViewBuilder _ builder: () -> Content) -> some View {
        builder()
            .padding(16)
            .background {
                BeansGlass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            .beansCardShadow(radius: 8, y: 3)
    }

    private func iconName(for platform: String) -> String {
        let lower = platform.lowercased()
        if lower.contains("bili") || platform.contains("哔哩") { return "play.rectangle.fill" }
        if lower.contains("wy") || platform.contains("网易") { return "music.note" }
        if lower.contains("tx") || lower.contains("qq") { return "music.note.list" }
        return "puzzlepiece.extension.fill"
    }

    // MARK: - 搜索

    private func startSearch(reset: Bool) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !platform.isEmpty else { return }
        searchTask?.cancel()

        let targetPage = reset ? 1 : page + 1
        if reset {
            page = 1
            isEnd = false
        }
        isLoading = true
        errorText = nil

        searchTask = Task { @MainActor in
            do {
                // BV 号：优先走原生精确解析，避免把 BV 号当关键词搜出一堆无关视频
                if reset, let exact = await manager.resolveBilibiliBV(trimmed, platform: platform) {
                    items = [exact]
                    isEnd = true
                    page = 1
                    isLoading = false
                    return
                }
                let result = try await manager.search(platform: platform, query: trimmed, page: targetPage)
                guard !Task.isCancelled else { return }
                if reset {
                    items = result.items
                } else {
                    let existing = Set(items.map(\.id))
                    items.append(contentsOf: result.items.filter { !existing.contains($0.id) })
                    page = targetPage
                }
                isEnd = result.isEnd || result.items.isEmpty
                isLoading = false
            } catch {
                guard !Task.isCancelled else { return }
                isLoading = false
                errorText = beansLocalized(
                    "搜索失败：\(error.localizedDescription)",
                    "Search failed: \(error.localizedDescription)"
                )
            }
        }
    }
}
