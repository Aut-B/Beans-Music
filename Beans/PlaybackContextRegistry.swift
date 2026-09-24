import Foundation

/// 给长列表里的 `SongCell` 传「点这一行该播哪个上下文」的轻量令牌。
///
/// 这一层看起来多余，但直接给每个 cell 传 `[Song]` 的代价高得离谱：
/// SwiftUI 判断某个已渲染的 cell 需不需要重建时，会把它新旧两个 View 值的
/// 存储属性逐个比较 —— 遇到数组就是**逐元素**比较（`Song` 字段里还有多个
/// String）。于是「一首歌单 N 首」的页面每次 body 重算都要做 N × N 次比较，
/// 一千首就是上百万次；而 `@ObservedObject` 的任何一次变化（切歌、收藏、
/// 播放状态）都会触发整页重算。表现出来就是「一进歌单，滑动就顿」。
///
/// 换成令牌之后，cell 之间的比较退化成一次短字符串比较；
/// 真正需要那个数组的时候（用户点「立即播放」）再按令牌取回来。
final class PlaybackContextRegistry {
    static let shared = PlaybackContextRegistry()

    private let lock = NSLock()
    private var storage: [String: [Song]] = [:]
    private var insertionOrder: [String] = []
    /// 最多同时保留的上下文数量。可见的列表通常只有一两个，
    /// 留 8 个是为了覆盖「曲库页 + 子页 + 搜索结果」同时挂载的情况。
    private let capacity = 8

    /// 登记一份播放上下文。重复登记同一个 key 时覆盖内容但不改变淘汰顺序。
    func register(_ songs: [Song], key: String) {
        guard !key.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        if storage[key] == nil {
            insertionOrder.append(key)
        }
        storage[key] = songs
        while insertionOrder.count > capacity, let oldest = insertionOrder.first {
            insertionOrder.removeFirst()
            // 不用 removeValue(forKey:) 的返回值 —— 这里只需要释放引用。
            storage.removeValue(forKey: oldest)
        }
    }

    func songs(for key: String) -> [Song]? {
        guard !key.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }
}
