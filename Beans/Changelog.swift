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
            id: "1.14.0",
            version: "1.14.0",
            title: "网易云的歌不再等半天、切歌不跳曲",
            features: [],
            fixes: [
                "网易云的歌不用再等半天了：这些歌的播放地址原先是一档接一档地试（内置音源 → 官方接口 → 官方降档 → 第三方音源），每一档都要等完自己的网络超时，最坏要二十多秒才轮到出声。现在几档同时上路，谁先给出可用地址就立刻播 —— 插件音源（B 站等）上一版已经这么做了，这次补上的是网易云这条主路径",
                "修复「有时候会莫名其妙跳过一首」：上一首自然播完的通知是投递到主线程的，如果那一瞬间你已经手动切了歌，这条迟到的通知会再把队列往前推一首。现在加了一道「确认这条通知说的就是当前这首」的校验",
                "内置音源（pyncmd）的地址缓存从 60 秒延长到 8 分钟：直链本身有效期约 20 分钟，原先的 60 秒短到「上一首播完自动切下一首」时缓存必然已经过期，每首歌都得从头再请求一次",
                "新增「预热下一首」：一首歌播到七成时，后台先把下一首的直链取回来。自动切歌那一刻直接命中缓存，接近零等待"
            ]
        ),
        VersionLog(
            id: "1.13.0",
            version: "1.13.0",
            title: "切歌不再退回上一首、找音源更快",
            features: [],
            fixes: [
                "修复「新歌还在解析地址时按播放键，结果播的还是上一首」：切歌那一刻就把旧播放器作废，播放键回到「重试当前这一首」的语义",
                "解析音源期间按播放键，会提示「正在寻找可用音源…」，不再重复触发一次解析、让等待从头计时",
                "插件歌曲的取址改为两条路径同时进行（匹配网易云换高音质直链 / 交给插件自身解析），谁先给出可用地址就用谁；此前是串行的，最坏情况要等两者耗时相加",
                "网易云搜索与官方取址各加一道时间上限：接口没有及时响应时，不再让整条顺位链跟着干等",
                "在底部标签栏上滑动不再发涩：原先手指滑过哪一格就切哪一页，一次滑动会连续构建两三个页面；现在拖动只做跟手位移，松手才切一次",
                "Tab 切换去掉隐式动画 —— 切换那一帧正是新页面首次构建的峰值，动画压在上面就是掉帧"
            ]
        ),
        VersionLog(
            id: "1.12.0",
            version: "1.12.0",
            title: "本地歌单铺到「我的」、去掉全站实时模糊",
            features: [
                "「我的」页面不再只放一个入口卡片：一键同步歌单、备份、恢复和歌单列表整段直接铺在页面上，滑到就能用，不用再点进二级页面"
            ],
            fixes: [
                "去掉全局卡片、按钮和底部浮岛（标签栏 + 迷你播放器）背后的实时模糊，换成静态玻璃面板 —— 滚动时不再逐帧重算模糊，明显更顺，也更不容易发热",
                "日志写盘改到后台队列：以前每记一条日志都在当前线程上做一串文件系统调用，其中不少来自主线程"
            ]
        ),
        VersionLog(
            id: "1.11.0",
            version: "1.11.0",
            title: "播放失败不再卡住、本地歌单更好找",
            features: [
                "「我的」页面新增「本地歌单」入口，点进去就是本机歌单页，不用再去音乐库滚过整张网易云歌单",
                "「一键同步歌单」旁边新增「备份」「恢复」：把本机歌单导出成一个文件，换设备导入即可回到手上；同名歌曲沿用「跳过 / 替换」策略，不会越导越多"
            ],
            fixes: [
                "修复「切到一首放不出来的歌，再点播放键却退回上一首」：解析失败后把播放器整个释放，播放键的语义回到「重试当前这一首」",
                "修复插件音源顺位走不完的问题：首选音源拿不到地址时，会继续问插件自身、再问第三方音源，全部试过才判失败",
                "播放失败自动跳到下一首的等待从 10 秒缩到 3 秒；连续多首都放不出来时最多跳 8 首就停下并提示，不再无止境往下跳"
            ]
        ),
        VersionLog(
            id: "1.10.0",
            version: "1.10.0",
            title: "流畅度优化、新歌置顶",
            features: [
                "加入本地歌单的歌曲改放到列表最上面（批量添加也保持原有顺序），加完立刻能看到，不用滚到末尾找",
                "封面按显示尺寸解码：列表里只解出缩略图，进播放页才解大图。一屏十几张封面的解码量与内存占用降一个数量级"
            ],
            fixes: [
                "列表行底不再用实时毛玻璃，改为同色系的半透明底：滚动时不再逐行做离屏模糊 —— 这是 iPhone 12 上「一滚就掉帧」的主要来源",
                "背景装饰光晕由半径 100 以上的高斯模糊改成等效的径向渐变，几乎每个页面都在用的这层背景不再做昂贵的离屏渲染",
                "唱片旋转、唱臂摆动、封面自转从「屏幕最高刷新率」限到 30fps，播放页不再持续满载 GPU —— 发热降频才是越用越卡的根因",
                "锁屏封面改为异步加载并只解 600 像素缩略图，同时给封面缓存加上容量上限（原先会把每首歌的原图整张存着）"
            ]
        ),
        VersionLog(
            id: "1.9.1",
            version: "1.9.1",
            title: "WebDAV 导入修复",
            features: [
                "导入设置新增「重复歌曲处理」：跳过（反复导入不再堆重复）或替换（把别的设备上换好音源的条目带回来）；同一首歌按来源标识或「歌名相同 + 时长差 5 秒内」判定",
                "导入云端文件时优先识别 Beans 自己导出的快照格式，完整还原歌手、封面与音源信息"
            ],
            fixes: [
                "修复 WebDAV 导入 Beans 快照后歌曲变成「未知歌手、无封面、无法播放」的问题：之前快照被误当成 MusicFree 备份解析，插件音源的原始信息全部丢失"
            ]
        ),
        VersionLog(
            id: "1.9.0",
            version: "1.9.0",
            title: "首选音源 pyncmd、逐曲换源",
            features: [
                "新增内置音源 pyncmd：按网易云歌曲 id 取原站直链，最高能拿到无损（约 800 kbps），单次请求通常 1 秒内返回；不用导入、不用填密钥",
                "解析顺位改为「pyncmd → 官方接口 → 你导入的第三方音源 → 插件音源本身」，任一顺位拿到地址就立刻播放",
                "插件音源的歌曲也会先试 pyncmd：按歌名 + 歌手 + 时长三者都吻合才认，认不出就退回插件自己解析",
                "设置页新增「首选音源 → 解析顺位设置」：可单独开关 pyncmd、单独开关「网易云歌曲优先」「插件歌曲优先」，并选择 pyncmd 音质档（最高 / 320k / 128k）",
                "本地歌单支持逐曲更换音源：长按歌曲 → 「更换音源」，会在网易云 / QQ / 酷狗 / 各已装插件里按歌名并发匹配，挑一条替换即可，歌单里的位置和顺序不变",
                "换源面板会给对得上的候选打对勾（歌手 + 时长都吻合），避免换成翻唱或 Live 版本"
            ],
            fixes: []
        ),
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
