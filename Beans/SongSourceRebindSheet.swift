import SwiftUI

/// 单曲换源面板。
///
/// 用途：本地歌单里某一首歌绑定的来源不好用（比如某个插件音源只给 320k、
/// 每次解析都很慢，或者干脆解析失败了），把它**换成另一个平台的同一条曲目**。
///
/// 做法是在网易云 / QQ / 酷狗 / 各个已装插件里按「歌名 + 歌手」并发搜一遍，
/// 按「歌手命中 → 时长接近」排序后列出来，用户挑一条替换即可。
/// 替换是**原地**的：歌单里这首歌的位置、顺序都不变，只把条目本身换掉。
///
/// 界面上刻意把歌手和时长一起显示出来 —— 同名不同版本（翻唱、Live、钢琴版）
/// 太多，只给歌名用户没法判断选哪个。
struct SongSourceRebindSheet: View {
    @ObservedObject private var library = LocalLibraryStore.shared
    @ObservedObject private var pluginManager = MFPluginManager.shared
    @ObservedObject private var preferred = PreferredSourceStore.shared
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.dismiss) private var dismiss

    let song: Song

    /// 一个可选的替代条目。
    struct RebindCandidate: Identifiable, Sendable {
        let song: Song
        /// 展示用的平台名（插件音源用插件自己声明的名字）。
        let platformLabel: String
        /// 歌手命中 + 时长接近，可以放心直接换。
        let isConfident: Bool
        var id: String { song.identityKey }
    }

    @State private var candidates: [RebindCandidate] = []
    @State private var searching = false
    @State private var searchedOnce = false
    @State private var errorText: String?

    var body: some View {
        let _ = theme.accent
        BeansNavigationStack {
            List {
                currentSection
                resultSection
                if let errorText {
                    Section {
                        Text(errorText)
                            .font(BeansFont.appFont(12))
                            .foregroundStyle(.red)
                    }
                }
                explainSection
            }
            .navigationTitle("更换音源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await runSearch() }
                    } label: {
                        if searching {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("重新匹配")
                        }
                    }
                    .disabled(searching)
                }
            }
        }
        .modifier(BeansSheetModifier(detents: [.medium, .large], dragIndicator: true))
        .task {
            guard !searchedOnce else { return }
            await runSearch()
        }
    }

    // MARK: - 当前

    @ViewBuilder
    private var currentSection: some View {
        Section {
            HStack(spacing: 12) {
                CoverImage(url: song.coverURL, size: 44, cornerRadius: 10)
                VStack(alignment: .leading, spacing: 3) {
                    Text(song.name)
                        .font(BeansFont.appFont(15, .medium))
                        .foregroundStyle(Color.beansLabel)
                        .lineLimit(1)
                    Text(song.artists.isEmpty ? song.album : song.artists)
                        .font(BeansFont.appFont(12))
                        .foregroundStyle(Color.beansComment)
                        .lineLimit(1)
                }
                Spacer()
                platformChip(currentPlatformLabel, tint: Color.beansComment)
            }
            let count = library.playlistCount(containing: song)
            Text(libraryCountText)
                .font(BeansFont.appFont(11))
                .foregroundStyle(count > 0 ? Color.beansSage : Color.beansComment)
        } header: {
            Text("当前来源")
        }
    }

    /// 抽成显式 `String` 属性：三元式里放两个字符串字面量会让
    /// `Text(LocalizedStringKey)` 与 `Text(StringProtocol)` 两个重载撞在一起，编译期报歧义。
    private var libraryCountText: String {
        let count = library.playlistCount(containing: song)
        return count > 0
            ? "这首歌在 \(count) 个本地歌单里"
            : "这首歌不在任何本地歌单里"
    }

    private var currentPlatformLabel: String {
        if song.source == .plugin, let platform = song.pluginPlatform, !platform.isEmpty {
            return platform
        }
        return song.source.sourceDisplayName
    }

    // MARK: - 匹配结果

    @ViewBuilder
    private var resultSection: some View {
        Section {
            if searching {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("正在各平台匹配同名曲目…")
                        .font(BeansFont.appFont(13))
                        .foregroundStyle(Color.beansComment)
                }
            } else if candidates.isEmpty {
                EmptyStateView(icon: "arrow.triangle.2.circlepath", text: "没有匹配到其他来源")
                Text("搜到的都是同一个来源，或者各平台都没有这条曲目。可以点右上角「重新匹配」再试一次。")
                    .font(BeansFont.appFont(11))
                    .foregroundStyle(Color.beansComment)
            } else {
                ForEach(candidates) { candidate in
                    Button {
                        apply(candidate)
                    } label: {
                        candidateRow(candidate)
                    }
                }
            }
        } header: {
            Text("可换成")
        } footer: {
            Text("共匹配到 \(candidates.count) 条。带对勾的是「歌手 + 时长」都对得上的，优先选这些；其余是同名但版本可能不同的条目。")
                .font(BeansFont.appFont(11))
        }
    }

    private func candidateRow(_ candidate: RebindCandidate) -> some View {
        HStack(spacing: 12) {
            CoverImage(url: candidate.song.coverURL, size: 42, cornerRadius: 10)
            VStack(alignment: .leading, spacing: 3) {
                Text(candidate.song.name)
                    .font(BeansFont.appFont(14))
                    .foregroundStyle(Color.beansLabel)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    platformChip(candidate.platformLabel, tint: Color.beansSage)
                    Text(candidate.song.artists.isEmpty ? candidate.song.album : candidate.song.artists)
                        .font(BeansFont.appFont(11))
                        .foregroundStyle(Color.beansComment)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 3) {
                Text(candidate.song.formattedDuration)
                    .font(BeansFont.appFont(11, .regular, .monospaced))
                    .foregroundStyle(Color.beansComment)
                if candidate.isConfident {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.beansAmber)
                }
            }
        }
    }

    private func platformChip(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(BeansFont.appFont(10, .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.14)))
            .lineLimit(1)
    }

    // MARK: - 说明

    @ViewBuilder
    private var explainSection: some View {
        Section {
            Text(explanationText)
                .font(BeansFont.appFont(11))
                .foregroundStyle(Color.beansComment)
        } header: {
            Text("关于换源")
        }
    }

    private var explanationText: String {
        var lines = [
            "换源只改本地歌单里的这一条，位置和顺序都不变，改动会随歌单一起同步到 WebDAV。",
            "播放队列和播放历史里的这首歌不受影响。",
        ]
        if preferred.enabled, preferred.preferForNetease {
            lines.append("换成网易云来源后，播放时会优先用 pyncmd 取高音质直链，通常比插件音源的 320k 更好、也更快。")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 应用

    private func apply(_ candidate: RebindCandidate) {
        BeansHaptics.tap()
        let changed = library.rebindSong(oldIdentity: song.identityKey, to: candidate.song)
        guard changed > 0 else {
            ToastCenter.shared.show("这首歌不在任何本地歌单里，没有可替换的条目", duration: 3)
            return
        }
        BeansHaptics.success()
        ToastCenter.shared.show("已在 \(changed) 个本地歌单里换成「\(candidate.platformLabel)」")
        dismiss()
    }

    // MARK: - 搜索

    @MainActor
    private func runSearch() async {
        searchedOnce = true
        searching = true
        errorText = nil
        let keyword = [song.name, song.artists]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: " ")
        guard !keyword.isEmpty else {
            errorText = "这首歌没有可用的歌名，无法匹配"
            searching = false
            return
        }

        let platforms = pluginManager.enabledPlatforms
        let origin = song
        var found: [RebindCandidate] = []
        await withTaskGroup(of: [RebindCandidate].self) { group in
            group.addTask { await Self.searchNetease(keyword: keyword, origin: origin) }
            group.addTask { await Self.searchQQ(keyword: keyword, origin: origin) }
            group.addTask { await Self.searchKugou(keyword: keyword, origin: origin) }
            for platform in platforms {
                group.addTask { await Self.searchPlugin(platform: platform, keyword: keyword, origin: origin) }
            }
            for await batch in group {
                found.append(contentsOf: batch)
            }
        }

        // 去重：同来源同 id 只留一条（不同歌单/分页可能重复给同一条）。
        var seen = Set<String>()
        let unique = found.filter { seen.insert($0.song.identityKey).inserted }
        // 排除它自己：同一来源同一 id 换过去等于没换。
        let filtered = unique.filter { $0.song.identityKey != song.identityKey }

        // 排序：对得上的排前面，其次按时长差从小到大。
        let target = song.duration
        candidates = filtered.sorted { lhs, rhs in
            if lhs.isConfident != rhs.isConfident { return lhs.isConfident }
            let l = lhs.song.duration > 0 ? abs(lhs.song.duration - target) : .greatestFiniteMagnitude
            let r = rhs.song.duration > 0 ? abs(rhs.song.duration - target) : .greatestFiniteMagnitude
            if l != r { return l < r }
            return lhs.song.name.count < rhs.song.name.count
        }
        searching = false
    }

    // MARK: - 各平台搜索
    //
    // 这几个函数刻意写成 nonisolated static：它们跑在 `withTaskGroup` 的子任务里，
    // 不该被主线程隔离带上（也不该捕获 self）。

    nonisolated private static func searchNetease(keyword: String, origin: Song) async -> [RebindCandidate] {
        guard let results = try? await NetEaseAPI.shared.search(keyword: keyword, limit: 12) else { return [] }
        return results.map { make($0, label: SongSource.netease.sourceDisplayName, origin: origin) }
    }

    nonisolated private static func searchQQ(keyword: String, origin: Song) async -> [RebindCandidate] {
        guard let results = try? await QQMusicAPI.shared.searchSongs(keyword: keyword, limit: 12) else { return [] }
        return results.map { make($0, label: SongSource.qq.sourceDisplayName, origin: origin) }
    }

    nonisolated private static func searchKugou(keyword: String, origin: Song) async -> [RebindCandidate] {
        guard let results = try? await KugouMusicAPI.shared.searchSongs(keyword: keyword, limit: 12) else { return [] }
        return results.map { make($0, label: SongSource.kugou.sourceDisplayName, origin: origin) }
    }

    nonisolated private static func searchPlugin(platform: String, keyword: String, origin: Song) async -> [RebindCandidate] {
        guard let result = try? await MFPluginManager.shared.search(platform: platform, query: keyword, page: 1) else {
            return []
        }
        return result.items
            .prefix(12)
            .map { make(Song(pluginItem: $0), label: platform, origin: origin) }
    }

    nonisolated private static func make(_ song: Song, label: String, origin: Song) -> RebindCandidate {
        RebindCandidate(song: song, platformLabel: label, isConfident: isSameTrack(song, origin))
    }

    /// 歌手命中 + 时长差 6 秒以内，视为同一首曲目。
    nonisolated private static func isSameTrack(_ candidate: Song, _ origin: Song) -> Bool {
        let durationOK: Bool
        if candidate.duration > 0, origin.duration > 0 {
            durationOK = abs(candidate.duration - origin.duration) <= 6
        } else {
            durationOK = false
        }
        return durationOK && artistMatches(candidate.artists, origin.artists)
    }

    /// 歌手名做分词后双向包含判断，兼容「周杰伦」对「周杰伦 / 方文山」、
    /// 以及英文别名这类写法差异。
    nonisolated private static func artistMatches(_ lhs: String, _ rhs: String) -> Bool {
        let left = tokens(lhs)
        let right = tokens(rhs)
        guard !left.isEmpty, !right.isEmpty else { return false }
        return left.contains { token in
            guard token.count >= 2 else { return false }
            return right.contains { other in other.contains(token) || token.contains(other) }
        }
    }

    nonisolated private static func tokens(_ raw: String) -> [String] {
        let separators = CharacterSet(charactersIn: "/&,，、 ")
            .union(.whitespacesAndNewlines)
        return raw
            .lowercased()
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
