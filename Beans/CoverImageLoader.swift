import CryptoKit
import ImageIO
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
//
// 2026-09-19（1.10.0，流畅度优化）：增加**按显示尺寸降采样**。
// 之前不论行内 46pt 的小封面还是播放页的大封面，都把原图整张解码：
// 一张 1000×1000 的封面解码后约 4 MB 位图，一屏 10 行就是 40 MB 的
// 解码开销与内存带宽——iPhone 12 滚动时的卡顿和发热有很大一部分来自这里。
// 现在按「尺寸档」缓存缩略图（128/256/512/1024/1280），行内只解码 256 档，
// 解码量和内存都降一个数量级；同一 URL 的不同档位各存一份，互不干扰。

enum CoverImageCache {
    private static let memory: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 600
        // 现在 cost 按**解码后字节数**计（见 store），64 MB 能装下约 250 张
        // 256 档缩略图，够一屏列表反复滚动。
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    /// 同一 URL 的并发请求合并，避免列表里同一张图被反复下载。
    private static var inflight: [String: Task<UIImage?, Never>] = [:]
    /// URL → SHA256 的记忆表：`body` 里每个可见行都会查一次缓存，
    /// 反复算 SHA256 是白费 CPU，这里缓存住。
    private static var digestMemo: [String: String] = [:]
    private static let lock = NSLock()

    /// 尺寸档：向上取整到这几个档位之一。
    /// 分档而不是用精确尺寸，是为了让同一张图在不同行高下能复用同一份缓存。
    static func bucket(forPixel pixel: CGFloat) -> Int {
        let steps: [CGFloat] = [128, 256, 512, 1024]
        for step in steps where pixel <= step { return Int(step) }
        return 1280
    }

    private static var diskDirectory: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BeansCoverCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 取 URL 的 SHA256（带记忆表）。
    private static func digest(_ url: URL) -> String {
        let key = url.absoluteString
        lock.lock()
        if let hit = digestMemo[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        let digest = SHA256.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }.joined()
        lock.lock()
        digestMemo[key] = digest
        lock.unlock()
        return digest
    }

    private static func cacheKey(_ url: URL, bucket: Int) -> NSString {
        "\(digest(url))@\(bucket)" as NSString
    }

    private static func diskPath(_ url: URL) -> String {
        diskDirectory.appendingPathComponent(digest(url)).path
    }

    /// 同步查询（仅内存）：给 `body` 用，绝不能碰磁盘。
    static func memoryImage(for url: URL?, maxPixel: CGFloat = 256) -> UIImage? {
        guard let url else { return nil }
        return memory.object(forKey: cacheKey(url, bucket: bucket(forPixel: maxPixel)))
    }

    /// 按最大边长解码缩略图：走 ImageIO，只解出需要的那一层，
    /// 不会先把原图整张解进内存再缩放。
    private static func downsample(_ data: Data, maxPixel: Int) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cg)
    }

    private static func diskImage(for url: URL, bucket: Int) -> UIImage? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: diskPath(url))),
              let image = downsample(data, maxPixel: bucket) else { return nil }
        store(image, for: url, bucket: bucket)
        return image
    }

    /// cost 用**解码后**的字节数：原实现用压缩后的 data.count 记账，
    /// 会让缓存实际占用远超上限（几百 MB 的位图被当成几 MB 统计）。
    private static func store(_ image: UIImage, for url: URL, bucket: Int) {
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        memory.setObject(image, forKey: cacheKey(url, bucket: bucket), cost: cost)
    }

    /// 取图：内存 → 磁盘 → 网络（并发合并）。`maxPixel` 是期望的最大边长（像素）。
    static func image(for url: URL, maxPixel: CGFloat) async -> UIImage? {
        let bucket = bucket(forPixel: maxPixel)
        if let hit = memoryImage(for: url, maxPixel: maxPixel) { return hit }
        if let hit = diskImage(for: url, bucket: bucket) { return hit }

        let key = "\(digest(url))@\(bucket)"
        lock.lock()
        if let existing = inflight[key] {
            lock.unlock()
            return await existing.value
        }
        let task = Task<UIImage?, Never> {
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.cachePolicy = .returnCacheDataElseLoad
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let image = downsample(data, maxPixel: bucket) else { return nil }
            // 磁盘上保留原始数据：换档位（比如进播放页要 1280）时还能重新裁一次。
            try? data.write(to: URL(fileURLWithPath: diskPath(url)), options: .atomic)
            store(image, for: url, bucket: bucket)
            return image
        }
        inflight[key] = task
        lock.unlock()
        let result = await task.value
        lock.lock()
        inflight[key] = nil
        lock.unlock()
        return result
    }

    static func clear() {
        memory.removeAllObjects()
        lock.lock()
        digestMemo.removeAll()
        lock.unlock()
        try? FileManager.default.removeItem(at: diskDirectory)
    }
}

// MARK: - 单个封面的加载器

/// 刻意保持非隔离（与 App 里其它 Store 一致）：所有发布都显式切回主线程，
/// 这样 `@StateObject private var loader = CoverImageLoader()` 不会引入 actor 隔离问题。
final class CoverImageLoader: ObservableObject {
    @Published private(set) var image: UIImage?
    private(set) var loadedURL: URL?
    /// 已加载图对应的像素档：尺寸变大时要重新取（行内 256 档直接放大到播放页会糊）。
    private(set) var loadedBucket = 0
    private var task: Task<Void, Never>?

    /// 供 `body` 同步取图：只有在图片确实属于当前 URL 时才返回。
    func image(for url: URL?, maxPixel: CGFloat = 256) -> UIImage? {
        guard loadedURL == url, loadedBucket >= CoverImageCache.bucket(forPixel: maxPixel) else { return nil }
        return image
    }

    func load(_ target: URL?, maxPixel: CGFloat = 256) {
        let bucket = CoverImageCache.bucket(forPixel: maxPixel)
        guard loadedURL != target || loadedBucket < bucket else { return }
        task?.cancel()
        loadedURL = target
        loadedBucket = bucket
        image = CoverImageCache.memoryImage(for: target, maxPixel: maxPixel)
        guard image == nil, let target else { return }
        task = Task { [weak self] in
            let loaded = await CoverImageCache.image(for: target, maxPixel: CGFloat(bucket))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.loadedURL == target, self.loadedBucket == bucket else { return }
                self.image = loaded
            }
        }
    }
}
