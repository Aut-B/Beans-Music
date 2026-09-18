import Foundation
import SwiftUI
import UIKit

// MARK: - WebDAV 配置

struct WebDAVConfig: Codable, Equatable {
    var server: String = ""
    var username: String = ""
    var password: String = ""
    /// 云端目录名（相对于服务器根路径）。
    var folder: String = "Beans"

    var trimmedServer: String {
        var value = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.hasSuffix("/") { value += "/" }
        return value
    }

    var isComplete: Bool {
        !server.trimmingCharacters(in: .whitespaces).isEmpty && !username.isEmpty && !password.isEmpty
    }

    func authorizationHeader() -> String? {
        guard !username.isEmpty || !password.isEmpty else { return nil }
        let raw = "\(username):\(password)"
        return "Basic \(Data(raw.utf8).base64EncodedString())"
    }

    var folderURLString: String {
        let folder = folder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !folder.isEmpty else { return trimmedServer }
        return trimmedServer + folder + "/"
    }
}

enum WebDAVError: LocalizedError {
    case incomplete
    case badServer
    case unauthorized
    case serverError(Int)
    case notFound
    case malformed

    var errorDescription: String? {
        switch self {
        case .incomplete: return beansLocalized("请先填写完整的 WebDAV 地址与账号", "Fill in the WebDAV address and account first")
        case .badServer: return beansLocalized("WebDAV 地址无效", "Invalid WebDAV address")
        case .unauthorized: return beansLocalized("WebDAV 账号或密码错误", "Wrong WebDAV account or password")
        case .serverError(let code): return beansLocalized("服务器返回 HTTP \(code)", "Server returned HTTP \(code)")
        case .notFound: return beansLocalized("云端还没有这份文件", "No such file in the cloud yet")
        case .malformed: return beansLocalized("云端文件格式无法识别", "Unrecognised cloud file format")
        }
    }
}

// MARK: - WebDAV 客户端

struct WebDAVEntry: Identifiable, Hashable {
    var id: String { urlString }
    let name: String
    let urlString: String
    let isDirectory: Bool
    let size: Int?
}

enum WebDAVClient {
    static func robustURL(_ string: String) -> URL? {
        if let url = URL(string: string), url.scheme != nil { return url }
        if let url = URLComponents(string: string)?.url, url.scheme != nil { return url }
        return URL(string: string.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? string)
    }

    private static func request(_ urlString: String, config: WebDAVConfig, method: String) throws -> URLRequest {
        guard let url = robustURL(urlString) else { throw WebDAVError.badServer }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 25
        if let auth = config.authorizationHeader() {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// 只做一次轻量 PROPFIND，用于「测试连接」。
    static func testConnection(_ config: WebDAVConfig) async throws {
        _ = try await list(config.folderURLString, config: config)
    }

    static func list(_ urlString: String, config: WebDAVConfig) async throws -> [WebDAVEntry] {
        var request = try request(urlString, config: config, method: "PROPFIND")
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = """
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:">
          <d:prop>
            <d:resourcetype/>
            <d:displayname/>
            <d:getcontentlength/>
          </d:prop>
        </d:propfind>
        """.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WebDAVError.malformed }
        if http.statusCode == 401 || http.statusCode == 403 { throw WebDAVError.unauthorized }
        if http.statusCode == 404 { throw WebDAVError.notFound }
        guard http.statusCode == 207 else { throw WebDAVError.serverError(http.statusCode) }
        guard let xml = String(data: data, encoding: .utf8) else { throw WebDAVError.malformed }

        var entries: [WebDAVEntry] = []
        let parser = WebDAVListParser()
        parser.parse(xml) { entry in
            if entry.urlString == urlString { return }
            entries.append(entry)
        }
        let base = robustURL(urlString)
        let resolved = entries.map { entry -> WebDAVEntry in
            if let existing = robustURL(entry.urlString), existing.scheme != nil { return entry }
            var components = base.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: true) }
            let href = entry.urlString
            if href.hasPrefix("/") {
                components?.path = href
            } else if let basePath = components?.path {
                components?.path = basePath.hasSuffix("/") ? basePath + href : basePath + "/" + href
            }
            components?.query = nil
            components?.fragment = nil
            return WebDAVEntry(
                name: entry.name,
                urlString: components?.string ?? ((base?.absoluteString ?? "") + href),
                isDirectory: entry.isDirectory,
                size: entry.size
            )
        }
        return resolved.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    static func download(_ urlString: String, config: WebDAVConfig) async throws -> Data {
        let request = try request(urlString, config: config, method: "GET")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WebDAVError.malformed }
        if http.statusCode == 401 || http.statusCode == 403 { throw WebDAVError.unauthorized }
        if http.statusCode == 404 { throw WebDAVError.notFound }
        guard (200..<300).contains(http.statusCode) else { throw WebDAVError.serverError(http.statusCode) }
        return data
    }

    static func upload(_ data: Data, to urlString: String, config: WebDAVConfig) async throws {
        var request = try request(urlString, config: config, method: "PUT")
        request.timeoutInterval = 60
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WebDAVError.malformed }
        if http.statusCode == 401 || http.statusCode == 403 { throw WebDAVError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw WebDAVError.serverError(http.statusCode) }
    }

    /// 建目录。已存在时服务器多返回 405 / 301，一律当作成功。
    static func createFolder(_ config: WebDAVConfig) async {
        guard let request = try? request(config.folderURLString, config: config, method: "MKCOL") else { return }
        _ = try? await URLSession.shared.data(for: request)
    }
}

/// WebDAV multistatus 的最小 SAX 解析。
private final class WebDAVListParser: NSObject, XMLParserDelegate {
    private var currentHref = ""
    private var currentName = ""
    private var isDirectory = false
    private var currentSize: Int?
    private var textBuffer = ""
    private var completion: ((WebDAVEntry) -> Void)?

    func parse(_ xml: String, completion: @escaping (WebDAVEntry) -> Void) {
        self.completion = completion
        guard let data = xml.data(using: .utf8) else { return }
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = true
        parser.parse()
    }

    private func localName(_ qName: String) -> String {
        qName.split(separator: ":").last.map(String.init) ?? qName
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch localName(qName ?? elementName) {
        case "response":
            currentHref = ""; currentName = ""; isDirectory = false; currentSize = nil
        default:
            break
        }
        textBuffer = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        textBuffer += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let trimmed = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch localName(qName ?? elementName) {
        case "href":
            currentHref = trimmed
        case "displayname":
            currentName = trimmed
        case "collection":
            isDirectory = true
        case "getcontentlength":
            currentSize = Int(trimmed)
        case "response":
            guard !currentHref.isEmpty else { return }
            let name = currentName.isEmpty
                ? (currentHref as NSString).lastPathComponent.removingPercentEncoding ?? currentHref
                : currentName
            completion?(WebDAVEntry(name: name, urlString: currentHref, isDirectory: isDirectory, size: currentSize))
        default:
            break
        }
    }
}

// MARK: - 本机歌单的云端快照

struct LocalLibraryPayload: Codable {
    var schema: Int = 1
    var app: String = "Beans Music"
    var updatedAt: Date = Date()
    var device: String = ""
    var playlists: [LocalPlaylist] = []
}

// MARK: - 同步中心

@MainActor
final class WebDAVSyncStore: ObservableObject {
    static let shared = WebDAVSyncStore()

    enum Status: Equatable {
        case idle
        case working(String)
        case success(String, Date)
        case failure(String)

        var isWorking: Bool {
            if case .working = self { return true }
            return false
        }
    }

    private static let configKey = "beans.webdav.config"
    private static let autoSyncKey = "beans.webdav.autoSync"

    @Published var config: WebDAVConfig
    @Published var autoSync: Bool
    @Published private(set) var status: Status = .idle
    @Published private(set) var remoteEntries: [WebDAVEntry] = []

    /// 云端固定文件名：本机歌单快照。
    static let snapshotFileName = "localLibrary.json"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.configKey),
           let decoded = try? JSONDecoder().decode(WebDAVConfig.self, from: data) {
            config = decoded
        } else {
            config = WebDAVConfig()
        }
        autoSync = UserDefaults.standard.bool(forKey: Self.autoSyncKey)
    }

    func saveConfig() {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: Self.configKey)
        }
        UserDefaults.standard.set(autoSync, forKey: Self.autoSyncKey)
    }

    /// 供界面更新状态文字（`status` 对外只读）。
    func setStatus(_ newValue: Status) {
        status = newValue
    }

    var snapshotURLString: String {
        config.folderURLString + Self.snapshotFileName
    }

    // MARK: - 连接

    func testConnection() async {
        guard config.isComplete else {
            status = .failure(WebDAVError.incomplete.localizedDescription)
            return
        }
        status = .working(beansLocalized("正在连接…", "Connecting…"))
        await WebDAVClient.createFolder(config)
        do {
            let entries = try await WebDAVClient.list(config.folderURLString, config: config)
            remoteEntries = entries
            status = .success(beansLocalized("连接成功，目录里有 \(entries.count) 项", "Connected — \(entries.count) items in the folder"), Date())
        } catch {
            remoteEntries = []
            status = .failure(error.localizedDescription)
        }
    }

    func refreshRemoteList() async {
        guard config.isComplete else { return }
        do {
            remoteEntries = try await WebDAVClient.list(config.folderURLString, config: config)
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    // MARK: - 上传 / 下载

    /// 上传本机歌单快照。返回上传的歌单数。
    @discardableResult
    func upload() async throws -> Int {
        guard config.isComplete else { throw WebDAVError.incomplete }
        let payload = LocalLibraryPayload(
            updatedAt: Date(),
            device: Self.deviceName,
            playlists: LocalLibraryStore.shared.playlists
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        await WebDAVClient.createFolder(config)
        try await WebDAVClient.upload(data, to: snapshotURLString, config: config)
        return payload.playlists.count
    }

    /// 从云端拉取并合并进本机歌单。返回（新增歌单数, 新增歌曲数）。
    @discardableResult
    func downloadAndMerge() async throws -> (playlists: Int, songs: Int) {
        guard config.isComplete else { throw WebDAVError.incomplete }
        let data = try await WebDAVClient.download(snapshotURLString, config: config)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(LocalLibraryPayload.self, from: data) else {
            throw WebDAVError.malformed
        }
        return LocalLibraryStore.shared.merge(payload.playlists)
    }

    /// 用云端快照**替换**本机歌单（危险操作，界面需二次确认）。
    @discardableResult
    func downloadAndReplace() async throws -> Int {
        guard config.isComplete else { throw WebDAVError.incomplete }
        let data = try await WebDAVClient.download(snapshotURLString, config: config)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(LocalLibraryPayload.self, from: data) else {
            throw WebDAVError.malformed
        }
        LocalLibraryStore.shared.replaceAll(payload.playlists)
        return payload.playlists.count
    }

    /// 下载云端任意 MusicFree 备份 / 歌单 JSON 并导入本机歌单。
    @discardableResult
    func importRemoteFile(_ entry: WebDAVEntry) async throws -> (playlists: Int, songs: Int) {
        guard config.isComplete else { throw WebDAVError.incomplete }
        let data = try await WebDAVClient.download(entry.urlString, config: config)
        let imported = MusicFreeBackupImporter.parse(data)
        guard !imported.isEmpty else { throw WebDAVError.malformed }
        return LocalLibraryStore.shared.merge(imported)
    }

    private static var deviceName: String {
        #if targetEnvironment(simulator)
        return "Simulator"
        #else
        return UIDevice.current.name
        #endif
    }
}

// MARK: - MusicFree 备份 / 歌单 JSON 导入
//
// MusicFree 的备份文件在不同版本间字段名有出入（playlists / musicSheets /
// sheets，musicList / songs / items …），这里不去猜具体版本，而是**递归扫描**整棵
// JSON，把"看着像歌单"的节点收集出来，兼容性最好。

enum MusicFreeBackupImporter {
    private static let playlistKeys = ["playlists", "musicSheets", "sheets", "sheetList", "歌单"]
    private static let itemListKeys = ["musicList", "musicItems", "songs", "items", "tracks"]
    private static let nameKeys = ["title", "name", "sheetName", "playlistName"]

    static func parse(_ data: Data) -> [LocalPlaylist] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var collected: [LocalPlaylist] = []
        collectSongs(from: root, into: &collected, depth: 0)
        // 去掉没有任何歌曲的残留节点，并按名字去重
        var seen = Set<String>()
        return collected.filter { !$0.songs.isEmpty && seen.insert($0.name).inserted }
    }

    private static func collectSongs(from node: Any, into result: inout [LocalPlaylist], depth: Int) {
        guard depth < 8 else { return }
        if let array = node as? [Any] {
            for element in array {
                collectSongs(from: element, into: &result, depth: depth + 1)
            }
            return
        }
        guard let dict = node as? [String: Any] else { return }

        // 1) 形如 { title: "xxx", musicList: [ ... ] } 的歌单节点
        if let listKey = itemListKeys.first(where: { dict[$0] as? [Any] != nil }),
           let rawItems = dict[listKey] as? [Any] {
            let name = nameKeys.compactMap { dict[$0] as? String }
                .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                ?? "导入的歌单"
            let songs = rawItems.compactMap { song(from: $0) }
            if !songs.isEmpty {
                result.append(LocalPlaylist(name: name, songs: songs))
            }
        }

        // 2) 继续往下钻，兼容 { data: { playlists: [...] } } 之类的包装
        for key in playlistKeys {
            if let child = dict[key] {
                collectSongs(from: child, into: &result, depth: depth + 1)
            }
        }
        for (key, value) in dict where !playlistKeys.contains(key) {
            if value is [Any] || value is [String: Any] {
                collectSongs(from: value, into: &result, depth: depth + 1)
            }
        }
    }

    private static func song(from node: Any) -> Song? {
        guard var dict = node as? [String: Any] else { return nil }
        // MusicFree 条目 id 多为字符串，但备份里可能是数字，统一成字符串。
        if let number = dict["id"] as? NSNumber, dict["id"] as? String == nil {
            dict["id"] = number.stringValue
        }
        guard let itemID = dict["id"] as? String, !itemID.isEmpty else { return nil }
        // 没有 platform 的条目（原生三平台备份）补一个标记，避免播放时路由不到插件。
        let platform = (dict["platform"] as? String) ?? (dict["source"] as? String) ?? ""
        guard !platform.isEmpty else { return nil }
        guard let item = MFPluginMusicItem(normalizing: dict, platform: platform) else { return nil }
        return Song(pluginItem: item)
    }
}
