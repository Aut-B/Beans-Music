import SwiftUI

// MARK: - 音乐库「插件音源」板块
//
// 把 MusicFree 插件音源直接搬进音乐库：左上角切到「插件音源」后，
// 顶部一行就是已安装的插件平台（哔哩哔哩 / 网易云 / QQ / 酷狗 …），
// 下面分「搜索」与「榜单歌单」两个页签。
//
// 榜单/歌单可以整体导入本机歌单，导入后的歌曲与网易云、QQ、酷狗的歌曲
// 混在同一个本机歌单里，并可通过 WebDAV 同步到自己的网盘。

struct PluginLibrarySection: View {
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var auth: AuthStore
    @ObservedObject private var manager = MFPluginManager.shared
    @ObservedObject private var library = LocalLibraryStore.shared

    private enum Pane: String, CaseIterable, Identifiable {
        case search = "搜索"
        case charts = "榜单歌单"

        var id: String { rawValue }

        var localizedName: String {
            switch self {
            case .search: return beansLocalized("搜索", "Search")
            case .charts: return beansLocalized("榜单歌单", "Charts")
            }
        }
    }

    private struct SheetRoute: Identifiable {
        let id: String
        let sheet: MFPluginSheetItem
    }

    @State private var platform = ""
    @State private var pane: Pane = .search

    @State private var keyword = ""
    @State private var items: [MFPluginMusicItem] = []
    @State private var page = 1
    @State private var isEnd = false
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var searchTask: Task<Void, Never>?

    @State private var groups: [MFPluginTopGroup] = []
    @State private var chartsLoading = false
    @State private var chartsError: String?
    @State private var openedSheet: SheetRoute?
    @State private var showPluginManager = false

    /// 已启用的插件；一个都没启用时回退到全部已安装插件，避免进来就是空白页。
    private var platforms: [String] {
        let enabled = manager.enabledPlatforms
        return enabled.isEmpty ? manager.plugins.map(\.platform) : enabled
    }

    private var songs: [Song] { items.map { Song(pluginItem: $0) } }

    var body: some View {
        let _ = theme.accent
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "插件音源", trailing: "管理") {
                BeansHaptics.tap()
                showPluginManager = true
            }

            if platforms.isEmpty {
                emptyHintCard
            } else {
                platformChips
                panePicker
                switch pane {
                case .search:
                    searchBar
                    searchContent
                case .charts:
                    chartsContent
                }
            }
        }
        .onAppear {
            if platform.isEmpty || !platforms.contains(platform) {
                platform = platforms.first ?? ""
            }
        }
        .onChange(of: platforms) { _ in
            if platform.isEmpty || !platforms.contains(platform) {
                platform = platforms.first ?? ""
            }
        }
        .task(id: platform) {
            items = []
            errorText = nil
            groups = []
            chartsError = nil
            guard !platform.isEmpty else { return }
            await loadCharts()
        }
        .onDisappear { searchTask?.cancel() }
        .sheet(item: $openedSheet) { route in
            PluginSheetDetailView(platform: platform, sheet: route.sheet)
                .environmentObject(theme)
                .environmentObject(player)
                .environmentObject(auth)
        }
        .sheet(isPresented: $showPluginManager) {
            MFPluginManagerSheet()
                .environmentObject(theme)
                .environmentObject(player)
                .environmentObject(auth)
        }
    }

    // MARK: - 空态

    private var emptyHintCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(beansLocalized("还没有可用的插件音源", "No plugin source available"))
                .font(BeansFont.appFont(14, .semibold))
                .foregroundStyle(Color.beansLabel)
            Text(beansLocalized(
                "装一个 MusicFree 插件（比如哔哩哔哩），回到这里就能直接搜歌、看榜单，并把歌单存到本机。",
                "Install a MusicFree plugin (e.g. Bilibili) and you can search, browse charts and save sheets locally."
            ))
                .font(BeansFont.appFont(12))
                .foregroundStyle(Color.beansComment)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                BeansHaptics.tap()
                showPluginManager = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "puzzlepiece.extension.fill")
                    Text(beansLocalized("去安装插件", "Install a plugin"))
                }
                .font(BeansFont.appFont(13, .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Capsule().fill(pluginTint))
            }
            .buttonStyle(GlassPressButtonStyle(scale: 0.96))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            BeansGlass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .beansCardShadow(radius: 8, y: 3)
    }

    // MARK: - 插件平台

    private var platformChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(platforms, id: \.self) { name in
                    Button {
                        BeansHaptics.tap()
                        platform = name
                        if !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            startSearch(reset: true)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: Self.iconName(for: name))
                                .font(.system(size: 12))
                            Text(name)
                                .font(BeansFont.appFont(13, .semibold))
                        }
                        .foregroundStyle(platform == name ? Color.white : Color.beansLabel)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            Capsule().fill(platform == name
                                           ? AnyShapeStyle(pluginTint)
                                           : AnyShapeStyle(Color.beansComment.opacity(0.14)))
                        )
                    }
                    .buttonStyle(GlassPressButtonStyle(scale: 0.95))
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private var panePicker: some View {
        HStack(spacing: 4) {
            ForEach(Pane.allCases) { candidate in
                Button {
                    BeansHaptics.tap()
                    pane = candidate
                } label: {
                    Text(candidate.localizedName)
                        .font(BeansFont.appFont(13, .semibold))
                        .foregroundStyle(pane == candidate ? Color.white : Color.beansComment)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background {
                            if pane == candidate {
                                Capsule().fill(pluginTint)
                            } else {
                                Capsule().fill(.clear)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background { BeansSurface(shape: Capsule()) }
        .clipShape(Capsule())
        .beansCardShadow(radius: 6, y: 2)
    }

    private var pluginTint: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.99, green: 0.42, blue: 0.62), Color(red: 0.89, green: 0.23, blue: 0.51)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    // MARK: - 搜索

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

    @ViewBuilder
    private var searchContent: some View {
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
                        "插件音源走的是它自己的曲库：哔哩哔哩可以直接搜视频，也可以粘贴 BV 号精确播放。",
                        "Plugin sources use their own catalog: Bilibili can search videos, or resolve a BV id directly."
                    ))
                        .font(BeansFont.appFont(12))
                        .foregroundStyle(Color.beansComment)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            card {
                VStack(spacing: 0) {
                    ForEach(songs.indices, id: \.self) { index in
                        let song = songs[index]
                        SongCell(
                            song: song,
                            playbackContext: songs,
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
                    .background { BeansGlass(shape: Capsule()) }
                }
                .buttonStyle(GlassPressButtonStyle(scale: 0.97))
                .disabled(isLoading)
            }
        }
    }

    // MARK: - 榜单 / 歌单

    @ViewBuilder
    private var chartsContent: some View {
        if chartsLoading && groups.isEmpty {
            card {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(beansLocalized("正在读取榜单…", "Loading charts…"))
                        .font(BeansFont.appFont(13))
                        .foregroundStyle(Color.beansComment)
                }
            }
        } else if let chartsError {
            card {
                VStack(alignment: .leading, spacing: 8) {
                    Text(chartsError)
                        .font(BeansFont.appFont(13))
                        .foregroundStyle(Color.beansComment)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        Task { await loadCharts() }
                    } label: {
                        Text(beansLocalized("重新加载", "Reload"))
                            .font(BeansFont.appFont(13, .semibold))
                            .foregroundStyle(Color.beansAmber)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if groups.isEmpty {
            card {
                Text(beansLocalized("这个音源没有提供榜单，用上面的搜索试试。", "This source provides no charts. Try searching above."))
                    .font(BeansFont.appFont(13))
                    .foregroundStyle(Color.beansComment)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(group.title)
                        .font(BeansFont.appFont(15, .semibold))
                        .foregroundStyle(Color.beansLabel)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(group.items) { sheet in
                                Button {
                                    BeansHaptics.tap()
                                    openedSheet = SheetRoute(id: sheet.id, sheet: sheet)
                                } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        CoverImage(url: sheet.cover, size: 124, cornerRadius: 14)
                                        Text(sheet.title)
                                            .font(BeansFont.appFont(12, .medium))
                                            .foregroundStyle(Color.beansLabel)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.leading)
                                            .frame(width: 124, alignment: .leading)
                                    }
                                }
                                .buttonStyle(GlassPressButtonStyle(scale: 0.96))
                            }
                        }
                        .padding(.horizontal, 2)
                        .padding(.bottom, 2)
                    }
                }
            }
        }
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

    private static func iconName(for platform: String) -> String {
        let lower = platform.lowercased()
        if lower.contains("bili") || platform.contains("哔哩") { return "play.rectangle.fill" }
        if lower.contains("wy") || platform.contains("网易") { return "cloud.fill" }
        if lower.contains("tx") || lower.contains("qq") { return "play.square.stack.fill" }
        if lower.contains("kg") || platform.contains("酷狗") { return "music.note" }
        if lower.contains("kw") || platform.contains("酷我") { return "music.quarternote.3" }
        return "puzzlepiece.extension.fill"
    }

    // MARK: - 数据

    @MainActor
    private func loadCharts() async {
        guard !platform.isEmpty, !chartsLoading else { return }
        chartsLoading = true
        chartsError = nil
        do {
            let result = try await manager.topLists(platform: platform)
            guard !Task.isCancelled else { return }
            groups = result
            if result.isEmpty {
                chartsError = beansLocalized("这个音源没有提供榜单。", "This source provides no charts.")
            }
        } catch {
            guard !Task.isCancelled else { return }
            chartsError = beansLocalized(
                "读取榜单失败：\(error.localizedDescription)",
                "Failed to load charts: \(error.localizedDescription)"
            )
        }
        chartsLoading = false
    }

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

// MARK: - 歌单 / 榜单详情

struct PluginSheetDetailView: View {
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var auth: AuthStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var manager = MFPluginManager.shared
    @ObservedObject private var library = LocalLibraryStore.shared

    let platform: String
    let sheet: MFPluginSheetItem

    @State private var items: [MFPluginMusicItem] = []
    @State private var page = 1
    @State private var isEnd = false
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var importing = false
    @State private var loadedOnce = false

    private var songs: [Song] { items.map { Song(pluginItem: $0) } }

    var body: some View {
        NavigationView {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    header
                    content
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
            }
            .background(GlassBackdrop())
            .navigationTitle(sheet.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(beansLocalized("完成", "Done")) { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .task {
            guard !loadedOnce else { return }
            loadedOnce = true
            await load(reset: true)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            CoverImage(url: sheet.cover, size: 92, cornerRadius: 16)
            VStack(alignment: .leading, spacing: 6) {
                Text(sheet.title)
                    .font(BeansFont.appFont(16, .semibold))
                    .foregroundStyle(Color.beansLabel)
                    .lineLimit(2)
                if !sheet.detail.isEmpty {
                    Text(sheet.detail)
                        .font(BeansFont.appFont(12))
                        .foregroundStyle(Color.beansComment)
                        .lineLimit(3)
                }
                HStack(spacing: 10) {
                    Button {
                        playAll()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "play.fill")
                            Text(beansLocalized("播放全部", "Play all"))
                        }
                        .font(BeansFont.appFont(13, .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Color.beansAmber))
                    }
                    .buttonStyle(GlassPressButtonStyle(scale: 0.96))
                    .disabled(songs.isEmpty)

                    Button {
                        importToLocalLibrary()
                    } label: {
                        HStack(spacing: 5) {
                            if importing { ProgressView().tint(Color.beansLabel) }
                            Image(systemName: "square.and.arrow.down")
                            Text(beansLocalized("存到本机歌单", "Save locally"))
                        }
                        .font(BeansFont.appFont(13, .semibold))
                        .foregroundStyle(Color.beansLabel)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Color.beansComment.opacity(0.14)))
                    }
                    .buttonStyle(GlassPressButtonStyle(scale: 0.96))
                    .disabled(items.isEmpty || importing)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background {
            BeansGlass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .beansCardShadow(radius: 8, y: 3)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && songs.isEmpty {
            HStack(spacing: 10) {
                ProgressView()
                Text(beansLocalized("正在读取歌单…", "Loading sheet…"))
                    .font(BeansFont.appFont(13))
                    .foregroundStyle(Color.beansComment)
            }
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        } else if let errorText {
            Text(errorText)
                .font(BeansFont.appFont(13))
                .foregroundStyle(Color.red.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if songs.isEmpty {
            EmptyStateView(icon: "music.note.list", text: "这个歌单里没有歌曲")
        } else {
            VStack(spacing: 0) {
                ForEach(songs.indices, id: \.self) { index in
                    SongCell(
                        song: songs[index],
                        playbackContext: songs,
                        playbackIndex: index
                    )
                    if index != songs.count - 1 {
                        Divider().overlay(Color.beansComment.opacity(0.15))
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background {
                BeansGlass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            .beansCardShadow(radius: 8, y: 3)

            if !isEnd {
                Button {
                    Task { await load(reset: false) }
                } label: {
                    HStack(spacing: 8) {
                        if isLoading { ProgressView().tint(Color.beansLabel) }
                        Text(beansLocalized("加载更多", "Load more"))
                    }
                    .font(BeansFont.appFont(13, .semibold))
                    .foregroundStyle(Color.beansLabel)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background { BeansGlass(shape: Capsule()) }
                }
                .buttonStyle(GlassPressButtonStyle(scale: 0.97))
                .disabled(isLoading)
            }
        }
    }

    private func playAll() {
        guard !songs.isEmpty else { return }
        BeansHaptics.tap()
        player.play(songs: songs, startAt: 0)
    }

    private func importToLocalLibrary() {
        guard !songs.isEmpty, !importing else { return }
        BeansHaptics.tap()
        importing = true
        let name = sheet.title
        let target = library.playlists.first { $0.name == name } ?? library.createPlaylist(name: name)
        let added = library.addSongs(songs, to: target.id)
        importing = false
        BeansHaptics.success()
        if added > 0 {
            ToastCenter.shared.show(beansLocalized(
                "已导入 \(added) 首到「\(name)」", "Imported \(added) songs into “\(name)”"
            ), duration: 3)
        } else {
            ToastCenter.shared.show(beansLocalized(
                "「\(name)」里已经有这些歌了", "These songs are already in “\(name)”"
            ), duration: 3)
        }
    }

    @MainActor
    private func load(reset: Bool) async {
        guard !isLoading else { return }
        isLoading = true
        errorText = nil
        let targetPage = reset ? 1 : page + 1
        do {
            let result = try await manager.sheetDetail(platform: platform, sheet: sheet, page: targetPage)
            if reset {
                items = result.items
                page = 1
            } else {
                let existing = Set(items.map(\.id))
                items.append(contentsOf: result.items.filter { !existing.contains($0.id) })
                page = targetPage
            }
            isEnd = result.isEnd || result.items.isEmpty
        } catch {
            errorText = beansLocalized(
                "读取歌单失败：\(error.localizedDescription)",
                "Failed to load sheet: \(error.localizedDescription)"
            )
        }
        isLoading = false
    }
}
