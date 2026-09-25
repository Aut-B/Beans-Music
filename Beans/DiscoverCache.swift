import Foundation

/// 主页数据缓存：避免每次切回主页 Tab 都重新请求接口。
/// 排行榜 / 歌单广场缓存 1 小时，每日推荐缓存 6 小时；
/// 点右上角刷新或下拉刷新会强制重新加载。
///
/// 快照**落盘**而不只是放在内存里——内存版的代价是：App 每次冷启动主页
/// 都必须等一轮网络才出内容，老机器（iPhone 6s 这类）上就是「主页要刷新
/// 很久」。落盘之后冷启动先把上次的内容铺出来，再在后台静默刷新。
final class DiscoverCache {
    static let shared = DiscoverCache()

    /// 单个平台的主页完整数据快照
    struct Snapshot: Codable {
        var dailySongs: [Song] = []
        var topLists: [TopList] = []
        var personalized: [Playlist] = []
        var qqTopLists: [QQTopInfo] = []
        var kugouTopLists: [KugouTopInfo] = []
        var savedAt: Date = .distantPast

        var isEmpty: Bool {
            dailySongs.isEmpty && topLists.isEmpty && personalized.isEmpty
                && qqTopLists.isEmpty && kugouTopLists.isEmpty
        }
    }

    /// 排行榜 / 歌单广场缓存时长（秒）
    let listTTL: TimeInterval = 3600
    /// 每日推荐缓存时长（秒，推荐内容按天更新）
    let dailyTTL: TimeInterval = 6 * 3600

    private var store: [String: Snapshot] = [:]
    private let persistenceQueue = DispatchQueue(label: "Beans.DiscoverCache.persistence", qos: .utility)
    private let lock = NSLock()

    private var fileURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("beans.discoverCache.json")
    }

    private init() {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode([String: Snapshot].self, from: data) else { return }
        store = saved
    }

    func cached(for source: SearchProvider) -> Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        return store[source.rawValue]
    }

    func save(_ snapshot: Snapshot, for source: SearchProvider) {
        lock.lock()
        store[source.rawValue] = snapshot
        let copy = store
        lock.unlock()
        persist(copy)
    }

    /// 缓存是否仍然新鲜：每日推荐单独放宽到 6 小时，其余按 1 小时
    func isFresh(_ snapshot: Snapshot) -> Bool {
        let age = Date().timeIntervalSince(snapshot.savedAt)
        let ttl = snapshot.dailySongs.isEmpty ? listTTL : dailyTTL
        return age < ttl
    }

    private func persist(_ snapshotStore: [String: Snapshot]) {
        guard let url = fileURL,
              let data = try? JSONEncoder().encode(snapshotStore) else { return }
        persistenceQueue.async {
            try? data.write(to: url, options: .atomic)
        }
    }
}
