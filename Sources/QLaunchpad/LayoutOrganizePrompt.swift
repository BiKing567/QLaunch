import Foundation
import QLaunchpadCore

enum LayoutOrganizePrompt {
    static func make(
        executablePath: String = Bundle.main.executableURL?.path
            ?? "/Applications/QLaunch.app/Contents/MacOS/QLaunchpad",
        domain: String = Bundle.main.bundleIdentifier
            ?? "com.qzrzz.qlaunchpad",
        language: AppLanguage? = nil
    ) -> String {
        let lang = language ?? LocalizationManager.shared.effectiveLanguage
        let cli = shellSingleQuoted(executablePath)
        let backup = LaunchpadPreferenceStore.layoutBackupFileURL(domain: domain).path
        let backupQuoted = shellSingleQuoted(backup)
        let layoutFile = LaunchpadPreferenceStore.layoutWorkingFileURL(domain: domain).path
        let layoutQuoted = shellSingleQuoted(layoutFile)

        if lang == .zhHans {
            return """
            你是 QLaunchpad（macOS 启动台）布局整理助手。通过其命令行读写布局 JSON，请严格按以下步骤操作：

            ## 变量
            QL=\(cli)
            FILE=\(layoutQuoted)

            ## 操作步骤
            1. 导出当前布局：
               "$QL" export --out "$FILE"

            2. 读取并修改 "$FILE" 中的 items 与 hidden 数组：
               - 应用 ID 必须以 catalog[].id 为准（不要使用应用名或编造 ID）。
               - 文件夹格式：{"type": "folder", "name": "类别名", "apps": ["id1", "id2"]}（仅单层结构，不支持嵌套；修改已有文件夹请保留其 id）。
               - 每个应用 ID 只能出现在根 items、某一文件夹 apps 或 hidden 之一（三者互斥）。
               - 根 items 的顺序即显示顺序；一页容量为 grid.pageCapacity 项。
               - 需隐藏的应用将其 ID 放入 hidden 数组，并从 items 中移除。

            3. 校验并导入生效：
               "$QL" import --in "$FILE" --dry-run --strict
               "$QL" import --in "$FILE" --merge --strict

            4. 完成后简要说明调整结果（如新建了哪些文件夹、首屏放了哪些应用），不要输出完整 JSON。

            > 回滚备用："$QL" import --in \(backupQuoted) --merge
            """
        } else {
            return """
            You are the QLaunchpad layout assistant. Operate via its CLI to read and update the layout JSON:

            ## Variables
            QL=\(cli)
            FILE=\(layoutQuoted)

            ## Steps
            1. Export current layout:
               "$QL" export --out "$FILE"

            2. Read and edit `items` and `hidden` in "$FILE":
               - Use `catalog[].id` as the app ID (do not use app name or invent IDs).
               - Folder format: {"type": "folder", "name": "Category", "apps": ["id1", "id2"]} (flat only, no nesting; preserve existing folder IDs).
               - Each app ID must appear at most once across root `items`, folder `apps`, and `hidden` (mutually exclusive).
               - The order of root `items` is the display order; page capacity is `grid.pageCapacity`.
               - To hide an app, put its ID into `hidden` and remove it from `items`.

            3. Validate and apply:
               "$QL" import --in "$FILE" --dry-run --strict
               "$QL" import --in "$FILE" --merge --strict

            4. Briefly summarize changes (folders created, 1st page apps). Do not output the entire JSON.

            > Rollback if needed: "$QL" import --in \(backupQuoted) --merge
            """
        }
    }

    private static func shellSingleQuoted(_ path: String) -> String {
        "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
