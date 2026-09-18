import SwiftUI

/// 首选音源（pyncmd）设置面板。
///
/// 这里管的是**解析顺位**：一首歌要播放时，先去哪里换可播放地址。
/// pyncmd 是内置的（不用导入、不用填 Key），默认排第一，
/// 拿不到地址才继续往下走到官方接口、你导入的第三方音源、以及插件音源本身。
struct PreferredSourceSettingsView: View {
    @ObservedObject private var store = PreferredSourceStore.shared
    @ObservedObject private var sourceStore = UnblockSourceStore.shared
    @ObservedObject private var pluginManager = MFPluginManager.shared
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let _ = theme.accent
        BeansNavigationStack {
            List {
                statusSection
                switchSection
                qualitySection
                prioritySection
            }
            .navigationTitle("首选音源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .modifier(BeansSheetModifier(detents: [.large], dragIndicator: true))
    }

    // MARK: - 总开关

    @ViewBuilder
    private var statusSection: some View {
        Section {
            Toggle(isOn: $store.enabled) {
                HStack(spacing: 12) {
                    Image(systemName: "bolt.horizontal.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(store.enabled ? Color.beansAmber : Color.beansComment)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("pyncmd 高音质音源")
                            .font(BeansFont.appFont(15, .medium))
                            .foregroundStyle(Color.beansLabel)
                        Text(statusText)
                            .font(BeansFont.appFont(11))
                            .foregroundStyle(store.enabled ? Color.beansSage : Color.beansComment)
                    }
                }
            }
            .toggleStyle(.switch)
            .tint(Color.beansAmber)
        } footer: {
            Text("pyncmd 是 App 自带的直链音源，不用导入、不用填密钥。它按网易云歌曲 id 取原站直链，最高能拿到无损（实测约 800 kbps），单次请求通常 1 秒内返回。拿不到地址时会自动继续往下顺位，不会卡住播放。")
                .font(BeansFont.appFont(11))
        }
    }

    /// 单独抽成 `String` 属性：三元式里两个字符串字面量会让 `Text` 的两个重载撞车。
    private var statusText: String {
        store.enabled
            ? "已启用，排在第 1 顺位"
            : "已关闭"
    }

    // MARK: - 生效范围

    @ViewBuilder
    private var switchSection: some View {
        Section {
            Toggle(isOn: $store.preferForNetease) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("网易云歌曲也优先用它")
                        .font(BeansFont.appFont(15))
                        .foregroundStyle(Color.beansLabel)
                    Text("关闭后网易云歌曲仍是「官方接口优先」，官方给不出来时才用 pyncmd")
                        .font(BeansFont.appFont(11))
                        .foregroundStyle(Color.beansComment)
                }
            }
            .toggleStyle(.switch)
            .tint(Color.beansAmber)
            .disabled(!store.enabled)

            Toggle(isOn: $store.preferForPlugin) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("插件音源歌曲也优先用它")
                        .font(BeansFont.appFont(15))
                        .foregroundStyle(Color.beansLabel)
                    Text("按歌名 + 歌手 + 时长三者都吻合才认，认不出就退回插件自己解析")
                        .font(BeansFont.appFont(11))
                        .foregroundStyle(Color.beansComment)
                }
            }
            .toggleStyle(.switch)
            .tint(Color.beansAmber)
            .disabled(!store.enabled)
        } header: {
            Text("生效范围")
        } footer: {
            Text("插件音源的歌（比如哔哩哔哩、第三方网易云插件）原本只问插件自己，音质和速度由插件决定。打开后先用 pyncmd 试一次，命中就换成高音质直链 —— 这也是解决「插件只给 320k 且解析慢」的主要办法。")
                .font(BeansFont.appFont(11))
        }
    }

    // MARK: - 音质

    @ViewBuilder
    private var qualitySection: some View {
        Section {
            ForEach(PyncmdQuality.allCases) { option in
                Button {
                    store.quality = option
                    BeansHaptics.tap()
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(option.displayName)
                                .font(BeansFont.appFont(15))
                                .foregroundStyle(Color.beansLabel)
                            Text(option.detail)
                                .font(BeansFont.appFont(11))
                                .foregroundStyle(Color.beansComment)
                        }
                        Spacer()
                        if store.quality == option {
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.beansAmber)
                        }
                    }
                }
                .disabled(!store.enabled)
            }
        } header: {
            Text("pyncmd 音质")
        } footer: {
            Text("选「最高音质」时服务端会按实际可用音质返回，多数情况是无损；拿不到无损会自动降档，不会因为没有无损就播放失败。")
                .font(BeansFont.appFont(11))
        }
    }

    // MARK: - 顺位说明

    @ViewBuilder
    private var prioritySection: some View {
        Section {
            Text(store.prioritySummary)
                .font(BeansFont.appFont(12))
                .foregroundStyle(Color.beansComment)
        } header: {
            Text("当前解析顺位")
        }

        Section {
            HStack {
                Text("你导入的第三方音源")
                    .font(BeansFont.appFont(14))
                    .foregroundStyle(Color.beansLabel)
                Spacer()
                Text("\(sourceStore.managementVisibleSources.count) 个")
                    .font(BeansFont.appFont(12))
                    .foregroundStyle(Color.beansComment)
            }
            HStack {
                Text("已启用的插件音源")
                    .font(BeansFont.appFont(14))
                    .foregroundStyle(Color.beansLabel)
                Spacer()
                Text("\(pluginManager.enabledPlatforms.count) 个")
                    .font(BeansFont.appFont(12))
                    .foregroundStyle(Color.beansComment)
            }
        } header: {
            Text("后面的顺位")
        } footer: {
            Text("第三方音源之间是并发抢答 —— 谁的地址先回来就用谁，避免某一个慢源把播放拖住。想调整它们内部的前后顺序，去「设置 → 管理 / 导入音源」上下移动。")
                .font(BeansFont.appFont(11))
        }
    }
}
