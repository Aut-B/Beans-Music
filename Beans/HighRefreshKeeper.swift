import QuartzCore
import SwiftUI
import UIKit

/// 全局高刷新率保持器（强制锁频开关）。
///
/// 背景：iOS 的 ProMotion 是「按需提频」的 —— 滚动、动画时升到 120Hz，画面静止时自动降到
/// 10~24Hz 省电。Info.plist 里的 `CADisableMinimumFrameDurationOnPhone = true` 已经去掉了
/// 60Hz 上限，系统会自行调度到 120Hz，不需要额外干预。
///
/// 这里额外挂的 CADisplayLink 不是「解锁 120Hz」，而是**强制锁频**：它用一个空回调把整个 App
/// 钉在设备最高刷新率上，画面完全静止时也不允许降频。代价是渲染服务器持续满帧合成 →
/// 发热 → SoC 热降频 → 掉帧，反而比自适应更卡，也更费电。
///
/// 因此它默认关闭，只在用户明确需要「所有页面恒定最高帧率」时手动开启。
final class HighRefreshKeeper {
    static let shared = HighRefreshKeeper()

    /// 键名由旧的 `beans.enableHighRefresh` 改为 `beans.forceMaxRefresh`。
    /// 旧键在老用户设备上被 `set(true)` 写死过，且语义不同，直接沿用会让老设备继续满帧运行，
    /// 所以换新键，让新的默认值（关闭）对所有设备生效。
    static let defaultsKey = "beans.forceMaxRefresh"

    private var displayLink: CADisplayLink?

    private init() {}

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [defaultsKey: false])
    }

    func configureFromDefaults() {
        configure(enabled: UserDefaults.standard.bool(forKey: Self.defaultsKey))
    }

    func configure(enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.defaultsKey)
        if enabled {
            start()
        } else {
            stop()
        }
    }

    /// 页面挂载时不再无条件开工，只跟随用户设置，避免任意页面出现就重新钉住刷新率。
    func attach(to view: UIView) {
        _ = view
        if UserDefaults.standard.bool(forKey: Self.defaultsKey) {
            start()
        }
    }

    private func start() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        if #available(iOS 15.0, *) {
            let maximum = Float(min(120, max(60, UIScreen.main.maximumFramesPerSecond)))
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: maximum >= 120 ? 120 : maximum,
                maximum: maximum,
                preferred: maximum
            )
        } else {
            link.preferredFramesPerSecond = 120
        }
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick() {}
}

struct HighRefreshConfigurator: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        HighRefreshKeeper.shared.attach(to: uiView)
    }
}
