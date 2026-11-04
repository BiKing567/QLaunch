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
    private var updateSessionID: UInt = 0

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
        updateSessionID &+= 1
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

        updateSessionID &+= 1
        let sessionID = updateSessionID

        activeRelease = release
        inAppUpdateState = .downloading(progress: 0, bytesWritten: 0, totalBytes: release.downloadSize ?? 0)

        let downloader = InAppUpdateDownloader()
        self.downloader = downloader

        downloader.onProgress = { [weak self] progress, written, total in
            Task { @MainActor [weak self] in
                guard let self, self.updateSessionID == sessionID else { return }
                if case .downloading = self.inAppUpdateState {
                    self.inAppUpdateState = .downloading(progress: progress, bytesWritten: written, totalBytes: total)
                }
            }
        }

        downloader.onCompletion = { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.updateSessionID == sessionID else { return }
                switch result {
                case .success(let downloadedURL):
                    await self.installAndRelaunch(packageURL: downloadedURL, sessionID: sessionID)
                case .failure(let error):
                    self.inAppUpdateState = .failed(message: error.localizedDescription)
                }
            }
        }

        downloader.startDownload(from: downloadURL, filename: release.downloadFileName)
    }

    private func installAndRelaunch(packageURL: URL, sessionID: UInt) async {
        guard sessionID == updateSessionID else { return }

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
        let expectedVersion = activeRelease?.tagName

        inAppUpdateState = .installing(status: "正在解压并校验更新包…")

        do {
            // 在后台线程执行挂载、提取与严格签名身份校验，避免阻塞主线程 (F4)
            let (scriptURL, _) = try await Task.detached(priority: .userInitiated) {
                try Self.prepareUpdate(
                    packageURL: packageURL,
                    targetAppURL: targetAppURL,
                    currentPID: currentPID,
                    expectedVersion: expectedVersion
                )
            }.value

            guard sessionID == self.updateSessionID else {
                try? FileManager.default.removeItem(at: scriptURL.deletingLastPathComponent())
                return
            }

            inAppUpdateState = .installing(status: "即将重启应用完成更新…")

            let relaunchProcess = Process()
            relaunchProcess.executableURL = URL(fileURLWithPath: "/bin/sh")
            relaunchProcess.arguments = [scriptURL.path]
            relaunchProcess.standardInput = FileHandle.nullDevice
            relaunchProcess.standardOutput = FileHandle.nullDevice
            relaunchProcess.standardError = FileHandle.nullDevice
            try relaunchProcess.run()

            try await Task.sleep(nanoseconds: 200_000_000)
            NSApp.terminate(nil)
        } catch {
            guard sessionID == self.updateSessionID else { return }
            inAppUpdateState = .failed(message: error.localizedDescription)
        }
    }

    private struct AppSignatureInfo: Sendable {
        let identifier: String?
        let teamIdentifier: String?
        let isDeveloperID: Bool
        let isAdHoc: Bool
    }

    nonisolated private static func runCommand(
        _ executable: String,
        arguments: [String]
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus, output)
    }

    nonisolated private static func queryCodeSignature(at bundleURL: URL) throws -> AppSignatureInfo {
        let (status, output) = try runCommand("/usr/bin/codesign", arguments: ["-dvv", bundleURL.path])
        guard status == 0 else {
            throw NSError(domain: "InAppUpdate", code: 10, userInfo: [
                NSLocalizedDescriptionKey: "无法获取代码签名信息: \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
            ])
        }

        var identifier: String?
        var teamIdentifier: String?
        var isDeveloperID = false
        var isAdHoc = false

        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Identifier=") {
                identifier = String(trimmed.dropFirst("Identifier=".count))
            } else if trimmed.hasPrefix("TeamIdentifier=") {
                let team = String(trimmed.dropFirst("TeamIdentifier=".count))
                if team != "not set" {
                    teamIdentifier = team
                }
            } else if trimmed.contains("Authority=Developer ID Application") {
                isDeveloperID = true
            } else if trimmed.contains("Signature=adhoc") {
                isAdHoc = true
            }
        }

        return AppSignatureInfo(
            identifier: identifier,
            teamIdentifier: teamIdentifier,
            isDeveloperID: isDeveloperID,
            isAdHoc: isAdHoc
        )
    }

    nonisolated private static func verifyCodeSeal(at bundleURL: URL) throws {
        let (status, output) = try runCommand(
            "/usr/bin/codesign",
            arguments: ["--verify", "--deep", "--strict", bundleURL.path]
        )
        guard status == 0 else {
            let errStr = output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(domain: "InAppUpdate", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "更新包签名完整性校验失败: \(errStr.isEmpty ? "代码签名无效或被篡改" : errStr)"
            ])
        }
    }

    nonisolated private static func validateStagedApp(
        stagedAppURL: URL,
        targetAppURL: URL,
        expectedVersion: String?
    ) throws {
        // 1. Bundle 结构与 Info.plist 校验
        let infoPlistURL = stagedAppURL.appendingPathComponent("Contents/Info.plist")
        guard FileManager.default.fileExists(atPath: infoPlistURL.path),
              let plistData = try? Data(contentsOf: infoPlistURL),
              let plist = (try? PropertyListSerialization.propertyList(from: plistData, format: nil)) as? [String: Any] else {
            throw NSError(domain: "InAppUpdate", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "更新包结构错误，缺少或无法解析 Info.plist"
            ])
        }

        // 2. CFBundleIdentifier 匹配校验
        guard let candidateBundleID = plist["CFBundleIdentifier"] as? String, !candidateBundleID.isEmpty else {
            throw NSError(domain: "InAppUpdate", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "更新包缺少 CFBundleIdentifier"
            ])
        }
        let runningBundleID = Bundle.main.bundleIdentifier
        let expectedBundleIDs: Set<String> = {
            if let id = runningBundleID, !id.isEmpty {
                return [id]
            }
            return ["com.qzrzz.qlaunchpad", "com.qzrzz.qlaunchpad.dev"]
        }()
        guard expectedBundleIDs.contains(candidateBundleID) else {
            throw NSError(domain: "InAppUpdate", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "更新包 Bundle ID 不匹配 (期望: \(expectedBundleIDs.joined(separator: " 或 ")), 实际: \(candidateBundleID))"
            ])
        }

        // 3. CFBundleExecutable 与主可执行文件完整性
        let executableName = (plist["CFBundleExecutable"] as? String) ?? "QLaunchpad"
        let executableURL = stagedAppURL.appendingPathComponent("Contents/MacOS/\(executableName)")
        guard FileManager.default.fileExists(atPath: executableURL.path) else {
            throw NSError(domain: "InAppUpdate", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "更新包主可执行文件不存在: \(executableName)"
            ])
        }
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw NSError(domain: "InAppUpdate", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "更新包主可执行文件不可执行: \(executableName)"
            ])
        }

        // 4. 版本号有效性与发布版本匹配
        let candidateShortVersion = plist["CFBundleShortVersionString"] as? String
        guard let candidateVersion = candidateShortVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
              !candidateVersion.isEmpty else {
            throw NSError(domain: "InAppUpdate", code: 8, userInfo: [
                NSLocalizedDescriptionKey: "更新包缺少有效的版本信息 (CFBundleShortVersionString)"
            ])
        }

        func normalizeVersion(_ v: String) -> String {
            var s = v.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.hasPrefix("v") || s.hasPrefix("V") {
                s.removeFirst()
            }
            return s
        }

        let normalizedCandidate = normalizeVersion(candidateVersion)

        if let expected = expectedVersion?.trimmingCharacters(in: .whitespacesAndNewlines), !expected.isEmpty {
            let normalizedExpected = normalizeVersion(expected)
            if normalizedCandidate != normalizedExpected {
                if VersionComparator.isVersion(normalizedExpected, greaterThan: normalizedCandidate) {
                    throw NSError(domain: "InAppUpdate", code: 8, userInfo: [
                        NSLocalizedDescriptionKey: "更新包版本低于期望版本 (期望: \(expected), 实际: \(candidateVersion))"
                    ])
                }
                throw NSError(domain: "InAppUpdate", code: 8, userInfo: [
                    NSLocalizedDescriptionKey: "更新包版本与发布版本不匹配 (期望: \(expected), 实际: \(candidateVersion))"
                ])
            }
        }

        // 校验当前安装版本，防止意外降级
        let currentInfoPlist = targetAppURL.appendingPathComponent("Contents/Info.plist")
        if let currentData = try? Data(contentsOf: currentInfoPlist),
           let currentPlist = (try? PropertyListSerialization.propertyList(from: currentData, format: nil)) as? [String: Any],
           let currentVer = currentPlist["CFBundleShortVersionString"] as? String {
            let normalizedCurrent = normalizeVersion(currentVer)
            if VersionComparator.isVersion(normalizedCurrent, greaterThan: normalizedCandidate) {
                throw NSError(domain: "InAppUpdate", code: 8, userInfo: [
                    NSLocalizedDescriptionKey: "更新包版本低于当前安装版本，禁止降级 (当前: \(currentVer), 更新包: \(candidateVersion))"
                ])
            }
        }

        // 5. 严格代码签名与资源封印校验
        try verifyCodeSeal(at: stagedAppURL)

        // 6. 开发者身份与签名信任链校验
        let candidateSig = try queryCodeSignature(at: stagedAppURL)
        if let codeIdentifier = candidateSig.identifier, !codeIdentifier.isEmpty {
            guard expectedBundleIDs.contains(codeIdentifier) else {
                throw NSError(domain: "InAppUpdate", code: 6, userInfo: [
                    NSLocalizedDescriptionKey: "更新包签名 Identifier 不匹配 (期望: \(expectedBundleIDs.joined(separator: " 或 ")), 实际: \(codeIdentifier))"
                ])
            }
        }
        let sourceForCurrentSig = Bundle.main.bundleURL.pathExtension == "app"
            ? Bundle.main.bundleURL
            : targetAppURL
        let currentSig = try? queryCodeSignature(at: sourceForCurrentSig)

        if let current = currentSig {
            if let currentTeam = current.teamIdentifier {
                guard candidateSig.teamIdentifier == currentTeam else {
                    throw NSError(domain: "InAppUpdate", code: 12, userInfo: [
                        NSLocalizedDescriptionKey: "更新包签名 Team ID 不匹配 (期望: \(currentTeam), 实际: \(candidateSig.teamIdentifier ?? "无"))"
                    ])
                }
                if current.isDeveloperID {
                    guard candidateSig.isDeveloperID else {
                        throw NSError(domain: "InAppUpdate", code: 13, userInfo: [
                            NSLocalizedDescriptionKey: "更新包未由 Developer ID Application 签名，禁止覆盖正式发布版本"
                        ])
                    }
                }
            } else if current.isDeveloperID {
                guard candidateSig.isDeveloperID else {
                    throw NSError(domain: "InAppUpdate", code: 13, userInfo: [
                        NSLocalizedDescriptionKey: "更新包未由 Developer ID Application 签名"
                    ])
                }
            } else {
                // 当前是本地开发/测试版 (adhoc)，更新包须为 Developer ID 或 adhoc
                if !candidateSig.isDeveloperID && !candidateSig.isAdHoc {
                    throw NSError(domain: "InAppUpdate", code: 14, userInfo: [
                        NSLocalizedDescriptionKey: "更新包签名不属于已知可信签名类型"
                    ])
                }
            }
        }
    }

    nonisolated private static func prepareUpdate(
        packageURL: URL,
        targetAppURL: URL,
        currentPID: Int32,
        expectedVersion: String?
    ) throws -> (scriptURL: URL, stagedAppURL: URL) {
        let tempDir = packageURL.deletingLastPathComponent()
        let isDMG = packageURL.pathExtension.lowercased() == "dmg"
        let stagedAppURL = tempDir.appendingPathComponent("QLaunch.app", isDirectory: true)

        if isDMG {
            let mountDir = tempDir.appendingPathComponent("mount", isDirectory: true)
            try FileManager.default.createDirectory(at: mountDir, withIntermediateDirectories: true)

            let (attachStatus, attachOutput) = try runCommand(
                "/usr/bin/hdiutil",
                arguments: ["attach", "-nobrowse", "-readonly", packageURL.path, "-mountpoint", mountDir.path]
            )
            guard attachStatus == 0 else {
                throw NSError(domain: "InAppUpdate", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "挂载 DMG 镜像失败: \(attachOutput)"
                ])
            }

            defer {
                _ = try? runCommand("/usr/bin/hdiutil", arguments: ["detach", mountDir.path, "-force"])
            }

            let contents = try FileManager.default.contentsOfDirectory(atPath: mountDir.path)
            guard let appName = contents.first(where: { $0.hasSuffix(".app") }) else {
                throw NSError(domain: "InAppUpdate", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "在安装镜像中未找到应用程序包"
                ])
            }
            let sourceAppURL = mountDir.appendingPathComponent(appName)

            let (dittoStatus, dittoOutput) = try runCommand(
                "/usr/bin/ditto",
                arguments: [sourceAppURL.path, stagedAppURL.path]
            )
            guard dittoStatus == 0 else {
                throw NSError(domain: "InAppUpdate", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "提取应用程序包失败: \(dittoOutput)"
                ])
            }
        } else {
            let (dittoStatus, dittoOutput) = try runCommand(
                "/usr/bin/ditto",
                arguments: ["-xk", packageURL.path, tempDir.path]
            )
            guard dittoStatus == 0 else {
                throw NSError(domain: "InAppUpdate", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "解压 ZIP 安装包失败: \(dittoOutput)"
                ])
            }
            if !FileManager.default.fileExists(atPath: stagedAppURL.path) {
                let contents = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
                guard let appName = contents.first(where: { $0.hasSuffix(".app") }) else {
                    throw NSError(domain: "InAppUpdate", code: 2, userInfo: [
                        NSLocalizedDescriptionKey: "在解压产物中未找到应用程序包"
                    ])
                }
                let foundURL = tempDir.appendingPathComponent(appName, isDirectory: true)
                if foundURL.path != stagedAppURL.path {
                    try FileManager.default.moveItem(at: foundURL, to: stagedAppURL)
                }
            }
        }

        // 执行严格校验（身份、版本、封印与开发者签名）
        try validateStagedApp(
            stagedAppURL: stagedAppURL,
            targetAppURL: targetAppURL,
            expectedVersion: expectedVersion
        )

        // 生成具备原子替换与失败回滚的安全更新脚本
        let scriptPath = tempDir.appendingPathComponent("relaunch.sh").path
        let targetDirPath = targetAppURL.deletingLastPathComponent().path
        let targetName = targetAppURL.lastPathComponent

        let scriptContent = """
        #!/bin/sh
        set -u

        PID=\(currentPID)
        TARGET="\(targetAppURL.path)"
        STAGED="\(stagedAppURL.path)"
        TEMPDIR="\(tempDir.path)"
        TARGET_DIR="\(targetDirPath)"
        TARGET_NAME="\(targetName)"
        STAGING="${TARGET_DIR}/.${TARGET_NAME}.staging.$$"
        BACKUP="${TARGET_DIR}/.${TARGET_NAME}.backup.$$"
        LOGFILE="${TEMPDIR}/update.log"

        log() {
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOGFILE"
        }

        log "Waiting for old process $PID to exit..."
        while kill -0 "$PID" 2>/dev/null; do
            sleep 0.1
        done
        log "Old process $PID exited."

        # 1. 清理可能残留的临时目录
        rm -rf "$STAGING" "$BACKUP" 2>/dev/null || true

        # 2. 先复制到目标目录同卷暂存区，若复制失败决不触碰 TARGET (保留旧应用)
        log "Copying $STAGED to $STAGING..."
        if ! /usr/bin/ditto "$STAGED" "$STAGING"; then
            log "Error: Staging copy failed"
            rm -rf "$STAGING"
            exit 1
        fi

        # 3. 校验暂存产物结构与签名
        if [ ! -d "$STAGING/Contents" ]; then
            log "Error: Staged app is missing Contents"
            rm -rf "$STAGING"
            exit 1
        fi

        if ! /usr/bin/codesign --verify --deep --strict "$STAGING" 2>> "$LOGFILE"; then
            log "Error: Staged app signature verification failed"
            rm -rf "$STAGING"
            exit 1
        fi

        # 4. 执行原子重命名替换；若旧应用存在，先移入 BACKUP
        MOVED_OLD=0
        if [ -e "$TARGET" ]; then
            log "Backing up current app to $BACKUP..."
            if mv "$TARGET" "$BACKUP"; then
                MOVED_OLD=1
            else
                log "Error: Failed to move current app to backup"
                rm -rf "$STAGING"
                exit 1
            fi
        fi

        log "Promoting staging to $TARGET..."
        if mv "$STAGING" "$TARGET"; then
            /usr/bin/xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true
            log "Launching updated app at $TARGET..."
            if /usr/bin/open "$TARGET"; then
                log "Launch succeeded, cleaning up backup..."
                rm -rf "$BACKUP" "$TEMPDIR"
                exit 0
            else
                log "Error: Failed to launch $TARGET, performing rollback..."
                if [ "$MOVED_OLD" -eq 1 ] && [ -e "$BACKUP" ]; then
                    rm -rf "$TARGET"
                    mv "$BACKUP" "$TARGET"
                    /usr/bin/open "$TARGET" 2>/dev/null || true
                fi
                exit 1
            fi
        else
            log "Error: Failed to promote staging to target, rolling back..."
            rm -rf "$STAGING"
            if [ "$MOVED_OLD" -eq 1 ] && [ -e "$BACKUP" ]; then
                mv "$BACKUP" "$TARGET"
                /usr/bin/open "$TARGET" 2>/dev/null || true
            fi
            exit 1
        fi
        """

        try scriptContent.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)

        return (URL(fileURLWithPath: scriptPath), stagedAppURL)
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
    private var destinationFilename: String?

    var onProgress: ((Double, Int64, Int64) -> Void)?
    var onCompletion: ((Result<URL, Error>) -> Void)?

    func startDownload(from url: URL, filename: String? = nil) {
        cancel()
        self.destinationFilename = filename
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
            let filename = destinationFilename ?? downloadTask.response?.suggestedFilename ?? "update.dmg"
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
