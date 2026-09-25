import SwiftUI

// MARK: - 歌单多选操作条（云端歌单页与本地歌单详情共用）

/// 多选模式下的汇总条：「已选择 N 项」+「全选 / 取消全选」。
struct PlaylistSelectionSummaryBar: View {
    let selectedCount: Int
    let totalCount: Int
    let onToggleAll: () -> Void

    private var allSelected: Bool {
        totalCount > 0 && selectedCount >= totalCount
    }

    /// 标题写成 `String` 属性而不是 `Text(...)` 里的插值：
    /// 插值字符串会同时撞上 `Text(LocalizedStringKey)` 与 `Text<S: StringProtocol>` 两个 init。
    private var summaryText: String {
        "已选择 \(selectedCount) 项"
    }

    private var toggleText: String {
        allSelected ? "取消全选" : "全选"
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(summaryText)
                .font(BeansFont.appFont(13, .semibold))
                .foregroundStyle(Color.beansLabel)
            Spacer(minLength: 0)
            Button(action: onToggleAll) {
                Text(toggleText)
                    .font(BeansFont.appFont(13, .medium))
                    .foregroundStyle(Color.beansAmber)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.beansAmber.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .disabled(totalCount == 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background { BeansSurface(shape: RoundedRectangle(cornerRadius: 14, style: .continuous)) }
    }
}

/// 多选模式下的操作条：下一首播放 / 收藏到歌单 / 下载 / 删除。
///
/// 「删除」能不能用由调用方决定（云端歌单只有网易云源支持写回，
/// 直接隐藏比点了报错更好），这里只负责显示与回调。
struct PlaylistSelectionActionBar: View {
    let selectedCount: Int
    var canDelete = true
    let onPlayNext: () -> Void
    let onCollect: () -> Void
    let onDownload: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            barButton(icon: "text.line.first.and.arrowtriangle.forward", label: "下一首播放", role: .normal, action: onPlayNext)
            barButton(icon: "folder.badge.plus", label: "收藏到歌单", role: .normal, action: onCollect)
            barButton(icon: "arrow.down.circle", label: "下载", role: .normal, action: onDownload)
            if canDelete {
                barButton(icon: "trash", label: "删除", role: .destructive, action: onDelete)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background { BeansSurface(shape: RoundedRectangle(cornerRadius: 18, style: .continuous)) }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.8)
        }
        .beansCardShadow(radius: 14, y: 4)
    }

    private enum BarButtonRole {
        case normal
        case destructive
    }

    private func barButton(icon: String, label: String, role: BarButtonRole, action: @escaping () -> Void) -> some View {
        Button {
            BeansHaptics.tap()
            action()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                Text(label)
                    .font(BeansFont.appFont(10.5, .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(role == .destructive ? Color.red : Color.beansLabel)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(selectedCount == 0)
        .opacity(selectedCount == 0 ? 0.45 : 1)
    }
}
