import SwiftUI

// MARK: - 相对时间

func beansRelativeTime(_ date: Date) -> String {
    let interval = Date().timeIntervalSince(date)
    if interval < 60 { return NSLocalizedString("刚刚", comment: "") }
    if interval < 3600 { return String(format: NSLocalizedString("%d 分钟前", comment: ""), Int(interval / 60)) }
    if interval < 86400 { return String(format: NSLocalizedString("%d 小时前", comment: ""), Int(interval / 3600)) }
    if interval < 86400 * 30 { return String(format: NSLocalizedString("%d 天前", comment: ""), Int(interval / 86400)) }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
}

private func beansCommentCountText(songName: String, platform: String? = nil, count: Int) -> String {
    if let platform {
        return String(format: NSLocalizedString("《%@》 · %@ %d 条评论", comment: ""), songName, NSLocalizedString(platform, comment: ""), count)
    }
    return String(format: NSLocalizedString("《%@》 · 共 %d 条评论", comment: ""), songName, count)
}

// MARK: - 评论区

struct CommentsSheet: View {
    @EnvironmentObject private var theme: ThemeStore
    let song: Song

    @State private var page: NetEaseAPI.SongCommentPage?
    @State private var qqComments: [SongComment] = []
    @State private var qqTotal = 0
    @State private var qqPageNum = 0
    @State private var kugouComments: [SongComment] = []
    @State private var kugouTotal = 0
    @State private var kugouPageNum = 1
    @State private var pluginComments: [SongComment] = []
    @State private var pluginCommentsTotal = 0
    @State private var pluginCommentsEnd = true
    @State private var pluginPageNum = 1
    /// 该音源没有可查的评论区（插件未实现 getMusicComments、条目也不是 B 站）时置位，
    /// 显示一句提示而不是空白页。
    @State private var pluginCommentsUnsupported = false
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var offset = 0

    private let limit = 30
    /// QQ 音乐每页条数（接口单页上限 25）
    private let qqPageSize = 25

    var body: some View {
        let _ = theme.accent
        ZStack {
            GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
            BeansNavigationStack {
                Group {
                    if loading {
                        LoadingStateView()
                    } else if let errorMessage {
                        ErrorStateView(message: errorMessage) {
                            Task { await load(reset: true) }
                        }
                    } else if song.source == .kugou {
                        kugouCommentList
                    } else if song.source == .qq {
                        qqCommentList
                    } else if song.source == .plugin {
                        // 插件音源的评论由插件自己的 getMusicComments 提供；
                        // 插件没实现时，B 站条目回退到 App 内置的原生评论解析。
                        if pluginCommentsUnsupported {
                            EmptyStateView(icon: "bubble.left", text: "该音源暂不支持查看评论")
                        } else if pluginComments.isEmpty {
                            EmptyStateView(icon: "bubble.left", text: "暂无评论")
                        } else {
                            pluginCommentList
                        }
                    } else if let page {
                        if page.hot.isEmpty && page.comments.isEmpty {
                            EmptyStateView(icon: "bubble.left", text: "暂无评论")
                        } else {
                            neteaseCommentList(page)
                        }
                    }
                }
                .navigationTitle("评论")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .task { await load(reset: true) }
    }

    private func neteaseCommentList(_ page: NetEaseAPI.SongCommentPage) -> some View {
        List {
            Section {
                Text(beansCommentCountText(songName: song.name, count: page.total))
                    .font(BeansFont.appFont(12))
                    .foregroundStyle(Color.beansComment)
            }
            .listRowBackground(Color.clear)
            if !page.hot.isEmpty {
                Section("精彩评论") {
                    ForEach(page.hot) { comment in
                        CommentRow(comment: comment)
                            .listRowBackground(Color.clear)
                    }
                }
            }
            if !page.comments.isEmpty {
                Section("最新评论") {
                    ForEach(page.comments) { comment in
                        CommentRow(comment: comment)
                            .listRowBackground(Color.clear)
                    }
                }
            }
            if page.comments.count >= limit {
                Section {
                    Button {
                        Task { await loadMore() }
                    } label: {
                        Text("加载更多")
                            .font(BeansFont.appFont(14, .semibold))
                            .foregroundStyle(Color.beansAmber)
                            .frame(maxWidth: .infinity)
                    }
                }
                .listRowBackground(Color.clear)
            }
        }
        .beansScrollContentBackgroundHidden()
    }

    // MARK: - B 站条目识别（原生回退路径用）

    /// 从插件条目里取出 BV 号。
    ///
    /// 先看原始条目 JSON 里的 `bvid`——那是插件搜索结果的规范字段，有它就一定是 B 站条目；
    /// 读不到再按平台名判断，并在条目 id / 原始 JSON 文本里用正则捞 BV 号，
    /// 因为旧歌单存的条目可能只有 id 字段，而 B 站条目的 id 本身就是 BV 号。
    private var bilibiliBVID: String? {
        guard song.source == .plugin else { return nil }
        if let raw = song.pluginRawJSON,
           let data = raw.data(using: .utf8),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let bvid = object["bvid"] as? String,
           !bvid.isEmpty {
            return bvid
        }
        guard Self.isBilibiliPlatform(song.pluginPlatform) else { return nil }
        for text in [song.pluginItemID ?? "", song.pluginRawJSON ?? ""] {
            if let range = text.range(of: "BV[0-9A-Za-z]{10}", options: .regularExpression) {
                return String(text[range])
            }
        }
        return nil
    }

    private static func isBilibiliPlatform(_ platform: String?) -> Bool {
        let name = (platform ?? "").lowercased()
        return name.contains("bili") || name.contains("哔哩") || name.contains("b站")
    }

    /// 钉在主线程：这个方法从头到尾都在写 `@State`，而它是个 async 函数，
    /// 不加 `@MainActor` 会被调度到后台线程执行，UI 拿不到更新——
    /// 表现出来就是「打开评论一直转圈」。网络请求本身会 await 让出，不会卡界面。
    @MainActor
    private func load(reset: Bool) async {
        if reset {
            offset = 0
            page = nil
            qqComments = []
            qqTotal = 0
            qqPageNum = 0
            kugouComments = []
            kugouTotal = 0
            kugouPageNum = 1
            pluginComments = []
            pluginCommentsTotal = 0
            pluginCommentsEnd = true
            pluginPageNum = 1
            pluginCommentsUnsupported = false
            loading = true
        }
        errorMessage = nil
        do {
            if song.source == .plugin {
                let supported = try await loadPluginComments(page: pluginPageNum)
                guard supported else {
                    pluginCommentsUnsupported = true
                    loading = false
                    return
                }
                loading = false
                return
            } else if song.source == .kugou {
                let mixSongID = song.kugouAlbumAudioId ?? ""
                let result = try await KugouMusicAPI.shared.comments(
                    mixSongID: mixSongID,
                    hash: song.kugouHash,
                    page: kugouPageNum,
                    limit: limit
                )
                if reset {
                    kugouComments = result.comments
                } else {
                    kugouComments.append(contentsOf: result.comments)
                }
                kugouTotal = result.total
                loading = false
                return
            } else if song.source == .qq {
                let result = try await QQMusicAPI.shared.comments(songID: song.id, limit: qqPageSize, pagenum: qqPageNum)
                if reset {
                    qqComments = result.comments
                } else {
                    qqComments.append(contentsOf: result.comments)
                }
                qqTotal = result.total
            } else {
                let result = try await NetEaseAPI.shared.songComments(id: song.id, limit: limit, offset: offset)
                if reset {
                    page = result
                } else if var current = page {
                    current.comments.append(contentsOf: result.comments)
                    page = current
                }
            }
            loading = false
        } catch {
            errorMessage = error.localizedDescription
            loading = false
        }
    }

    /// QQ 音乐评论列表（分页加载更多）
    private var qqCommentList: some View {
        Group {
            if qqComments.isEmpty {
                EmptyStateView(icon: "bubble.left", text: "暂无评论")
            } else {
                List {
                    Section {
                        Text(beansCommentCountText(songName: song.name, platform: "QQ 音乐", count: qqTotal > 0 ? qqTotal : qqComments.count))
                            .font(BeansFont.appFont(12))
                            .foregroundStyle(Color.beansComment)
                    }
                    .listRowBackground(Color.clear)
                    Section("评论") {
                        ForEach(qqComments) { comment in
                            CommentRow(comment: comment)
                                .listRowBackground(Color.clear)
                        }
                    }
                    if qqTotal <= 0 || qqComments.count < qqTotal {
                        Section {
                            Button {
                                Task { await loadQQMore() }
                            } label: {
                                Text("加载更多")
                                    .font(BeansFont.appFont(14, .semibold))
                                    .foregroundStyle(Color.beansAmber)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .listRowBackground(Color.clear)
                    }
                }
                .beansScrollContentBackgroundHidden()
            }
        }
    }

    /// QQ 评论翻页
    @MainActor
    private func loadQQMore() async {
        qqPageNum += 1
        await load(reset: false)
    }

    private var kugouCommentList: some View {
        Group {
            if kugouComments.isEmpty {
                EmptyStateView(icon: "bubble.left", text: "暂无评论")
            } else {
                List {
                    Section {
                        Text(beansCommentCountText(songName: song.name, platform: "酷狗音乐", count: kugouTotal > 0 ? kugouTotal : kugouComments.count))
                            .font(BeansFont.appFont(12))
                            .foregroundStyle(Color.beansComment)
                    }
                    .listRowBackground(Color.clear)
                    Section("评论") {
                        ForEach(kugouComments) { comment in
                            CommentRow(comment: comment)
                                .listRowBackground(Color.clear)
                        }
                    }
                    if kugouTotal <= 0 || kugouComments.count < kugouTotal {
                        Section {
                            Button {
                                kugouPageNum += 1
                                Task { await load(reset: false) }
                            } label: {
                                Text("加载更多")
                                    .font(BeansFont.appFont(14, .semibold))
                                    .foregroundStyle(Color.beansAmber)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .listRowBackground(Color.clear)
                    }
                }
                .beansScrollContentBackgroundHidden()
            }
        }
    }

    // MARK: - 插件音源评论

    /// 重建插件条目：`getMusicComments` 要的是插件自己的条目对象（里面有 bvid/aid），
    /// 不能传 App 归一化后的 `Song`。
    private var pluginItem: MFPluginMusicItem {
        let platform = song.pluginPlatform ?? ""
        return MFPluginMusicItem(
            id: "\(platform)|\(song.pluginItemID ?? "")",
            platform: platform,
            itemID: song.pluginItemID ?? "",
            title: song.name,
            artist: song.artists,
            album: song.album,
            artwork: song.coverURL?.absoluteString,
            durationMS: Int(song.duration * 1000),
            rawJSON: song.pluginRawJSON ?? "{}"
        )
    }

    /// 拉一页插件评论；返回 false 表示这个音源没有可用的评论接口。
    @MainActor
    private func loadPluginComments(page: Int) async throws -> Bool {
        // ① 插件自己实现了 MusicFree 的 getMusicComments（哔哩哔哩插件就有）
        let fetched = try await MFPluginManager.shared.pluginMusicComments(
            platform: song.pluginPlatform ?? "", item: pluginItem, page: page
        )
        // B 站条目 + 插件返回空，不能就此收场：条目里可能没有 aid，
        // 插件拿不到 oid 只会回一个空列表，这种情况改走 App 内置的原生解析。
        if let fetched, !fetched.comments.isEmpty || bilibiliBVID == nil {
            merge(fetched.comments, replace: page <= 1)
            pluginCommentsTotal = max(pluginCommentsTotal, pluginComments.count)
            pluginCommentsEnd = fetched.isEnd || fetched.comments.isEmpty
            return true
        }
        // ② 原生 B 站解析
        guard let bvid = bilibiliBVID else { return false }
        let result = try await BilibiliCommentsAPI.comments(bvid: bvid, page: page)
        merge(result.comments, replace: page <= 1)
        pluginCommentsTotal = result.total
        pluginCommentsEnd = result.comments.count < BilibiliCommentsAPI.pageSize
        return true
    }

    /// 首页整体替换，翻页只补新条目（按评论 id 去重）。
    private func merge(_ incoming: [SongComment], replace: Bool) {
        if replace {
            pluginComments = incoming
        } else {
            let existing = Set(pluginComments.map(\.id))
            pluginComments.append(contentsOf: incoming.filter { !existing.contains($0.id) })
        }
    }

    /// 评论条数里显示的来源名：B 站条目统一写成「哔哩哔哩」，
    /// 免得把插件注册名（如 "b站-ios"）直接摆到界面上。
    private var pluginPlatformLabel: String {
        bilibiliBVID != nil ? "哔哩哔哩" : (song.pluginPlatform ?? "插件音源")
    }

    private var pluginCommentList: some View {
        List {
            Section {
                Text(beansCommentCountText(
                    songName: song.name,
                    platform: pluginPlatformLabel,
                    count: pluginCommentsTotal > 0 ? pluginCommentsTotal : pluginComments.count
                ))
                .font(BeansFont.appFont(12))
                .foregroundStyle(Color.beansComment)
            }
            .listRowBackground(Color.clear)
            Section("评论") {
                ForEach(pluginComments) { comment in
                    CommentRow(comment: comment)
                        .listRowBackground(Color.clear)
                }
            }
            if !pluginCommentsEnd {
                Section {
                    Button {
                        pluginPageNum += 1
                        Task { await load(reset: false) }
                    } label: {
                        Text("加载更多")
                            .font(BeansFont.appFont(14, .semibold))
                            .foregroundStyle(Color.beansAmber)
                            .frame(maxWidth: .infinity)
                    }
                }
                .listRowBackground(Color.clear)
            }
        }
        .beansScrollContentBackgroundHidden()
    }

    @MainActor
    private func loadMore() async {
        offset += limit
        await load(reset: false)
    }
}

// MARK: - 评论行

struct CommentRow: View {
    @EnvironmentObject private var theme: ThemeStore
    let comment: SongComment

    var body: some View {
        let _ = theme.accent
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: comment.avatarURL) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.beansComment)
                }
            }
            .frame(width: 36, height: 36)
            .clipShape(Circle())
            .background(Color.beansGlassFill, in: Circle())

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(comment.nickname)
                        .font(BeansFont.appFont(13, .medium))
                        .foregroundStyle(Color.beansComment)
                        .lineLimit(1)
                    if comment.isHot {
                        Text("热评")
                            .font(BeansFont.appFont(9, .bold))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(LinearGradient.beansAccent, in: Capsule())
                    }
                    Spacer()
                    Text(beansRelativeTime(comment.time))
                        .font(BeansFont.appFont(11))
                        .foregroundStyle(Color.beansComment.opacity(0.8))
                }
                Text(comment.content)
                    .font(BeansFont.appFont(14))
                    .foregroundStyle(Color.beansLabel)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Label("\(comment.likedCount)", systemImage: "heart")
                        .font(BeansFont.appFont(11, .medium))
                        .foregroundStyle(Color.beansComment)
                        .labelStyle(.trailingIcon)
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
    }
}

// 图标在文字后面
extension LabelStyle where Self == TrailingIconLabelStyle {
    static var trailingIcon: TrailingIconLabelStyle { TrailingIconLabelStyle() }
}

struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon
        }
    }
}
