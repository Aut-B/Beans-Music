import Foundation
import SwiftUI

/// 首选音源（pyncmd）配置的**值类型快照**。
///
/// 解析链跑在非主线程（`UnblockService` 是 nonisolated，
/// `PlayerManager.loadCurrent` 里的 `Task` 也不在主线程），
/// 直接跨线程读主线程隔离的 store 会编译不过，所以统一取一份快照再传下去。
struct PreferredSourceSnapshot: Sendable {
    var enabled: Bool
    /// 网易云歌曲优先用 pyncmd 拿高音质直链，拿不到再走官方接口。
    var preferForNetease: Bool
    /// 插件音源歌曲先用 pyncmd 试一次（按歌名+歌手匹配网易云），失败再回到插件本身。
    var preferForPlugin: Bool
    var quality: PyncmdQuality
}

/// UserDefaults 键。放在文件级而不是类里，
/// 是因为 `PlayerManager` 的同步热路径（`externalSourcesEnabled`）需要非主线程直接读，
/// 那条路径不能 await 到主线程去取快照。
private enum PreferredSourceKeys {
    static let enabled = "beans.pyncmd.enabled"
    static let neteaseFirst = "beans.pyncmd.neteaseFirst"
    static let pluginFirst = "beans.pyncmd.pluginFirst"
    static let quality = "beans.pyncmd.quality"
}

/// 首选音源设置。默认开启 —— pyncmd 单次请求通常 1 秒内返回，
/// 而且能拿到比插件音源更高的音质（实测 flac 约 800 kbps）。
@MainActor
final class PreferredSourceStore: ObservableObject {
    static let shared = PreferredSourceStore()

    /// 总开关。关闭后解析链回到「官方接口 → 你导入的第三方音源」。
    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: PreferredSourceKeys.enabled) }
    }

    /// 网易云歌曲也先用 pyncmd（默认开）。关掉后网易云歌曲仍是「官方优先」的老行为。
    @Published var preferForNetease: Bool {
        didSet { defaults.set(preferForNetease, forKey: PreferredSourceKeys.neteaseFirst) }
    }

    /// 插件音源歌曲先用 pyncmd（默认开）。关掉后插件歌曲直接问插件自己。
    @Published var preferForPlugin: Bool {
        didSet { defaults.set(preferForPlugin, forKey: PreferredSourceKeys.pluginFirst) }
    }

    @Published var quality: PyncmdQuality {
        didSet { defaults.set(quality.rawValue, forKey: PreferredSourceKeys.quality) }
    }

    private let defaults = UserDefaults.standard

    private init() {
        enabled = Self.storedBool(PreferredSourceKeys.enabled, fallback: true)
        preferForNetease = Self.storedBool(PreferredSourceKeys.neteaseFirst, fallback: true)
        preferForPlugin = Self.storedBool(PreferredSourceKeys.pluginFirst, fallback: true)
        let raw = UserDefaults.standard.string(forKey: PreferredSourceKeys.quality)
        quality = raw.flatMap { PyncmdQuality(rawValue: $0) } ?? .best
    }

    /// 没写过这个键时返回 `fallback`。`UserDefaults.bool(forKey:)` 对未设置的键返回 false，
    /// 直接用它会把「默认开启」变成「默认关闭」。
    nonisolated static func storedBool(_ key: String, fallback: Bool) -> Bool {
        (UserDefaults.standard.object(forKey: key) as? Bool) ?? fallback
    }

    /// 非主线程可直接读的开关。
    /// `PlayerManager.externalSourcesEnabled` 是同步热路径，没法 await 到主线程取快照，
    /// 而它必须知道「内置 pyncmd 是否可用」—— 否则一个音源都没导入时会连 pyncmd 一起关掉。
    nonisolated static var isEnabledSync: Bool {
        storedBool(PreferredSourceKeys.enabled, fallback: true)
    }

    var snapshot: PreferredSourceSnapshot {
        PreferredSourceSnapshot(
            enabled: enabled,
            preferForNetease: preferForNetease,
            preferForPlugin: preferForPlugin,
            quality: quality
        )
    }

    /// 供解析链（非主线程）调用。
    nonisolated static func currentSnapshot() async -> PreferredSourceSnapshot {
        await MainActor.run { shared.snapshot }
    }

    /// 一句话描述当前顺位，设置页展示用。
    var prioritySummary: String {
        guard enabled else {
            return beansLocalized(
                "已关闭 —— 仍按原来的顺序解析：官方接口 → 你导入的第三方音源。",
                "Off — resolution keeps the original order: official API, then your imported sources."
            )
        }
        return beansLocalized(
            "解析顺位：pyncmd（按网易云 id 取高音质直链）→ 官方接口 → 你导入的第三方音源 → 插件音源本身。任一顺位拿到地址就立刻播放，不会等后面的。",
            "Order: pyncmd (high-quality direct link by NetEase id) → official API → your imported sources → the plugin itself. The first source that returns a URL wins immediately."
        )
    }
}
