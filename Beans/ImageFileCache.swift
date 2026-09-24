import UIKit

/// 复用本地图片解码结果，避免设置页/歌词页滚动时反复从磁盘解码大图。
///
/// 1.10.0：加上 cost 记账与上限。原实现是「只进不出」的无上限 NSCache，
/// 壁纸、歌词背景这类整屏大图（一张 1170×2532 解出来约 12 MB）多看几张
/// 就会把内存顶到几百 MB，触发系统内存压力后 App 整体变卡。
enum BeansImageFileCache {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()

    static func image(at path: String) -> UIImage? {
        guard !path.isEmpty else { return nil }
        let key = path as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let image = UIImage(contentsOfFile: path) else { return nil }
        cache.setObject(image, forKey: key, cost: cost(of: image))
        return image
    }

    /// 解码后的位图字节数（width × height × 4）。
    private static func cost(of image: UIImage) -> Int {
        let pixels = image.size.width * image.scale * image.size.height * image.scale
        return Int(pixels * 4)
    }

    static func remove(_ path: String) {
        guard !path.isEmpty else { return }
        cache.removeObject(forKey: path as NSString)
    }

    // MARK: - 缩略图（设置页壁纸网格用）

    /// 只查缓存，不碰磁盘。异步加载路径上先用它拿到「已经解好的那张」，
    /// 避免已经显示过的缩略图在重建时闪一下占位色。
    static func cachedImage(at path: String) -> UIImage? {
        guard !path.isEmpty else { return nil }
        return cache.object(forKey: path as NSString)
    }

    /// 下采样读取。
    ///
    /// 壁纸格子只有 108pt 高，却按整图（常见 1170×2532，解出来约 12 MB）解码 ——
    /// 设置页展开外观面板时要为每张壁纸做一遍，全部压在渲染帧里。
    /// 这里改到后台队列，并顺手缩到 `maxPixelSize` 见方：解码工作量与常驻内存
    /// 都降两个数量级，缓存也不会被几张壁纸挤爆。
    static func thumbnail(at path: String, maxPixelSize: CGFloat) async -> UIImage? {
        guard !path.isEmpty else { return nil }
        if let cached = cachedImage(at: path) { return cached }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let source = UIImage(contentsOfFile: path) else {
                    continuation.resume(returning: nil)
                    return
                }
                let size = CGSize(width: maxPixelSize, height: maxPixelSize)
                let thumb = source.preparingThumbnail(of: size) ?? source
                cache.setObject(thumb, forKey: path as NSString, cost: cost(of: thumb))
                continuation.resume(returning: thumb)
            }
        }
    }

    static func removeAll() {
        cache.removeAllObjects()
    }
}
