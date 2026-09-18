import Foundation

/// B 站评论区读取失败的原因。
enum BilibiliCommentsError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): return message
        }
    }
}

/// B 站视频评论。
///
/// 关键点：评论接口的 `oid` 用的是**视频 aid（数字）**，不是 BV 号——
/// 直接把 BV 号当 oid 传进去只会拿到空列表或报错，所以先走 `view` 换 aid。
///
/// 接口是 B 站网页版在用的老接口（`/x/v2/reply`），不需要登录、不需要 wbi 签名，
/// 但要求带 `Referer: https://www.bilibili.com/`，否则会被风控拦掉。
enum BilibiliCommentsAPI {
    /// 单页上限，B 站这个接口给 20 比较稳（写 30 时偶发截断）。
    static let pageSize = 20

    private static var browserHeaders: [String: String] {
        [
            "User-Agent": MFPluginManager.browserUserAgent,
            "Referer": "https://www.bilibili.com/",
        ]
    }

    /// bvid → aid。
    static func aid(for bvid: String) async -> Int? {
        guard let url = URL(string: "https://api.bilibili.com/x/web-interface/view?bvid=\(bvid)") else { return nil }
        guard let json = await get(url),
              let detail = json["data"] as? [String: Any] else { return nil }
        if let number = detail["aid"] as? NSNumber { return number.intValue }
        if let text = detail["aid"] as? String { return Int(text) }
        return nil
    }

    /// 评论列表；`page` 从 1 开始，`sort=2` 表示按热度。
    static func comments(bvid: String, page: Int, limit: Int = pageSize) async throws -> (comments: [SongComment], total: Int) {
        guard let aid = await aid(for: bvid) else {
            throw BilibiliCommentsError.unavailable(
                beansLocalized("找不到这个 B 站视频，可能已失效或设为私密", "This Bilibili video could not be found")
            )
        }
        let size = max(1, min(limit, 49))
        guard let url = URL(string: "https://api.bilibili.com/x/v2/reply?type=1&oid=\(aid)&sort=2&pn=\(max(1, page))&ps=\(size)") else {
            throw BilibiliCommentsError.unavailable(beansLocalized("评论地址无效", "Invalid comment endpoint"))
        }
        guard let json = await get(url) else {
            throw BilibiliCommentsError.unavailable(beansLocalized("B 站评论加载失败，请稍后再试", "Failed to load Bilibili comments, please retry later"))
        }
        let code = (json["code"] as? NSNumber)?.intValue ?? -1
        guard code == 0, let data = json["data"] as? [String: Any] else {
            throw BilibiliCommentsError.unavailable(message(for: code))
        }
        let total = (data["page"] as? [String: Any]).flatMap { ($0["acount"] as? NSNumber)?.intValue } ?? 0
        let replies = data["replies"] as? [[String: Any]] ?? []
        var seen = Set<Int>()
        let comments: [SongComment] = replies.compactMap { reply in
            guard let id = Self.intValue(reply["rpid"]), seen.insert(id).inserted else { return nil }
            let content = (reply["content"] as? [String: Any])?["message"] as? String ?? ""
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let member = reply["member"] as? [String: Any]
            // 头像地址是协议相对的（//i0.hdslb.com/...），必须补上 https
            var avatar = member?["avatar"] as? String ?? ""
            if avatar.hasPrefix("//") { avatar = "https:" + avatar }
            let seconds = (reply["ctime"] as? NSNumber)?.doubleValue ?? 0
            let likes = Self.intValue(reply["like"]) ?? 0
            return SongComment(
                id: id,
                content: content,
                nickname: member?["uname"] as? String ?? beansLocalized("B 站用户", "Bilibili user"),
                avatarURL: URL(string: avatar),
                time: Date(timeIntervalSince1970: seconds),
                likedCount: likes,
                isHot: likes >= 100
            )
        }
        return (comments, total)
    }

    /// 兼容 Int / String / 浮点三种形态（B 站不同接口的 rpid、like 类型不统一）。
    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    private static func message(for code: Int) -> String {
        switch code {
        case -404: return beansLocalized("评论不存在，视频可能已被删除", "Comments not found — the video may have been removed")
        case -412: return beansLocalized("B 站拦截了本次请求，请稍后再试", "Bilibili blocked this request, please retry later")
        case 12061: return beansLocalized("B 站要求登录后才能查看这条评论", "Bilibili requires sign-in to view this comment")
        default: return String(format: beansLocalized("B 站评论加载失败（错误码 %d）", "Failed to load Bilibili comments (code %d)"), code)
        }
    }

    private static func get(_ url: URL) async -> [String: Any]? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        browserHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
