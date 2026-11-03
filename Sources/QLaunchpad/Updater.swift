import AppKit
import Combine
import QLaunchpadCore
import SwiftUI

/// GitHub Releases 更新管理器（从当前分支维护的仓库获取更新，并支持应用内直接下载与静默安装更新）。
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    public static let githubRepo = "BiKing567/QLaunch"
    public static let releasesAPI = "https://api.github.com/repos/\(githubRepo)/releases"
    public static let releasesWebURL = "https://github.com/\(githubRepo)/releases"

    /// 正在检查时禁用按钮，避免重复触发。
    @Published private(set) var canCheckForUpdates = true

    /// 应用内更新状态。
    @Published var inAppUpdateState: InAppUpdateState = .available(
        GitHubReleaseInfo(
            tagName: "",
            name: "",
            body: "",
            htmlURL: "",
            downloadAssetURL: nil,
            downloadSize: nil,
            downloadFileName: nil
        )
    )

    /// 是否自动检查更新，持久化在 UserDefaults。
    @Published var automaticallyChecksForUpdates: Bool {
        didSet {
            UserDefaults.standard.set(automaticallyChecksForUpdates, forKey: "automaticallyChecksForUpdates")
            updateBackgroundScheduling()
        }
    }

    var isCheckEnabled: Bool {
        canCheckForUpdates
    }

    var currentVersionString: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.3.3"
    }

    private(set) var backgroundTimer: Timer?
    private(set) var startupCheckWorkItem: DispatchWorkItem?
    private var activeRelease: GitHubReleaseInfo?
    private var downloader: InAppUpdateDownloader?

    private init() {
        let initialSetting = UserDefaults.standard.object(forKey: "automaticallyChecksForUpdates") as? Bool ?? true
        self.automaticallyChecksForUpdates = initialSetting
        updateBackgroundScheduling()

        if initialSetting {
            scheduleStartupCheck()
        }
    }

    private func scheduleStartupCheck() {
        startupCheckWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.automaticallyChecksForUpdates else { return }
            self.performCheck(isBackground: true)
        }
        startupCheckWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: item)
    }

    private func updateBackgroundScheduling() {
        if automaticallyChecksForUpdates {
            if backgroundTimer == nil {
                backgroundTimer = Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.automaticallyChecksForUpdates else { return }
                        self.performCheck(isBackground: true)
                    }
                }
            }
        } else {
            backgroundTimer?.invalidate()
            backgroundTimer = nil
            startupCheckWorkItem?.cancel()
            startupCheckWorkItem = nil
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

                // 优先查找 .dmg 或 .zip 安装资产
                let assets = latest["assets"] as? [[String: Any]] ?? []
                let dmgAsset = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".dmg") == true })
                    ?? assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true })
                let downloadAssetURL = (dmgAsset?["browser_download_url"] as? String).flatMap { URL(string: $0) }
                let downloadSize = dmgAsset?["size"] as? Int64
                let downloadFileName = dmgAsset?["name"] as? String

                let releaseInfo = GitHubReleaseInfo(
                    tagName: tagName,
                    name: releaseName,
                    body: body,
                    htmlURL: htmlURL,
                    downloadAssetURL: downloadAssetURL,
                    downloadSize: downloadSize,
                    downloadFileName: downloadFileName
                )

                if Self.isVersion(tagName, greaterThan: currentVersionString) || Self.isVersion(releaseName, greaterThan: currentVersionString) {
                    showUpdateWindow(for: releaseInfo)
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

    var appIconImage: NSImage? {
        if let image = QLaunchpadAppIcon.image {
            return image
        }
        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension == "app" {
            let icon = NSWorkspace.shared.icon(forFile: bundleURL.path)
            if icon.size.width > 0 {
                return icon
            }
        }
        return NSApplication.shared.applicationIconImage
    }

    func showUpdateWindow(for release: GitHubReleaseInfo) {
        activeRelease = release
        inAppUpdateState = .available(release)
        InAppUpdateWindowController.shared.show(for: release, updater: self)
    }

    func closeUpdateWindow() {
        cancelInAppUpdateIfDownloading()
        InAppUpdateWindowController.shared.close()
    }

    func cancelInAppUpdateIfDownloading() {
        if case .downloading = inAppUpdateState {
            cancelInAppUpdate()
        }
    }

    func cancelInAppUpdate() {
        downloader?.cancel()
        downloader = nil
        if let activeRelease {
            inAppUpdateState = .available(activeRelease)
        }
    }

    func startInAppUpdate(for release: GitHubReleaseInfo) {
        guard let downloadURL = release.downloadAssetURL else {
            if let url = URL(string: release.htmlURL) {
                NSWorkspace.shared.open(url)
            }
            return
        }

        activeRelease = release
        inAppUpdateState = .downloading(progress: 0, bytesWritten: 0, totalBytes: release.downloadSize ?? 0)

        let downloader = InAppUpdateDownloader()
        self.downloader = downloader

        downloader.onProgress = { [weak self] progress, written, total in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if case .downloading = self.inAppUpdateState {
                    self.inAppUpdateState = .downloading(progress: progress, bytesWritten: written, totalBytes: total)
                }
            }
        }

        downloader.onCompletion = { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch result {
                case .success(let downloadedURL):
                    await self.installAndRelaunch(packageURL: downloadedURL)
                case .failure(let error):
                    self.inAppUpdateState = .failed(message: error.localizedDescription)
                }
            }
        }

        downloader.startDownload(from: downloadURL)
    }

    private func installAndRelaunch(packageURL: URL) async {
        let tempDir = packageURL.deletingLastPathComponent()
        let isDMG = packageURL.pathExtension.lowercased() == "dmg"
        let stagedAppURL = tempDir.appendingPathComponent("QLaunch.app", isDirectory: true)

        inAppUpdateState = .installing(status: "正在挂载并校验安装包…")

        do {
            if isDMG {
                let mountDir = tempDir.appendingPathComponent("mount", isDirectory: true)
                try FileManager.default.createDirectory(at: mountDir, withIntermediateDirectories: true)

                let attach = Process()
                attach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                attach.arguments = ["attach", "-nobrowse", "-readonly", packageURL.path, "-mountpoint", mountDir.path]
                try attach.run()
                attach.waitUntilExit()
                guard attach.terminationStatus == 0 else {
                    throw NSError(domain: "InAppUpdate", code: 1, userInfo: [NSLocalizedDescriptionKey: "挂载 DMG 镜像失败"])
                }

                defer {
                    let detach = Process()
                    detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                    detach.arguments = ["detach", mountDir.path, "-force"]
                    try? detach.run()
                    detach.waitUntilExit()
                }

                let contents = try FileManager.default.contentsOfDirectory(atPath: mountDir.path)
                guard let appName = contents.first(where: { $0.hasSuffix(".app") }) else {
                    throw NSError(domain: "InAppUpdate", code: 2, userInfo: [NSLocalizedDescriptionKey: "在安装镜像中未找到应用程序包"])
                }
                let sourceAppURL = mountDir.appendingPathComponent(appName)

                let ditto = Process()
                ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                ditto.arguments = [sourceAppURL.path, stagedAppURL.path]
                try ditto.run()
                ditto.waitUntilExit()
                guard ditto.terminationStatus == 0 else {
                    throw NSError(domain: "InAppUpdate", code: 3, userInfo: [NSLocalizedDescriptionKey: "提取应用程序包失败"])
                }
            } else {
                let ditto = Process()
                ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                ditto.arguments = ["-xk", packageURL.path, tempDir.path]
                try ditto.run()
                ditto.waitUntilExit()
                guard ditto.terminationStatus == 0 else {
                    throw NSError(domain: "InAppUpdate", code: 4, userInfo: [NSLocalizedDescriptionKey: "解压 ZIP 安装包失败"])
                }
            }

            let executablePath = stagedAppURL.appendingPathComponent("Contents/MacOS/QLaunchpad").path
            guard FileManager.default.fileExists(atPath: executablePath) else {
                throw NSError(domain: "InAppUpdate", code: 5, userInfo: [NSLocalizedDescriptionKey: "校验更新包结构失败，可执行文件不存在"])
            }

            inAppUpdateState = .installing(status: "即将重启应用完成更新…")

            let currentBundleURL = Bundle.main.bundleURL
            let targetAppURL: URL
            if currentBundleURL.pathExtension == "app" {
                targetAppURL = currentBundleURL
            } else if FileManager.default.fileExists(atPath: "/Applications/QLaunch.app") {
                targetAppURL = URL(fileURLWithPath: "/Applications/QLaunch.app")
            } else {
                targetAppURL = currentBundleURL
            }

            let currentPID = ProcessInfo.processInfo.processIdentifier
            let scriptPath = tempDir.appendingPathComponent("relaunch.sh").path

            let scriptContent = """
            #!/bin/sh
            PID=\(currentPID)
            TARGET="\(targetAppURL.path)"
            STAGED="\(stagedAppURL.path)"
            TEMPDIR="\(tempDir.path)"

            while kill -0 "$PID" 2>/dev/null; do
                sleep 0.1
            done

            rm -rf "$TARGET"
            /usr/bin/ditto "$STAGED" "$TARGET"
            /usr/bin/xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true

            open "$TARGET"
            rm -rf "$TEMPDIR"
            """

            try scriptContent.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)

            let relaunchProcess = Process()
            relaunchProcess.executableURL = URL(fileURLWithPath: "/bin/sh")
            relaunchProcess.arguments = [scriptPath]
            relaunchProcess.standardInput = FileHandle.nullDevice
            relaunchProcess.standardOutput = FileHandle.nullDevice
            relaunchProcess.standardError = FileHandle.nullDevice
            try relaunchProcess.run()

            try await Task.sleep(nanoseconds: 200_000_000)
            NSApp.terminate(nil)
        } catch {
            inAppUpdateState = .failed(message: error.localizedDescription)
        }
    }

    /// 供开发者/测试 Option-点击快速预览与实测应用内更新流程。
    func simulateUpdateAvailableForTesting() {
        let sampleNotes = """
        ## 新增功能
        - 支持应用内自动下载、解压与无缝重启更新，无需手动前往网页
        - 增设下载进度条、实时传输体积与状态提示
        
        ## 优化与修复
        - 修复深色模式背景文件夹底板偏暗问题
        - 提升多页文件夹与手势翻页稳定性
        """
        let fakeRelease = GitHubReleaseInfo(
            tagName: "v1.3.4-test",
            name: "V1.3.4 (应用内更新体验)",
            body: sampleNotes,
            htmlURL: Self.releasesWebURL,
            downloadAssetURL: URL(string: "https://github.com/BiKing567/QLaunch/releases/download/v1.3.3/QLaunch-1.3.3.dmg"),
            downloadSize: 8005122,
            downloadFileName: "QLaunch-1.3.3.dmg"
        )
        showUpdateWindow(for: fakeRelease)
    }

    private func showUpToDateAlert() {
        let alert = NSAlert()
        if let appIcon = appIconImage {
            alert.icon = appIcon
        }
        alert.messageText = "已是最新版本"
        alert.informativeText = "QLaunch \(currentVersionString) 当前已是最新版本，无需更新。"
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
        if let appIcon = appIconImage {
            alert.icon = appIcon
        }
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

/// 基于 URLSessionDownloadDelegate 的轻量级资产下载管理器。
private final class InAppUpdateDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var session: URLSession?
    private var downloadTask: URLSessionDownloadTask?

    var onProgress: ((Double, Int64, Int64) -> Void)?
    var onCompletion: ((Result<URL, Error>) -> Void)?

    func startDownload(from url: URL) {
        cancel()
        let config = URLSessionConfiguration.default
        let session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        self.session = session
        let task = session.downloadTask(with: url)
        self.downloadTask = task
        task.resume()
    }

    func cancel() {
        downloadTask?.cancel()
        downloadTask = nil
        session?.invalidateAndCancel()
        session = nil
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let progress = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0.0
        onProgress?(progress, totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("qlaunch-update-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let filename = downloadTask.response?.suggestedFilename ?? "update.dmg"
            let destinationURL = tempDir.appendingPathComponent(filename)
            try FileManager.default.moveItem(at: location, to: destinationURL)
            onCompletion?(.success(destinationURL))
        } catch {
            onCompletion?(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error as? URLError, error.code == .cancelled {
            return
        }
        if let error {
            onCompletion?(.failure(error))
        }
    }
}
