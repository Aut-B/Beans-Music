import Foundation

// MARK: - 内置音源：pyncmd（GD Studio）
//
// 这是 App 自带的直链提供方，**不需要用户导入、不需要 API Key**，
// 和「第三方音源」列表里那些用户自己加的源是两个体系，但共用同一条解析链
// （见 `UnblockService.resolve` 与 `PreferredSourceStore`）。
//
// 它的工作方式：拿一个**网易云歌曲 id**，向 GD Studio 换一条网易云原站直链
// （m701 / m801.music.126.net）。最高档 br=999 实测能返回 flac（约 800 kbps），
// 比多数插件音源默认给的 320k 高一大截，而且是一次轻量 HTTP 请求，通常 1 秒内返回。
//
// 为什么只按 id 取流、不自己搜索：
// GD Studio 的搜索接口排序很差 —— 搜「夜曲 周杰伦」返回的是一堆翻唱
// （Xai小爱、武钟旭……），正主根本不出现。拿它的搜索结果去取流必然张冠李戴。
// 所以匹配这件事交给 App 自己的网易云搜索（`NetEaseAPI.search`），
// 拿到可信的 id 之后再回来换直链。

/// pyncmd 的音质档，对应 GD Studio 的 `br` 参数。
enum PyncmdQuality: String, CaseIterable, Identifiable, Sendable {
    /// 请求最高档，服务端按实际可用音质返回（多为 flac）。
    case best = "999"
    case kb320 = "320"
    case kb128 = "128"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .best: return beansLocalized("最高音质", "Highest")
        case .kb320: return "320k"
        case .kb128: return "128k"
        }
    }

    var detail: String {
        switch self {
        case .best: return beansLocalized("优先无损（FLAC），拿不到时服务端自动降档", "Prefer lossless (FLAC); the server downgrades automatically")
        case .kb320: return beansLocalized("固定 320 kbps MP3，体积更小", "Fixed 320 kbps MP3, smaller files")
        case .kb128: return beansLocalized("最省流量，音质一般", "Lowest bandwidth, modest quality")
        }
    }

    /// 把服务端实际返回的码率折算成 App 内部的音质枚举。
    static func quality(forBitrate br: Int) -> ThirdPartyAudioQuality {
        if br >= 700 { return .flac }
        if br >= 300 { return .kb320 }
        return .kb128
    }
}

/// pyncmd 换回来的直链信息。
struct PyncmdResolved: Sendable {
    let url: URL
    /// 服务端返回的实际码率（kbps），0 表示未知。
    let bitrate: Int
    let sizeBytes: Int

    var quality: ThirdPartyAudioQuality { PyncmdQuality.quality(forBitrate: bitrate) }
}

enum PyncmdError: LocalizedError {
    case badResponse
    case notFound

    var errorDescription: String? {
        switch self {
        case .badResponse:
            return beansLocalized("pyncmd 返回格式异常", "pyncmd returned an unexpected response")
        case .notFound:
            return beansLocalized("pyncmd 没有这首歌的可播放地址", "pyncmd has no playable URL for this track")
        }
    }
}

enum PyncmdSource {
    private static let endpoint = "https://music-api.gdstudio.xyz/api.php"

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 8
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    /// 内存缓存：播放失败自动重试、以及「预热下一首直链」时不必再走一次网络。
    ///
    /// 网易云直链带时间戳、有效期约 20 分钟，缓存 8 分钟仍然安全。
    /// 原先只有 60 秒 —— 短到「上一首播完自动切下一首」时缓存必然已过期，
    /// 于是每首歌都要重新请求一遍，等待全落在用户耳朵里。
    private static let cacheLock = NSLock()
    private static var cache: [String: (resolved: PyncmdResolved, at: Date)] = [:]
    private static let cacheLifetime: TimeInterval = 480

    /// 按网易云歌曲 id 换直链。失败（无版权、id 无效、网络异常）返回 nil，
    /// 由调用方顺位递进到下一个音源。
    static func mediaURL(
        neteaseID: Int,
        quality: PyncmdQuality = .best,
        timeout: TimeInterval = 6
    ) async -> PyncmdResolved? {
        guard neteaseID > 0 else { return nil }
        let cacheKey = "\(neteaseID)|\(quality.rawValue)"
        if let cached = cachedValue(for: cacheKey) { return cached }

        guard var components = URLComponents(string: endpoint) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "types", value: "url"),
            URLQueryItem(name: "source", value: "netease"),
            URLQueryItem(name: "id", value: String(neteaseID)),
            URLQueryItem(name: "br", value: quality.rawValue),
        ]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )

        let started = Date()
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            BeansLogger.shared.log("pyncmd 请求失败：id=\(neteaseID)", level: .debug)
            return nil
        }

        let rawURL = (object["url"] as? String) ?? ""
        let br = (object["br"] as? NSNumber)?.intValue ?? 0
        let size = (object["size"] as? NSNumber)?.intValue ?? 0
        // br <= 0 表示源站没有这首歌（会员曲、已下架），url 也会是空串。
        guard !rawURL.isEmpty, br > 0,
              let mediaURL = URL(string: rawURL.replacingOccurrences(of: "http://", with: "https://")) else {
            BeansLogger.shared.log("pyncmd 无可用直链：id=\(neteaseID) br=\(br)", level: .debug)
            return nil
        }

        let resolved = PyncmdResolved(url: mediaURL, bitrate: br, sizeBytes: size)
        store(resolved, for: cacheKey)
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        BeansLogger.shared.log(
            "pyncmd 命中：id=\(neteaseID) 码率=\(br)kbps 体积=\(size) 耗时=\(elapsed)ms",
            level: .debug
        )
        return resolved
    }

    // MARK: - 缓存

    private static func cachedValue(for key: String) -> PyncmdResolved? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let entry = cache[key] else { return nil }
        guard Date().timeIntervalSince(entry.at) < cacheLifetime else {
            cache.removeValue(forKey: key)
            return nil
        }
        return entry.resolved
    }

    private static func store(_ value: PyncmdResolved, for key: String) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        // 顺手清掉过期项，避免长期运行后字典无限增长。
        let now = Date()
        cache = cache.filter { now.timeIntervalSince($0.value.at) < cacheLifetime }
        cache[key] = (value, now)
    }

    /// 供界面显示来源名用。写成计算属性，切语言时能跟着变。
    static var sourceTitle: String { beansLocalized("pyncmd 高音质", "pyncmd (HQ)") }
}

extension PyncmdSource {
    /// 按「歌名 + 歌手 + 时长」在网易云找同一条曲目，用来给**插件音源**的歌曲
    /// 找一条可以走 pyncmd 的网易云 id。
    ///
    /// 判据刻意从严（歌手要命中、时长差 ≤ 12 秒）：插件条目的歌手可能是
    /// 哔哩哔哩 UP 主名，宽松匹配很容易把一段视频换成一首毫不相干的歌。
    /// 找不准就返回 nil，让调用方退回插件自己解析 —— 宁可音质差一点，不能播错歌。
    static func matchNeteaseSong(name: String, artists: String, durationMS: Int) async -> Song? {
        let keyword = [name, artists]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: " ")
        guard !keyword.isEmpty,
              let results = try? await NetEaseAPI.shared.search(keyword: keyword, limit: 8),
              !results.isEmpty else { return nil }

        let target = Double(durationMS) / 1000.0
        let artistTokens = artists
            .lowercased()
            .components(separatedBy: CharacterSet(charactersIn: "/&,，、 ").union(.whitespacesAndNewlines))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 2 }

        guard target > 0, !artistTokens.isEmpty else { return nil }
        return results.first { candidate in
            let durationOK = candidate.duration > 0 && abs(candidate.duration - target) < 12
            guard durationOK else { return false }
            let candidateArtists = candidate.artists.lowercased()
            return artistTokens.contains { candidateArtists.contains($0) }
        }
    }
}
