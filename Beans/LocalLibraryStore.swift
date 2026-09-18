import Foundation

/// 本地歌单（保存在设备本机，不依赖任何平台账号）
struct LocalPlaylist: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var songs: [Song] = []
    var createdAt = Date()

    enum CodingKeys: String, CodingKey { case id, name, songs, createdAt }

    init(id: UUID = UUID(), name: String, songs: [Song] = [], createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.songs = songs
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "未命名歌单"
        songs = try c.decodeIfPresent([Song].self, forKey: .songs) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
    }
}

/// 本地音乐库：本地歌单的创建 / 删除 / 收藏歌曲，UserDefaults JSON 持久化（覆盖安装不丢失）
final class LocalLibraryStore: ObservableObject {
    static let shared = LocalLibraryStore()

    @Published var playlists: [LocalPlaylist] {
        didSet { save() }
    }

    private let defaults = UserDefaults.standard
    private let key = "beans.localLibrary.playlists"
    /// 自动上传的防抖任务：连续增删歌曲时只发一次请求。
    private var autoSyncTask: Task<Void, Never>?

    private init() {
        if let data = defaults.data(forKey: key),
           let list = try? JSONDecoder().decode([LocalPlaylist].self, from: data) {
            playlists = list
        } else {
            playlists = []
        }
    }

    @discardableResult
    func createPlaylist(name: String) -> LocalPlaylist {
        let playlist = LocalPlaylist(name: name)
        playlists.append(playlist)
        return playlist
    }

    func deletePlaylist(id: UUID) {
        playlists.removeAll { $0.id == id }
    }

    func renamePlaylist(id: UUID, name: String) {
        guard let idx = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[idx].name = name
    }

    /// 调整本地歌单顺序，顺序会随歌单一起持久化。
    func movePlaylist(id: UUID, offset: Int) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        let destination = index + offset
        guard playlists.indices.contains(destination) else { return }
        var reordered = playlists
        reordered.swapAt(index, destination)
        playlists = reordered
    }

    /// 使用 List 的拖动结果更新顺序，显式重新赋值确保 @Published 与持久化都能触发。
    func movePlaylists(from offsets: IndexSet, to destination: Int) {
        var reordered = playlists
        reordered.move(fromOffsets: offsets, toOffset: destination)
        playlists = reordered
    }

    /// 添加歌曲到本地歌单（按 identityKey 去重）
    func addSong(_ song: Song, to id: UUID) {
        guard let idx = playlists.firstIndex(where: { $0.id == id }) else { return }
        guard !playlists[idx].songs.contains(where: { $0.identityKey == song.identityKey }) else { return }
        playlists[idx].songs.append(song)
    }

    @discardableResult
    func addSongs(_ songs: [Song], to id: UUID) -> Int {
        let before = playlists.first(where: { $0.id == id })?.songs.count ?? 0
        for song in songs {
            addSong(song, to: id)
        }
        let after = playlists.first(where: { $0.id == id })?.songs.count ?? before
        return after - before
    }

    /// 调整歌单内歌曲顺序（List 拖动排序的结果），顺序随歌单一起持久化。
    func moveSongs(playlistID: UUID, from offsets: IndexSet, to destination: Int) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        var reordered = playlists
        reordered[idx].songs.move(fromOffsets: offsets, toOffset: destination)
        playlists = reordered
    }

    /// 单曲上移 / 下移一步（`offset` 传 -1 或 1）。
    /// 拖动排序在长歌单里不好对准，菜单里的上移/下移用来做精细微调。
    @discardableResult
    func moveSong(playlistID: UUID, songIdentity: String, offset: Int) -> Bool {
        guard let idx = playlists.firstIndex(where: { $0.id == playlistID }),
              let from = playlists[idx].songs.firstIndex(where: { $0.identityKey == songIdentity }) else { return false }
        let to = from + offset
        guard playlists[idx].songs.indices.contains(to) else { return false }
        var reordered = playlists
        reordered[idx].songs.swapAt(from, to)
        playlists = reordered
        return true
    }

    func containsSong(_ song: Song?) -> Bool {
        guard let song else { return false }
        return playlists.contains { $0.songs.contains { $0.identityKey == song.identityKey } }
    }

    /// 含有这首歌的本地歌单数量（换源面板用来判断「改了有没有用」）。
    func playlistCount(containing song: Song) -> Int {
        playlists.filter { $0.songs.contains { $0.identityKey == song.identityKey } }.count
    }

    /// 把本地歌单里某首歌**原地换成另一个来源的同名曲目**（换源）。
    ///
    /// 只改歌单里的条目，不动播放队列与播放历史 —— 换源本质是「以后从哪个平台取流」，
    /// 已经播出去的东西不必追溯。位置保持不变，顺序不会被打乱；
    /// 如果该歌单里本来就有目标曲目，则直接删掉旧条目，避免出现两条一样的歌。
    ///
    /// 返回值：被改动的歌单数量（0 表示这首歌不在任何本地歌单里）。
    @discardableResult
    func rebindSong(oldIdentity: String, to newSong: Song) -> Int {
        var changed = 0
        var result = playlists
        for index in result.indices {
            guard let position = result[index].songs.firstIndex(where: { $0.identityKey == oldIdentity }) else { continue }
            if result[index].songs.contains(where: { $0.identityKey == newSong.identityKey }) {
                result[index].songs.remove(at: position)
            } else {
                result[index].songs[position] = newSong
            }
            changed += 1
        }
        if changed > 0 { playlists = result }
        return changed
    }

    /// 同一次换源可能被应用在多首歌上（批量场景），这里做一层去重合并。
    @discardableResult
    func rebindSongs(_ pairs: [(oldIdentity: String, newSong: Song)]) -> Int {
        var total = 0
        for pair in pairs {
            total += rebindSong(oldIdentity: pair.oldIdentity, to: pair.newSong)
        }
        return total
    }

    @discardableResult
    func addToDefaultFavorites(_ song: Song, name: String = "我的收藏歌单") -> String {
        let playlist = playlists.first(where: { $0.name == name }) ?? createPlaylist(name: name)
        let before = playlists.first(where: { $0.id == playlist.id })?.songs.count ?? 0
        addSong(song, to: playlist.id)
        let after = playlists.first(where: { $0.id == playlist.id })?.songs.count ?? before
        return after > before ? "已加入「\(playlist.name)」" : "已在「\(playlist.name)」中"
    }

    @discardableResult
    func syncSongs(_ songs: [Song], intoPlaylistNamed name: String = "三平台喜欢") -> Int {
        let target: LocalPlaylist
        if let existing = playlists.first(where: { $0.name == name }) {
            target = existing
        } else {
            target = createPlaylist(name: name)
        }
        let before = playlists.first(where: { $0.id == target.id })?.songs.count ?? 0
        for song in songs { addSong(song, to: target.id) }
        return (playlists.first(where: { $0.id == target.id })?.songs.count ?? before) - before
    }

    func removeSong(playlistID: UUID, songIdentity: String) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[idx].songs.removeAll { $0.identityKey == songIdentity }
    }

    @discardableResult
    func removeSongFromAllPlaylists(_ song: Song) -> Int {
        var removed = 0
        for index in playlists.indices {
            let before = playlists[index].songs.count
            playlists[index].songs.removeAll { $0.identityKey == song.identityKey }
            removed += before - playlists[index].songs.count
        }
        return removed
    }

    private func save() {
        if let data = try? JSONEncoder().encode(playlists) {
            defaults.set(data, forKey: key)
        }
        scheduleAutoSync()
    }

    /// 开了「改动后自动上传」就延迟几秒静默上传一次，把连续操作合并成一次请求。
    private func scheduleAutoSync() {
        autoSyncTask?.cancel()
        autoSyncTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            let sync = WebDAVSyncStore.shared
            guard sync.autoSync, sync.config.isComplete, !sync.status.isWorking else { return }
            _ = try? await sync.upload()
        }
    }

    // MARK: - 云端同步

    /// 合并外部歌单（WebDAV 快照 / MusicFree 备份导入）。
    ///
    /// 同 id 或同名的歌单做**并集**：按 `identityKey` 去重后把云端独有的歌曲补进来，
    /// 本机已有的顺序保持不变；本地没有的歌单整体追加。返回（新增歌单数, 新增歌曲数）。
    @discardableResult
    func merge(_ incoming: [LocalPlaylist]) -> (playlists: Int, songs: Int) {
        var addedPlaylists = 0
        var addedSongs = 0
        var result = playlists
        for remote in incoming {
            if let index = result.firstIndex(where: { $0.id == remote.id || $0.name == remote.name }) {
                let existing = Set(result[index].songs.map(\.identityKey))
                let fresh = remote.songs.filter { !existing.contains($0.identityKey) }
                if !fresh.isEmpty {
                    result[index].songs.append(contentsOf: fresh)
                    addedSongs += fresh.count
                }
            } else {
                result.append(remote)
                addedPlaylists += 1
                addedSongs += remote.songs.count
            }
        }
        if result != playlists { playlists = result }
        return (addedPlaylists, addedSongs)
    }

    /// 用云端快照整体替换本机歌单（危险操作，调用方需二次确认）。
    func replaceAll(_ incoming: [LocalPlaylist]) {
        playlists = incoming
    }
}
