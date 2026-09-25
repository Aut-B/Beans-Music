import Foundation

/// 歌单置顶。
///
/// 置顶单独存一份，不写进 `LocalPlaylist` / `Playlist` 本体：
/// `LocalPlaylist` 是要 WebDAV 同步、还要导出成快照的 Codable 结构，
/// 往里加字段等于改数据格式，旧设备恢复备份时会丢字段。置顶只是本机
/// 的显示偏好，放在独立 store 里最简单，也不影响同步往返。
///
/// 键的写法：`"<来源>-<歌单标识>"`，云端用数字 id，本地歌单用 UUID 字符串。
/// 这样两个体系的歌单可以共用一份置顶表，不会撞键。
final class PlaylistPinStore: ObservableObject {
    static let shared = PlaylistPinStore()

    private let defaults = UserDefaults.standard
    private let key = "beans.playlistPinnedKeys.v1"

    @Published private(set) var pinnedKeys: Set<String>

    private init() {
        if let saved = defaults.array(forKey: key) as? [String] {
            pinnedKeys = Set(saved)
        } else {
            pinnedKeys = []
        }
    }

    func isPinned(_ pinKey: String) -> Bool {
        pinnedKeys.contains(pinKey)
    }

    func setPinned(_ pinKey: String, _ pinned: Bool) {
        guard !pinKey.isEmpty else { return }
        if pinned {
            guard !pinnedKeys.contains(pinKey) else { return }
            pinnedKeys.insert(pinKey)
        } else {
            guard pinnedKeys.contains(pinKey) else { return }
            pinnedKeys.remove(pinKey)
        }
        defaults.set(pinnedKeys.sorted(), forKey: key)
    }

    func toggle(_ pinKey: String) {
        setPinned(pinKey, !isPinned(pinKey))
    }

    // MARK: - 置顶键

    static func cloudKey(source: SongSource, id: Int) -> String {
        "\(source.rawValue)-\(id)"
    }

    static func localKey(_ id: UUID) -> String {
        "local-\(id.uuidString)"
    }

    // MARK: - 排序

    /// 把置顶项提到最前面，置顶组与未置顶组各自保持传入顺序。
    ///
    /// 自定义排序（`SyncedPlaylistOrderStore` / 本地歌单顺序）照旧生效，
    /// 置顶只在它之上再叠一层——用户拖动排好之后把常用的几个钉住，
    /// 不用为了置顶把顺序整个重排一遍。
    func pinnedFirst<T>(_ items: [T], key: (T) -> String) -> [T] {
        guard !pinnedKeys.isEmpty else { return items }
        var pinned: [T] = []
        var rest: [T] = []
        pinned.reserveCapacity(items.count)
        rest.reserveCapacity(items.count)
        for item in items {
            if pinnedKeys.contains(key(item)) {
                pinned.append(item)
            } else {
                rest.append(item)
            }
        }
        return pinned.isEmpty ? items : pinned + rest
    }
}
