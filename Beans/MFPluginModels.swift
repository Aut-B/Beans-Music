import Foundation

// MARK: - MusicFree 插件模型
//
// 这套模型对应 MusicFree（React Native 版）的插件协议：
// 插件 `module.exports` 出 { platform, version, search, getMediaSource, ... }，
// 搜索返回音乐条目数组，getMediaSource 依据条目返回可播放地址。
//
// 移植自 Aut-B/kumone 的 dev-musicfree 分支（Kumone 的 Core/Plugins），
// 命名改为 Beans 侧前缀以免与既有类型冲突。

/// 归一化后的插件搜索结果条目。
struct MFPluginMusicItem: Identifiable, Hashable, Sendable {
    /// 复合稳定 id："platform|itemID"。
    let id: String
    let platform: String
    let itemID: String
    let title: String
    let artist: String
    let album: String
    let artwork: String?
    let durationMS: Int
    /// 插件返回的**原始条目 JSON**，回传给 getMediaSource 时必须原样送回。
    let rawJSON: String

    var artworkURL: URL? {
        guard let artwork, !artwork.isEmpty else { return nil }
        return URL(string: artwork)
    }

    var duration: TimeInterval { Double(durationMS) / 1000.0 }

    /// 从插件返回的原始字典构建。缺少可用 id 时返回 nil。
    /// `platform` 作为兜底来源（导入的歌单条目会自带 platform）。
    init?(normalizing dict: [String: Any], platform: String) {
        guard let itemID = dict["id"] as? String, !itemID.isEmpty else { return nil }
        // 路由键必须与已挂载实例一致，优先用上下文里的 platform（注册名）。
        let resolvedPlatform = platform.isEmpty
            ? ((dict["platform"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? platform)
            : platform
        self.platform = resolvedPlatform
        self.itemID = itemID
        id = "\(resolvedPlatform)|\(itemID)"
        title = (dict["title"] as? String) ?? (dict["name"] as? String) ?? itemID
        artist = (dict["artist"] as? String) ?? beansLocalized("未知歌手", "Unknown artist")
        album = (dict["album"] as? String) ?? beansLocalized("未知专辑", "Unknown album")
        artwork = (dict["artwork"] as? String) ?? (dict["picUrl"] as? String)
        let durationValue = (dict["duration"] as? NSNumber)?.doubleValue ?? 0
        // MusicFree 规范是秒，但部分插件（wy.js）返回毫秒。
        // 正常歌曲不会超过 100000 秒（约 28 小时），超过即按毫秒处理。
        durationMS = durationValue > 100_000 ? Int(durationValue) : Int(durationValue * 1000)
        rawJSON = (try? JSONSerialization.data(withJSONObject: dict)).flatMap {
            String(data: $0, encoding: .utf8)
        } ?? "{}"
    }

    /// 直接构造（原生 B 站解析等场景）。
    init(id: String, platform: String, itemID: String, title: String, artist: String,
         album: String, artwork: String?, durationMS: Int, rawJSON: String) {
        self.id = id
        self.platform = platform
        self.itemID = itemID
        self.title = title
        self.artist = artist
        self.album = album
        self.artwork = artwork
        self.durationMS = durationMS
        self.rawJSON = rawJSON
    }
}

/// 插件 `getMediaSource` 解析出的可播放源。
struct MFPluginMediaSource: Sendable {
    let url: URL?
    let headers: [String: String]?

    static let empty = MFPluginMediaSource(url: nil, headers: nil)
}

/// 插件挂载结果。
struct MFPluginMountResult: Sendable {
    let platform: String
    /// 插件声明的 userVariables：[{key, name, defaultValue}]。
    let userVariables: [[String: Any]]
}

// MARK: - 音质映射

extension ThirdPartyAudioQuality {
    /// 把 Beans 的第三方音质档位映射到 MusicFree 插件的音质键。
    /// MusicFree 只认 standard / high / super 三档。
    var mfPluginQuality: String {
        switch self {
        case .kb128: return "standard"
        case .kb320: return "high"
        case .flac, .flac24bit, .hires, .atmos, .atmosPlus, .master: return "super"
        }
    }
}
