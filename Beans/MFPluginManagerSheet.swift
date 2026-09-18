import SwiftUI
import UIKit

// MARK: - MusicFree 插件音源管理
//
// 与 Beans 既有的「自定义音源」并列：后者是 LX 脚本（只换播放地址），
// 这里是 MusicFree 插件（自带搜索与曲库，例如哔哩哔哩）。

struct MFPluginManagerSheet: View {
    @Environment(\.dismiss) private var dismiss
    // 这三者本身不直接用，仅用于向下层 sheet 透传（嵌套 sheet 不保证继承环境对象）
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var auth: AuthStore
    @ObservedObject private var manager = MFPluginManager.shared

    @State private var importURL = ""
    @State private var message: String?
    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    @State private var installingName: String?
    @State private var showSearch = false

    var body: some View {
        NavigationView {
            ScrollView {
                LazyVStack(spacing: 14) {
                    headerCard
                    installCard
                    presetCard
                    installedCard
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
            }
            .background(GlassBackdrop())
            .navigationTitle(beansLocalized("插件音源", "Plugin Sources"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(beansLocalized("完成", "Done")) { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .sheet(isPresented: $showSearch) {
            MFPluginSearchView()
                .environmentObject(theme)
                .environmentObject(player)
                .environmentObject(auth)
        }
        .alert(beansLocalized("安装失败", "Install Failed"), isPresented: $showErrorAlert) {
            Button(beansLocalized("知道了", "OK"), role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    // MARK: - 头部

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(beansLocalized("MusicFree 插件", "MusicFree Plugins"))
                    .font(BeansFont.appFont(18, .bold))
                    .foregroundStyle(Color.beansLabel)
                Text(beansLocalized(
                    "兼容 MusicFree 的 .js 音源插件。插件自带搜索与曲库，可播放哔哩哔哩等平台的内容。",
                    "Compatible with MusicFree .js plugin sources. Plugins bring their own search and catalog, such as Bilibili."
                ))
                    .font(BeansFont.appFont(12))
                    .foregroundStyle(Color.beansComment)
                Text(beansLocalized(
                    "与上方「自定义音源」互补：自定义音源只补播放地址，插件音源是独立内容源。",
                    "Complements custom sources above: custom sources only fill in playback URLs, while plugins are independent content sources."
                ))
                    .font(BeansFont.appFont(12))
                    .foregroundStyle(Color.beansComment)
            }

            HStack(spacing: 10) {
                Button {
                    BeansHaptics.tap()
                    showSearch = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                        Text(beansLocalized("用插件音源搜歌", "Search with plugins"))
                    }
                    .font(BeansFont.appFont(13, .semibold))
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.black, in: Capsule())
                }
                .buttonStyle(GlassPressButtonStyle(scale: 0.97))
                .disabled(manager.enabledPlatforms.isEmpty)
                .opacity(manager.enabledPlatforms.isEmpty ? 0.45 : 1)

                Text(beansLocalized("\(manager.plugins.count) 个插件", "\(manager.plugins.count) plugins"))
                    .font(BeansFont.appFont(12))
                    .foregroundStyle(Color.beansComment)
            }

            if let message {
                Text(message)
                    .font(BeansFont.appFont(12))
                    .foregroundStyle(Color.beansAmber)
                    .lineLimit(3)
            }
        }
        .padding(16)
        .background {
            BeansGlass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .beansCardShadow(radius: 8, y: 3)
    }

    // MARK: - 从地址安装

    private var installCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(beansLocalized("从地址安装", "Install from URL"))
                .font(BeansFont.appFont(15, .semibold))
                .foregroundStyle(Color.beansLabel)

            TextField(beansLocalized("粘贴 .js 插件地址", "Paste a .js plugin URL"), text: $importURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .font(BeansFont.appFont(14))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background { BeansSurface(shape: RoundedRectangle(cornerRadius: 14, style: .continuous)) }

            Button {
                let target = importURL.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !target.isEmpty else { return }
                install(urls: [target], name: "自定义")
            } label: {
                HStack(spacing: 8) {
                    if manager.isInstalling {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "arrow.down.circle.fill")
                    }
                    Text(manager.isInstalling
                         ? beansLocalized("安装中…", "Installing…")
                         : beansLocalized("安装", "Install"))
                }
                .font(BeansFont.appFont(13, .semibold))
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.black, in: Capsule())
            }
            .buttonStyle(GlassPressButtonStyle(scale: 0.97))
            .disabled(manager.isInstalling || importURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(manager.isInstalling ? 0.6 : 1)

            Text(beansLocalized(
                "支持 MusicFree 插件仓库里的任意 .js 文件。GitHub 地址会自动尝试国内镜像。",
                "Any .js file from a MusicFree plugin repo works. GitHub URLs automatically fall back to mirrors."
            ))
                .font(BeansFont.appFont(11))
                .foregroundStyle(Color.beansComment)
        }
        .padding(16)
        .background {
            BeansGlass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .beansCardShadow(radius: 8, y: 3)
    }

    // MARK: - 预置音源

    private var presetCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(beansLocalized("推荐音源", "Recommended"))
                .font(BeansFont.appFont(15, .semibold))
                .foregroundStyle(Color.beansLabel)

            ForEach(MFPluginManager.presetSources) { preset in
                HStack(spacing: 12) {
                    Image(systemName: "shippingbox.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.beansAmber)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(preset.name)
                            .font(BeansFont.appFont(14))
                            .foregroundStyle(Color.beansLabel)
                        Text(installedHint(for: preset))
                            .font(BeansFont.appFont(11))
                            .foregroundStyle(Color.beansComment)
                            .lineLimit(1)
                    }
                    Spacer()
                    if installingName == preset.name {
                        ProgressView()
                    } else if isInstalled(preset) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 17))
                            .foregroundStyle(Color.beansAmber)
                    } else {
                        Button {
                            install(urls: preset.mirrors, name: preset.name)
                        } label: {
                            Text(beansLocalized("安装", "Install"))
                                .font(BeansFont.appFont(12, .semibold))
                                .foregroundStyle(Color.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(Color.black, in: Capsule())
                        }
                        .buttonStyle(GlassPressButtonStyle(scale: 0.95))
                        .disabled(installingName != nil)
                    }
                }
            }
        }
        .padding(16)
        .background {
            BeansGlass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .beansCardShadow(radius: 8, y: 3)
    }

    // MARK: - 已安装

    private var installedCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(beansLocalized("已安装", "Installed"))
                .font(BeansFont.appFont(15, .semibold))
                .foregroundStyle(Color.beansLabel)

            if manager.plugins.isEmpty {
                Text(beansLocalized("还没有装插件。先从上面挑一个推荐音源吧。", "No plugins yet. Install one from the list above."))
                    .font(BeansFont.appFont(12))
                    .foregroundStyle(Color.beansComment)
            } else {
                ForEach(manager.plugins) { plugin in
                    HStack(spacing: 12) {
                        Image(systemName: "puzzlepiece.extension.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.beansAmber)
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(plugin.platform)
                                .font(BeansFont.appFont(14))
                                .foregroundStyle(Color.beansLabel)
                            if let sourceURL = plugin.sourceURL, !sourceURL.isEmpty {
                                Text(sourceURL)
                                    .font(BeansFont.appFont(10))
                                    .foregroundStyle(Color.beansComment)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { plugin.enabled },
                            set: { manager.setEnabled($0, for: plugin) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(Color.beansAmber)

                        Button {
                            BeansHaptics.tap()
                            manager.remove(plugin)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 14))
                                .foregroundStyle(Color.red.opacity(0.85))
                        }
                        .buttonStyle(.plain)
                    }
                    if plugin.id != manager.plugins.last?.id {
                        Divider().overlay(Color.beansComment.opacity(0.15))
                    }
                }
            }
        }
        .padding(16)
        .background {
            BeansGlass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .beansCardShadow(radius: 8, y: 3)
    }

    // MARK: - 辅助

    private func installedHint(for preset: MFPluginManager.PresetSource) -> String {
        guard let host = preset.mirrors.first.flatMap({ URL(string: $0)?.host }) else {
            return preset.mirrors.first ?? ""
        }
        return host
    }

    private func isInstalled(_ preset: MFPluginManager.PresetSource) -> Bool {
        let name = preset.name
        return manager.plugins.contains { plugin in
            name.contains(plugin.platform) || plugin.platform.contains(name)
                || (name.contains("哔哩哔哩") && plugin.platform.lowercased().contains("bili"))
        }
    }

    private func install(urls: [String], name: String) {
        Task { @MainActor in
            installingName = name
            message = beansLocalized("正在安装 \(name)…", "Installing \(name)…")
            do {
                let installed = try await manager.install(fromMirrors: urls)
                BeansHaptics.success()
                message = beansLocalized("已安装：\(installed.platform)", "Installed: \(installed.platform)")
                importURL = ""
            } catch {
                BeansLogger.shared.log("插件安装失败：\(error.localizedDescription)", level: .warn)
                errorMessage = error.localizedDescription
                showErrorAlert = true
                message = nil
            }
            installingName = nil
        }
    }
}
