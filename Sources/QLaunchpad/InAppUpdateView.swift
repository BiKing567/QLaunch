import AppKit
import Combine
import QLaunchpadCore
import SwiftUI

/// GitHub Release 资产与元数据。
struct GitHubReleaseInfo: Sendable, Identifiable, Equatable {
    var id: String { tagName }
    let tagName: String
    let name: String
    let body: String
    let htmlURL: String
    let downloadAssetURL: URL?
    let downloadSize: Int64?
    let downloadFileName: String?
}

/// 应用内更新状态机。
enum InAppUpdateState: Equatable {
    case available(GitHubReleaseInfo)
    case downloading(progress: Double, bytesWritten: Int64, totalBytes: Int64)
    case installing(status: String)
    case failed(message: String)
}

/// 专用的应用内更新窗口控制器。
@MainActor
final class InAppUpdateWindowController: NSWindowController, NSWindowDelegate {
    static let shared = InAppUpdateWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 440),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "QLaunch 软件更新"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(for release: GitHubReleaseInfo, updater: Updater) {
        guard let window else { return }
        window.contentView = NSHostingView(rootView: InAppUpdateView(updater: updater, release: release))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        Updater.shared.cancelInAppUpdateIfDownloading()
    }
}

/// 应用内更新界面视图。
struct InAppUpdateView: View {
    @ObservedObject var updater: Updater
    let release: GitHubReleaseInfo

    var body: some View {
        VStack(spacing: 16) {
            // 头部：应用图标与版本基本信息
            HStack(alignment: .top, spacing: 14) {
                if let icon = updater.appIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 54, height: 54)
                        .shadow(color: .black.opacity(0.12), radius: 3, x: 0, y: 1.5)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("发现新版本 \(release.name)")
                        .font(.system(size: 15, weight: .bold))
                    Text("最新版本：\(release.tagName)    当前版本：v\(updater.currentVersionString)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            // 中间：更新说明
            VStack(alignment: .leading, spacing: 6) {
                Text("更新说明：")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.secondary)

                UpdateNotesMarkdownView(markdown: release.body)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()

            // 底部：根据当前更新状态展示操作与进度
            footerControls
        }
        .padding(18)
        .frame(width: 500, height: 440)
    }

    @ViewBuilder
    private var footerControls: some View {
        switch updater.inAppUpdateState {
        case .available:
            HStack {
                Button("在浏览器中查看") {
                    if let url = URL(string: release.htmlURL) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
                .font(.system(size: 12))

                Spacer()

                Button("稍后") {
                    updater.closeUpdateWindow()
                }
                .keyboardShortcut(.cancelAction)

                if release.downloadAssetURL != nil {
                    Button("立即更新") {
                        updater.startInAppUpdate(for: release)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("前往网页下载") {
                        if let url = URL(string: release.htmlURL) {
                            NSWorkspace.shared.open(url)
                        }
                        updater.closeUpdateWindow()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }

        case let .downloading(progress, written, total):
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: max(0.01, min(1.0, progress)))
                    .progressViewStyle(.linear)

                HStack {
                    Text("正在下载更新… \(formatBytes(written)) / \(total > 0 ? formatBytes(total) : "未知") (\(Int(progress * 100))%)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button("取消") {
                        updater.cancelInAppUpdate()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

        case let .installing(status):
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                Text(status)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer()
            }

        case let .failed(message):
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.system(size: 12))
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                }

                HStack {
                    Button("在浏览器中下载") {
                        if let url = URL(string: release.htmlURL) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 12))

                    Spacer()

                    Button("关闭") {
                        updater.closeUpdateWindow()
                    }

                    Button("重试") {
                        updater.startInAppUpdate(for: release)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
