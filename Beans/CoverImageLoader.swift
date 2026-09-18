import CryptoKit
import SwiftUI
import UIKit

// MARK: - 封面图缓存
//
// 原实现直接使用 SwiftUI 的 `AsyncImage`。它的相位（phase）是跟着视图实例走的：
// 视图一旦重建——列表滚动复用、从播放页退回首页时迷你播放器重新插入——就会重新
// 从 `.empty` 开始，于是先渲染占位图、再淡入真图，观感上就是封面「一闪一闪」。
//
// 这里改为自己持有内存 + 磁盘缓存，并在 `body` 里同步查询**内存**缓存：
// 视图重建时首帧就能拿到已解码的图片，不再有占位图闪烁；同时省掉了重复的网络
// 请求与解码，列表滚动更稳。磁盘兜底只放在异步链路里，避免在主线程做文件 IO。

enum CoverImageCache {
    private static let memory: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 600
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    /// 同一 URL 的并发请求合并，避免列表里同一张图被反复下载。
    private static var inflight: [String: Task<UIImage?, Never>] = [:]
    private static let lock = NSLock()

    private static var diskDirectory: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BeansCoverCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func key(_ url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 同步查询（仅内存）：给 `body` 用，绝不能碰磁盘。
    static func memoryImage(for url: URL?) -> UIImage? {
        guard let url else { return nil }
        return memory.object(forKey: key(url) as NSString)
    }

    private static func diskImage(for url: URL) -> UIImage? {
        let path = diskDirectory.appendingPathComponent(key(url)).path
        guard let image = BeansImageFileCache.image(at: path) else { return nil }
        memory.setObject(image, forKey: key(url) as NSString)
        return image
    }

    private static func store(_ image: UIImage, data: Data, for url: URL) {
        memory.setObject(image, forKey: key(url) as NSString, cost: data.count)
        try? data.write(to: diskDirectory.appendingPathComponent(key(url)), options: .atomic)
    }

    /// 取图：内存 → 磁盘 → 网络（并发合并）。
    static func image(for url: URL) async -> UIImage? {
        if let hit = memoryImage(for: url) { return hit }
        if let hit = diskImage(for: url) { return hit }
        let cacheKey = key(url)
        lock.lock()
        if let existing = inflight[cacheKey] {
            lock.unlock()
            return await existing.value
        }
        let task = Task<UIImage?, Never> {
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.cachePolicy = .returnCacheDataElseLoad
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let image = UIImage(data: data) else { return nil }
            store(image, data: data, for: url)
            return image
        }
        inflight[cacheKey] = task
        lock.unlock()
        let result = await task.value
        lock.lock()
        inflight[cacheKey] = nil
        lock.unlock()
        return result
    }

    static func clear() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: diskDirectory)
    }
}

// MARK: - 单个封面的加载器

/// 刻意保持非隔离（与 App 里其它 Store 一致）：所有发布都显式切回主线程，
/// 这样 `@StateObject private var loader = CoverImageLoader()` 不会引入 actor 隔离问题。
final class CoverImageLoader: ObservableObject {
    @Published private(set) var image: UIImage?
    private(set) var loadedURL: URL?
    private var task: Task<Void, Never>?

    /// 供 `body` 同步取图：只有在图片确实属于当前 URL 时才返回。
    func image(for url: URL?) -> UIImage? {
        guard loadedURL == url else { return nil }
        return image
    }

    func load(_ target: URL?) {
        guard loadedURL != target else { return }
        task?.cancel()
        loadedURL = target
        image = CoverImageCache.memoryImage(for: target)
        guard image == nil, let target else { return }
        task = Task { [weak self] in
            let loaded = await CoverImageCache.image(for: target)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.loadedURL == target else { return }
                self.image = loaded
            }
        }
    }
}
