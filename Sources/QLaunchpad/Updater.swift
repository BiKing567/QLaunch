import AppKit
import Combine
import QLaunchpadCore

/// GitHub Releases 更新管理器（从当前分支维护的仓库获取更新）。
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    public static let githubRepo = "BiKing567/QLaunch"
    public static let releasesAPI = "https://api.github.com/repos/\(githubRepo)/releases"
    public static let releasesWebURL = "https://github.com/\(githubRepo)/releases"

    /// 正在检查时禁用按钮，避免重复触发。
    @Published private(set) var canCheckForUpdates = true

    /// 是否自动检查更新，持久化在 UserDefaults。
    @Published var automaticallyChecksForUpdates: Bool {
        didSet {
            UserDefaults.standard.set(automaticallyChecksForUpdates, forKey: "automaticallyChecksForUpdates")
        }
    }

    var isCheckEnabled: Bool {
        canCheckForUpdates
    }

    private var backgroundTimer: Timer?

    private init() {
        self.automaticallyChecksForUpdates = UserDefaults.standard.object(forKey: "automaticallyChecksForUpdates") as? Bool ?? true

        if automaticallyChecksForUpdates {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                self?.performCheck(isBackground: true)
            }
            backgroundTimer = Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    if self?.automaticallyChecksForUpdates == true {
                        self?.performCheck(isBackground: true)
                    }
                }
            }
        }
    }

    func checkForUpdates() {
        NotificationCenter.default.post(name: .qlaunchpadDismiss, object: nil)
        performCheck(isBackground: false)
    }

    private func performCheck(isBackground: Bool) {
        guard canCheckForUpdates else { return }
        canCheckForUpdates = false

        Task {
            defer {
                canCheckForUpdates = true
            }

            do {
                guard let url = URL(string: Self.releasesAPI) else { return }
                var request = URLRequest(url: url)
                request.timeoutInterval = 15
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("QLaunch", forHTTPHeaderField: "User-Agent")

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    if !isBackground {
                        showErrorAlert()
                    }
                    return
                }

                guard let jsonArray = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    if !isBackground {
                        showErrorAlert()
                    }
                    return
                }

                // 过滤草稿，获取最新 release
                let validReleases = jsonArray.filter { ($0["draft"] as? Bool) != true }
                guard let latest = validReleases.first else {
                    if !isBackground {
                        showUpToDateAlert()
                    }
                    return
                }

                let tagName = latest["tag_name"] as? String ?? ""
                let releaseName = latest["name"] as? String ?? tagName
                let body = latest["body"] as? String ?? ""
                let htmlURL = latest["html_url"] as? String ?? Self.releasesWebURL

                let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1.1"

                if Self.isVersion(tagName, greaterThan: currentVersion) || Self.isVersion(releaseName, greaterThan: currentVersion) {
                    showNewVersionAlert(name: releaseName, tag: tagName, body: body, urlString: htmlURL)
                } else {
                    if !isBackground {
                        showUpToDateAlert()
                    }
                }
            } catch {
                if !isBackground {
                    showErrorAlert()
                }
            }
        }
    }

    static func isVersion(_ v1: String, greaterThan v2: String) -> Bool {
        VersionComparator.isVersion(v1, greaterThan: v2)
    }

    private func showNewVersionAlert(name: String, tag: String, body: String, urlString: String) {
        let alert = NSAlert()
        alert.messageText = "发现新版本 \(name)"
        let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1.1"
        let notes = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let notePreview = notes.isEmpty ? "" : "\n\n更新说明：\n" + (notes.count > 500 ? String(notes.prefix(500)) + "…" : notes)
        alert.informativeText = "当前版本：v\(currentVersion)\n最新版本：\(tag)\(notePreview)"
        alert.addButton(withTitle: "前往下载")
        alert.addButton(withTitle: "稍后")
        alert.alertStyle = .informational

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn, let url = URL(string: urlString) {
                    NSWorkspace.shared.open(url)
                }
            }
        } else {
            if alert.runModal() == .alertFirstButtonReturn, let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func showUpToDateAlert() {
        let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1.1"
        let alert = NSAlert()
        alert.messageText = "已是最新版本"
        alert.informativeText = "QLaunch \(currentVersion) 当前已是最新版本，无需更新。"
        alert.addButton(withTitle: "好")
        alert.alertStyle = .informational
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func showErrorAlert() {
        let alert = NSAlert()
        alert.messageText = "检查更新失败"
        alert.informativeText = "无法连接至 GitHub 获取更新信息，请检查网络连接或稍后重试。"
        alert.addButton(withTitle: "好")
        alert.alertStyle = .warning
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
