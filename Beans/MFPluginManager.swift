import CryptoKit
import Foundation
import SwiftUI

// MARK: - MusicFree 插件管理器
//
// 负责插件生态的完整生命周期：从 URL / 文件安装、持久化、挂载、搜索、
// 以及解析可播放地址。
//
// 移植自 Aut-B/kumone 的 dev-musicfree 分支，并针对 Beans 做了适配：
// - 插件代码与变量存到 Documents/BeansPlugins（与 Beans 既有的第三方音源目录并列）
// - 去掉对宿主网易云客户端的依赖，播放解析统一走「原生 B 站 → 插件 JS」
// - 预置音源保留了哔哩哔哩、网易云、QQ、酷我、酷狗等常用项，并附带国内镜像

@MainActor
final class MFPluginManager: ObservableObject {
    static let shared = MFPluginManager()

    struct InstalledPlugin: Codable, Identifiable, Hashable {
        var id: String { platform }
        var platform: String
        var name: String
        var version: String?
        var sourceURL: String?
        var enabled: Bool
        var fileName: String
        var hash: String
    }

    struct PresetSource: Identifiable, Hashable {
        let id = UUID()
        let name: String
        /// 候选镜像地址，按顺序尝试，第一个可达的胜出。
        let mirrors: [String]
    }

    /// 为 GitHub 托管的音源补上国内可达的镜像（raw.githubusercontent.com 常被墙）。
    private static func githubMirrors(_ rawURL: String) -> [String] {
        [
            rawURL,
            rawURL.replacingOccurrences(of: "raw.githubusercontent.com/", with: "cdn.jsdelivr.net/gh/")
                .replacingOccurrences(of: "/refs/heads/", with: "@"),
            "https://ghfast.top/" + rawURL,
            "https://gh-proxy.com/" + rawURL,
        ]
    }

    /// 预置音源：用户常用项 + 社区知名插件。
    static let presetSources: [PresetSource] = [
        .init(name: "哔哩哔哩 (zhuguibiao)", mirrors: githubMirrors("https://raw.githubusercontent.com/zhuguibiao/m-plugins/main/bilibili.js")),
        .init(name: "哔哩哔哩 (官方)", mirrors: githubMirrors("https://raw.githubusercontent.com/maotoumao/MusicFreePlugins/master/dist/bilibili/index.js")),
        .init(name: "网易云音乐 (ThomasBy2025)", mirrors: githubMirrors("https://raw.githubusercontent.com/ThomasBy2025/musicfree/refs/heads/main/plugins/wy.js")),
        .init(name: "QQ 音乐 (ThomasBy2025)", mirrors: githubMirrors("https://raw.githubusercontent.com/ThomasBy2025/musicfree/refs/heads/main/plugins/tx.js")),
        .init(name: "酷狗音乐 (ThomasBy2025)", mirrors: githubMirrors("https://raw.githubusercontent.com/ThomasBy2025/musicfree/refs/heads/main/plugins/kg.js")),
        .init(name: "酷我音乐 (ThomasBy2025)", mirrors: githubMirrors("https://raw.githubusercontent.com/ThomasBy2025/musicfree/refs/heads/main/plugins/kw.js")),
        .init(name: "网易云音乐 (元力)", mirrors: ["https://13413.kstore.vip/yuanli/wy.js"]),
        .init(name: "QQ 音乐 (元力)", mirrors: ["https://13413.kstore.vip/yuanli/qq.js"]),
        .init(name: "酷我音乐 (元力)", mirrors: ["https://13413.kstore.vip/yuanli/kw.js"]),
        .init(name: "歌词千寻", mirrors: ["https://gitee.com/maotoumao/MusicFreePlugins/raw/v0.1/dist/geciqianxun/index.js"]),
        .init(name: "网易云电台", mirrors: ["https://fastly.jsdelivr.net/gh/GuGuMur/MusicFreePlugin-NeteaseRadio@master/dist/plugin.js"]),
    ]

    @Published private(set) var plugins: [InstalledPlugin] = []
    @Published var lastError: String?
    @Published private(set) var isInstalling = false

    private let engine = MFPluginEngine.shared

    // MARK: - 存储

    private var baseDirectory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BeansPlugins", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var registryURL: URL { baseDirectory.appendingPathComponent("plugins.json") }

    private var variablesDirectory: URL {
        let dir = baseDirectory.appendingPathComponent("Variables", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private init() {
        engine.setVariablesDirectory(variablesDirectory)
        loadRegistry()
    }

    private func loadRegistry() {
        guard let data = try? Data(contentsOf: registryURL),
              let list = try? JSONDecoder().decode([InstalledPlugin].self, from: data) else { return }
        plugins = list
        Task { await mountEnabled() }
    }

    private func persistRegistry() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(plugins) {
            try? data.write(to: registryURL, options: .atomic)
        }
    }

    func mountEnabled() async {
        for plugin in plugins where plugin.enabled {
            let codeURL = baseDirectory.appendingPathComponent(plugin.fileName)
            guard let code = try? String(contentsOf: codeURL, encoding: .utf8) else { continue }
            do {
                _ = try await engine.mount(code: code, installName: plugin.name)
            } catch {
                BeansLogger.shared.log("插件挂载失败：\(plugin.platform)｜\(error.localizedDescription)", level: .warn)
            }
        }
    }

    /// 已启用插件的平台名列表（供搜索页选择音源）。
    var enabledPlatforms: [String] {
        plugins.filter(\.enabled).map(\.platform)
    }

    // MARK: - 安装 / 删除 / 启停

    @discardableResult
    func install(from urlString: String) async throws -> InstalledPlugin {
        try await install(fromMirrors: [urlString])
    }

    /// 依次尝试各镜像地址，第一个成功的胜出。
    @discardableResult
    func install(fromMirrors mirrors: [String]) async throws -> InstalledPlugin {
        guard !mirrors.isEmpty else {
            throw MFPluginEngineError.script(beansLocalized("无效的插件地址", "Invalid plugin URL"))
        }
        isInstalling = true
        defer { isInstalling = false }

        var lastError: Error = MFPluginEngineError.script(beansLocalized("插件下载失败", "Plugin download failed"))
        var failedCount = 0
        for urlString in mirrors {
            guard let url = URL(string: urlString), url.scheme != nil else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 12
            request.setValue("MusicFree", forHTTPHeaderField: "User-Agent")
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                guard statusCode == 200,
                      let code = String(data: data, encoding: .utf8), code.count > 100 else {
                    lastError = MFPluginEngineError.script(
                        beansLocalized("下载失败（HTTP \(statusCode)）：\(url.host ?? urlString)",
                                       "Download failed (HTTP \(statusCode)): \(url.host ?? urlString)"))
                    failedCount += 1
                    continue
                }
                let installed = try await finishInstall(code: code, sourceURL: urlString, fallbackName: url.lastPathComponent)
                self.lastError = nil
                return installed
            } catch {
                lastError = error
                failedCount += 1
            }
        }
        let detail = failedCount > 1 ? beansLocalized("（已尝试 \(failedCount) 个下载地址）", " (tried \(failedCount) mirrors)") : ""
        throw MFPluginEngineError.script("\(lastError.localizedDescription)\(detail)")
    }

    /// 直接以代码安装（例如从 MusicFree 备份文件导入）。
    @discardableResult
    func installFromCode(_ code: String, sourceName: String) async throws -> InstalledPlugin {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 100 else {
            throw MFPluginEngineError.script(beansLocalized("插件代码无效", "Invalid plugin code"))
        }
        let installed = try await finishInstall(code: trimmed, sourceURL: sourceName, fallbackName: sourceName)
        lastError = nil
        return installed
    }

    private func finishInstall(code: String, sourceURL: String, fallbackName: String) async throws -> InstalledPlugin {
        // 先挂载以校验代码并取得其声明的 platform
        let mount = try await engine.mount(code: code, installName: fallbackName)
        let hash = sha256(code)

        let fileName = mount.platform + ".js"
        try code.write(to: baseDirectory.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
        initializeVariables(mount.userVariables, platform: mount.platform)

        let installed = InstalledPlugin(
            platform: mount.platform,
            name: mount.platform,
            version: nil,
            sourceURL: sourceURL,
            enabled: true,
            fileName: fileName,
            hash: hash
        )
        plugins.removeAll { $0.platform == mount.platform }
        plugins.append(installed)
        persistRegistry()
        BeansLogger.shared.log("插件安装成功：\(mount.platform)", level: .info)
        return installed
    }

    func remove(_ plugin: InstalledPlugin) {
        plugins.removeAll { $0.platform == plugin.platform }
        persistRegistry()
        try? FileManager.default.removeItem(at: baseDirectory.appendingPathComponent(plugin.fileName))
        try? FileManager.default.removeItem(at: variablesDirectory.appendingPathComponent(plugin.platform + ".json"))
    }

    func setEnabled(_ enabled: Bool, for plugin: InstalledPlugin) {
        guard let index = plugins.firstIndex(where: { $0.platform == plugin.platform }) else { return }
        plugins[index].enabled = enabled
        persistRegistry()
        if enabled {
            Task {
                let codeURL = baseDirectory.appendingPathComponent(plugin.fileName)
                guard let code = try? String(contentsOf: codeURL, encoding: .utf8) else { return }
                _ = try? await engine.mount(code: code, installName: plugin.name)
            }
        }
    }

    private func initializeVariables(_ declarations: [[String: Any]], platform: String) {
        var variables = [String: Any]()
        for declaration in declarations {
            guard let key = declaration["key"] as? String else { continue }
            if let current = storedVariables(platform: platform)[key] {
                variables[key] = current
            } else if let defaultValue = declaration["defaultValue"] {
                variables[key] = defaultValue
            }
        }
        guard !variables.isEmpty else { return }
        if let data = try? JSONSerialization.data(withJSONObject: variables, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: variablesDirectory.appendingPathComponent(platform + ".json"), options: .atomic)
        }
    }

    private func storedVariables(platform: String) -> [String: Any] {
        let url = variablesDirectory.appendingPathComponent(platform + ".json")
        guard let data = try? Data(contentsOf: url),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return [:]
        }
        return object
    }

    private func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 搜索与播放解析

    /// 搜索单个插件。`page` 从 1 开始。
    func search(platform: String, query: String, page: Int) async throws -> (isEnd: Bool, items: [MFPluginMusicItem]) {
        let value = try await engine.call(platform: platform, method: "search", args: [query, page, "music"])
        guard let result = value as? [String: Any] else {
            throw MFPluginEngineError.script(beansLocalized("搜索返回格式异常", "Unexpected search result"))
        }
        let isEnd = result["isEnd"] as? Bool ?? true
        let rawItems = result["data"] as? [[String: Any]] ?? []
        let items = rawItems.compactMap { MFPluginMusicItem(normalizing: $0, platform: platform) }
        return (isEnd, items)
    }

    /// 解析可播放地址（可带请求头）。
    ///
    /// 顺序：原生 B 站 → 插件 JS。
    /// B 站先走原生是因为 `view → cid → playurl → dash.audio` 这条链路稳定可控，
    /// 且部分 B 站插件只实现了搜索、没有可靠的取流实现。
    func getMediaSource(platform: String, item: MFPluginMusicItem, quality: String) async -> MFPluginMediaSource {
        guard let itemData = item.rawJSON.data(using: .utf8),
              let itemObject = (try? JSONSerialization.jsonObject(with: itemData)) as? [String: Any] else {
            return .empty
        }
        // B 站：优先原生解析。旧歌单可能没有 bvid，BV 号就是条目 id。
        let bvid = (itemObject["bvid"] as? String)
            ?? ((itemObject["id"] as? String).flatMap { $0.hasPrefix("BV") ? $0 : nil })
        if let bvid {
            let native = await Self.nativeBilibiliMediaURL(bvid: bvid)
            if let nativeURL = native.url {
                return MFPluginMediaSource(url: nativeURL, headers: native.headers)
            }
        }
        // 其它平台：只问该条目所属的插件本身（跨插件兜底会出现“串味”播错歌）
        guard let value = try? await engine.call(
            platform: platform, method: "getMediaSource", args: [itemObject, quality], timeout: 15
        ), let dict = value as? [String: Any] else {
            return .empty
        }
        var url: URL?
        if let urlString = dict["url"] as? String, !urlString.isEmpty {
            url = URL(string: urlString.replacingOccurrences(of: "http://", with: "https://"))
        }
        let headers = (dict["headers"] as? [String: Any])?.reduce(into: [String: String]()) { result, pair in
            if let value = pair.value as? String { result[pair.key] = value }
        }
        return MFPluginMediaSource(url: url, headers: headers)
    }

    /// BV 号精确解析：查询本身就是 BV 号时，直接走 view 接口，
    /// 保证结果命中目标视频，而不是拿 BV 号当关键词去搜索。
    func resolveBilibiliBV(_ query: String, platform: String) async -> MFPluginMusicItem? {
        guard query.range(of: "^BV[0-9A-Za-z]{10}$", options: .regularExpression) != nil,
              platform.lowercased().contains("bili") else { return nil }
        guard let url = URL(string: "https://api.bilibili.com/x/web-interface/view?bvid=\(query)") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let detail = json["data"] as? [String: Any] else { return nil }
        let title = (detail["title"] as? String) ?? query
        let owner = ((detail["owner"] as? [String: Any])?["name"] as? String) ?? "哔哩哔哩"
        let pic = detail["pic"] as? String
        let durationSeconds = (detail["duration"] as? NSNumber)?.intValue ?? 0
        var itemDict: [String: Any] = [
            "id": query,
            "platform": platform,
            "bvid": query,
            "title": title,
            "artist": owner,
            "album": "哔哩哔哩",
            "duration": Double(durationSeconds),
        ]
        if let pic { itemDict["artwork"] = pic }
        return MFPluginMusicItem(normalizing: itemDict, platform: platform)
    }

    static let browserUserAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/89.0.4389.90 Safari/537.36"

    /// B 站原生解析：view → cid → playurl → 第一条音频流。
    /// 返回的请求头必须一并交给播放器，否则 B 站 CDN 会 403。
    static func nativeBilibiliMediaURL(bvid: String) async -> (url: URL?, headers: [String: String]?) {
        let browserHeaders = [
            "User-Agent": browserUserAgent,
            "Referer": "https://www.bilibili.com/",
        ]
        guard let viewURL = URL(string: "https://api.bilibili.com/x/web-interface/view?bvid=\(bvid)") else {
            return (nil, nil)
        }
        var viewRequest = URLRequest(url: viewURL)
        viewRequest.timeoutInterval = 10
        browserHeaders.forEach { viewRequest.setValue($0.value, forHTTPHeaderField: $0.key) }
        guard let (viewData, _) = try? await URLSession.shared.data(for: viewRequest),
              let viewJSON = (try? JSONSerialization.jsonObject(with: viewData)) as? [String: Any],
              let detail = viewJSON["data"] as? [String: Any],
              let cid = (detail["cid"] as? NSNumber)?.stringValue ?? detail["cid"] as? String else {
            return (nil, nil)
        }
        guard let playURL = URL(string: "https://api.bilibili.com/x/player/playurl?bvid=\(bvid)&cid=\(cid)&fnval=16&platform=html5") else {
            return (nil, nil)
        }
        var playRequest = URLRequest(url: playURL)
        playRequest.timeoutInterval = 10
        browserHeaders.forEach { playRequest.setValue($0.value, forHTTPHeaderField: $0.key) }
        guard let (playData, _) = try? await URLSession.shared.data(for: playRequest),
              let playJSON = (try? JSONSerialization.jsonObject(with: playData)) as? [String: Any],
              let data = playJSON["data"] as? [String: Any] else {
            return (nil, nil)
        }
        // 优先 DASH 音频（音质最好），退回 durl
        var urlString: String?
        if let dash = data["dash"] as? [String: Any],
           let audios = dash["audio"] as? [[String: Any]],
           let first = audios.first,
           let baseUrl = first["baseUrl"] as? String {
            urlString = baseUrl
        }
        if urlString == nil, let durl = data["durl"] as? [[String: Any]], let first = durl.first {
            urlString = first["url"] as? String
        }
        guard let urlString, !urlString.isEmpty,
              let url = URL(string: urlString.replacingOccurrences(of: "http://", with: "https://")) else {
            return (nil, nil)
        }
        return (url, browserHeaders)
    }

    // MARK: - 榜单 / 歌单

    /// 插件榜单（MusicFree 的 `getTopLists`）。
    /// 插件未实现该方法时 `call` 会抛错，界面据此把榜单入口隐藏掉。
    func topLists(platform: String) async throws -> [MFPluginTopGroup] {
        let value = try await engine.call(platform: platform, method: "getTopLists", args: [], timeout: 20)
        guard let groups = value as? [[String: Any]] else {
            throw MFPluginEngineError.script(beansLocalized("该音源没有提供榜单", "This source provides no charts"))
        }
        return groups.enumerated().compactMap { index, group in
            let title = (group["title"] as? String) ?? beansLocalized("榜单", "Chart")
            let rawItems = group["data"] as? [[String: Any]] ?? []
            let items = rawItems.compactMap { Self.sheetItem(normalizing: $0, platform: platform) }
            guard !items.isEmpty else { return nil }
            return MFPluginTopGroup(id: "\(platform)|group-\(index)", title: title, items: items)
        }
    }

    /// 榜单 / 歌单详情（`getTopListDetail`），展开成可播放曲目。
    /// `page` 从 1 开始；不支持分页的插件会忽略它。
    func sheetDetail(platform: String, sheet: MFPluginSheetItem, page: Int) async throws -> (isEnd: Bool, items: [MFPluginMusicItem]) {
        guard let data = sheet.rawJSON.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw MFPluginEngineError.script(beansLocalized("歌单数据异常", "Corrupted sheet data"))
        }
        let value = try await engine.call(
            platform: platform, method: "getTopListDetail", args: [object, page], timeout: 25
        )
        guard let dict = value as? [String: Any] else {
            throw MFPluginEngineError.script(beansLocalized("歌单返回格式异常", "Unexpected sheet result"))
        }
        let rawItems = (dict["musicList"] as? [[String: Any]])
            ?? (dict["data"] as? [[String: Any]])
            ?? []
        let items = rawItems.compactMap { MFPluginMusicItem(normalizing: $0, platform: platform) }
        // 有些插件只回一页全部数据，不给 isEnd；items 为空时直接视为到底。
        let isEnd = (dict["isEnd"] as? Bool) ?? items.isEmpty
        return (isEnd, items)
    }

    /// 插件评论。
    ///
    /// MusicFree 协议里的评论方法是 `getMusicComments(musicItem)`，返回
    /// `{ isEnd, data: [{ id, nickName, avatar, comment, like, createAt }] }`。
    /// 实现了它的音源（哔哩哔哩、部分 wy/qq 插件）都能直接用，
    /// **插件没实现时返回 nil**（而不是抛错），调用方据此回退到 App 内置的原生解析。
    func pluginMusicComments(platform: String, item: MFPluginMusicItem, page: Int) async throws -> (comments: [SongComment], isEnd: Bool)? {
        guard let itemData = item.rawJSON.data(using: .utf8),
              let itemObject = (try? JSONSerialization.jsonObject(with: itemData)) as? [String: Any] else {
            return nil
        }
        var value: Any?
        do {
            value = try await engine.call(
                platform: platform, method: "getMusicComments", args: [itemObject, page], timeout: 20
            )
        } catch MFPluginEngineError.script(let message) {
            // 插件没实现这个方法，交给调用方回退到原生解析；其它脚本错误照常上抛。
            guard message.contains("method not implemented") else {
                throw MFPluginEngineError.script(message)
            }
            return nil
        } catch {
            throw error
        }
        guard let dict = value as? [String: Any] else { return nil }
        let rawItems = (dict["data"] as? [[String: Any]]) ?? (dict["comments"] as? [[String: Any]]) ?? []
        let comments = rawItems.enumerated().compactMap { index, raw in
            Self.songComment(normalizing: raw, fallbackKey: "\(platform)|\(item.itemID)|\(page)|\(index)")
        }
        // 多数插件只给一页，不给 isEnd，这时按"到底了"处理。
        let isEnd = (dict["isEnd"] as? Bool) ?? true
        return (comments, isEnd)
    }

    /// 把 MusicFree 的评论条目换成 App 的 `SongComment`。
    /// 字段名在协议里是 nickName / comment / like / createAt（毫秒时间戳），
    /// 但有的插件会写成 nickname / content，两种都认。
    private static func songComment(normalizing dict: [String: Any], fallbackKey: String) -> SongComment? {
        let content = (dict["comment"] as? String) ?? (dict["content"] as? String) ?? ""
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let id = (dict["id"] as? NSNumber)?.intValue
            ?? (dict["id"] as? String).flatMap { Int($0) }
            ?? Song.syntheticPluginID(fallbackKey)
        var avatar = (dict["avatar"] as? String) ?? (dict["avatarUrl"] as? String) ?? ""
        if avatar.hasPrefix("//") { avatar = "https:" + avatar }
        let stamp = (dict["createAt"] as? NSNumber)?.doubleValue
            ?? (dict["ctime"] as? NSNumber)?.doubleValue
            ?? 0
        let likes = (dict["like"] as? NSNumber)?.intValue
            ?? (dict["likedCount"] as? NSNumber)?.intValue
            ?? 0
        return SongComment(
            id: id,
            content: content,
            nickname: (dict["nickName"] as? String) ?? (dict["nickname"] as? String) ?? "",
            avatarURL: URL(string: avatar),
            // 协议给的是毫秒，老接口给的是秒，超过 100 亿按毫秒折算
            time: Date(timeIntervalSince1970: stamp > 10_000_000_000 ? stamp / 1000 : stamp),
            likedCount: likes,
            isHot: likes >= 100
        )
    }

    private static func sheetItem(normalizing dict: [String: Any], platform: String) -> MFPluginSheetItem? {
        let sheetID = (dict["id"] as? String) ?? (dict["id"] as? NSNumber)?.stringValue
        guard let sheetID, !sheetID.isEmpty else { return nil }
        let cover = (dict["coverImg"] as? String)
            ?? (dict["artwork"] as? String)
            ?? (dict["cover"] as? String)
            ?? (dict["picUrl"] as? String)
        let detail = (dict["description"] as? String)
            ?? (dict["artist"] as? String)
            ?? (dict["playCount"] as? NSNumber)?.stringValue
            ?? ""
        let rawJSON = (try? JSONSerialization.data(withJSONObject: dict)).flatMap {
            String(data: $0, encoding: .utf8)
        } ?? "{}"
        return MFPluginSheetItem(
            id: "\(platform)|\(sheetID)",
            platform: platform,
            sheetID: sheetID,
            title: (dict["title"] as? String) ?? (dict["name"] as? String) ?? sheetID,
            cover: cover.flatMap { URL(string: $0) },
            detail: detail,
            rawJSON: rawJSON
        )
    }
}
