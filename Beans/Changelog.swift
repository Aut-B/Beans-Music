import SwiftUI

// MARK: - 版本更新日志（设置页与首次更新弹窗使用）

struct VersionLog: Identifiable {
    let id: String
    let version: String
    let title: String
    let notices: [String]
    let features: [String]
    let fixes: [String]
    let imageURL: URL?
    let textColorHex: String?

    init(id: String, version: String, title: String, notices: [String] = [], features: [String], fixes: [String], imageURL: URL? = nil, textColorHex: String? = nil) {
        self.id = id
        self.version = version
        self.title = title
        self.notices = notices
        self.features = features
        self.fixes = fixes
        self.imageURL = imageURL
        self.textColorHex = textColorHex
    }
}

enum ChangelogStore {
    static let lastSeenKey = "beans.lastSeenVersion"

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    static var lastSeenVersion: String {
        UserDefaults.standard.string(forKey: lastSeenKey) ?? ""
    }

    static func markSeen() {
        UserDefaults.standard.set(currentVersion, forKey: lastSeenKey)
        UserDefaults.standard.synchronize()
    }

    static var shouldShowWhatsNew: Bool {
        lastSeenVersion != currentVersion
    }

    static var latest: VersionLog? { logs.first }

    static let logs: [VersionLog] = [
        VersionLog(
            id: "1.8.2",
            version: "1.8.2",
            title: "评论入口提到顶栏",
            features: [
                "播放页右上角新增独立的评论按钮，就在红心左边，一步直达（原来要先点「⋯」再点「查看评论」）",
                "黑胶页、歌曲页、Apple Music 版播放页的顶栏都已同步调整"
            ],
            fixes: []
        ),
        VersionLog(
            id: "1.8.1",
            version: "1.8.1",
            title: "修复网易云歌单加歌、评论入口",
            features: [
                "播放页右上角「⋯」菜单新增「查看评论」，黑胶页与歌曲页都能进"
            ],
            fixes: [
                "修复点「添加到歌单」里的网易云歌单后毫无反应的问题：现在会正常关闭面板并给出成功或失败提示",
                "修复网易云歌单加歌一直没有真正写入的问题，并会显示网易云返回的真实原因",
                "收藏来的网易云歌单现在标明「不能往里加歌」，避免点了必然失败",
                "修复评论页会一直转圈不出的问题"
            ]
        ),
        VersionLog(
            id: "1.8.0",
            version: "1.8.0",
            title: "歌单排序、网易云歌单入库、B 站评论",
            features: [
                "本机歌单支持调整歌曲顺序：歌单详情右上角菜单选「调整歌曲顺序」，拖动右侧手柄即可排序，顺序自动保存",
                "「添加到歌单」合并成一个面板：本机歌单与网易云歌单同屏可选，网易云来源的歌曲可以直接存进自己的网易云歌单",
                "歌曲右键菜单新增「查看评论」",
                "评论按来源分流：网易云、QQ音乐、酷狗音乐各看各的，插件音源（哔哩哔哩）看 B 站视频评论"
            ],
            fixes: [
                "修复插件音源歌曲的评论页会去查网易云评论、显示成不相干内容的问题"
            ]
        ),
        VersionLog(
            id: "1.7.0",
            version: "1.7.0",
            title: "插件音源接入音乐库、歌单 WebDAV 同步",
            features: [
                "音乐库新增「插件音源」入口，与网易云、QQ音乐、酷狗音乐并列，左上角一键切换",
                "支持 MusicFree 插件音源：哔哩哔哩等插件可直接搜歌、看榜单歌单并一键导入本地歌单",
                "本机歌单支持把网易云、QQ音乐、酷狗音乐、插件音源的歌曲混装在一起",
                "新增 WebDAV 同步：本机歌单可上传到自己的 WebDAV 网盘，换机或重装后一键恢复合并",
                "新增封面图片缓存，列表滚动与页面往返不再反复加载封面"
            ],
            fixes: [
                "修复从播放页返回首页后，右下角迷你播放器封面反复闪烁的问题",
                "修复版本号回退导致的「发现新版本」误提示",
                "后台链路默认不再强制拉满刷新率，减少发热与降频掉帧"
            ]
        ),
        VersionLog(
            id: "1.5.8",
            version: "1.5.8",
            title: "歌单同步、主页与播放器全面优化",
            features: [
                "新增网易云音乐、QQ音乐、酷狗音乐歌单一键同步到本地",
                "本地歌单支持编辑和搜索，批量选择歌曲后可添加到其他本地歌单",
                "新增 QQ 音乐热门歌单展示",
                "主页问候语支持自定义文字、颜色、大小、发光、专属字体、底部横线和上下渐变，并可逐行选择渐变颜色",
                "播放器支持左右滑动切换歌曲，新增顶部三平台排序、隐藏主页刷新/用户名/排序按钮",
                "播放器按钮图标样式新增，播放器设置界面重新整理分组和控件排版",
                "主页、音乐库、我的、设置页增加 iPad 最大宽度适配",
                "播放列表、最近播放和日志界面背景同步主页壁纸"
            ],
            fixes: [
                "修复 QQ 音乐喜欢列表不显示的问题",
                "修复最近播放、日志、本地歌单和播放列表不同步主页壁纸的问题",
                "修复设置页掉帧问题；如果本次仍然掉帧，建议更换设备",
                "修复 iOS 15 编译兼容问题"
            ]
        ),
        VersionLog(
            id: "1.5.6",
            version: "1.5.6",
            title: "播放器体验优化",
            features: [
                "封面页歌名、歌手和预览歌词支持渐变、高光及高光强度调节",
                "播放页背景浮尘新增开关，默认关闭；动态浮尘支持密度和大小调节",
                "全局上传壁纸自动同步到播放器封面页背景",
                "播放页支持从顶部下划关闭，并加入缩放、淡出动画"
            ],
            fixes: [
                "修复酷狗排行榜歌曲封面缺失或未归一化的问题",
                "提高内置音源搜索上限",
                "播放器设置打开后不再默认展开播放和歌词显示分组"
            ]
        ),
        VersionLog(
            id: "1.5.5",
            version: "1.5.5",
            title: "播放流畅度与发热优化",
            notices: [
                "从 1.5.4 版本开始，播放器设置已从右上角删除，改为点击中间歌曲正在播放的标题打开。"
            ],
            features: [
                "优化播放中全局刷新策略，移除高刷保持器的常驻空转刷新，降低设置页、我的页面和播放器页面的发热与掉帧",
                "本地壁纸、歌词背景、设置页缩略图改为复用解码缓存，减少滚动和切换设置时的重复图片解码",
                "锁屏/系统正在播放封面增加缓存，避免播放状态变化时反复下载和刷新同一张封面",
                "聆澜内置音源支持多密钥池，当前密钥未命中时自动切换下一个，并记住最近可用密钥",
                "播放器设置新增封面页歌名、歌手、预览歌词与未播放歌词颜色调节"
            ],
            fixes: [
                "修复播放中进度更新过于频繁导致非播放器页面也跟随重绘的问题",
                "修复重新上传歌词背景或恢复壁纸后，部分位置可能继续显示旧图片缓存的问题",
                "修复酷狗排行榜详情歌曲封面链接未归一化，并在官网榜单缺封面时自动用移动端榜单数据补齐封面",
                "优化巨魔安装场景下播放中切换页面的刷新与解码负担"
            ]
        ),
    ]
}

// MARK: - 更新说明弹窗

struct WhatsNewSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        BeansNavigationStack {
            ZStack {
                GlassBackdrop(customColor: ThemeStore.shared.backgroundSyncAll ? ThemeStore.shared.customBackground : nil)
                ScrollView {
                    if let log = ChangelogStore.latest {
                        VersionLogCard(log: log)
                            .padding(16)
                    }
                }
                .beansScrollIndicatorsHidden()
            }
            .navigationTitle("更新说明")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("开始使用") {
                        ChangelogStore.markSeen()
                        dismiss()
                    }
                    .font(BeansFont.appFont(14, .semibold))
                    .foregroundStyle(Color.beansAmber)
                }
            }
        }
        .modifier(BeansSheetModifier(detents: [.medium, .large]))
        .onDisappear {
            ChangelogStore.markSeen()
        }
    }
}

struct ChangelogListView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        BeansNavigationStack {
            ZStack {
                GlassBackdrop(customColor: ThemeStore.shared.backgroundSyncAll ? ThemeStore.shared.customBackground : nil)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(ChangelogStore.logs) { log in
                            VersionLogCard(log: log)
                        }
                    }
                    .padding(16)
                }
                .beansScrollIndicatorsHidden()
            }
            .navigationTitle("更新日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .modifier(BeansSheetModifier(detents: [.medium, .large]))
    }
}

private struct VersionLogCard: View {
    let log: VersionLog

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("v\(log.version)")
                    .font(BeansFont.appFont(16, .bold))
                    .foregroundStyle(Color.beansAmber)
                Text(log.title)
                    .font(BeansFont.appFont(14, .semibold))
                    .foregroundStyle(textColor)
            }
            if let imageURL = log.imageURL {
                AsyncImage(url: imageURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit()
                    } else if phase.error != nil {
                        EmptyView()
                    } else {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 80)
                    }
                }
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            if !log.notices.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(log.notices, id: \.self) { notice in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.top, 1)
                            Text(notice)
                                .font(BeansFont.appFont(13, .semibold))
                                .foregroundStyle(.white)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    LinearGradient(
                        colors: [Color.orange, Color.red.opacity(0.88)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
            }
            if !log.features.isEmpty {
                logSection(title: "新增功能", icon: "plus.circle.fill", items: log.features)
            }
            if !log.fixes.isEmpty {
                Divider().overlay(Color.beansComment.opacity(0.15))
                logSection(title: "问题修复", icon: "checkmark.circle.fill", items: log.fixes)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            BeansGlass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .beansCardShadow(radius: 9, y: 3)
    }

    private func logSection(title: String, icon: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizedStringKey(title))
                .font(BeansFont.appFont(14, .bold))
                .foregroundStyle(Color.beansAmber)
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.beansAmber)
                        .padding(.top, 2)
                    Text(LocalizedStringKey(item))
                        .font(BeansFont.appFont(13))
                        .foregroundStyle(textColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var textColor: Color {
        if let raw = log.textColorHex, let color = Color(hex: raw) { return color }
        return Color.beansLabel
    }
}
