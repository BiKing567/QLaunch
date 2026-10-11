# 🚀 QLaunch (BiKing567 维护分支)

<div align="center">
  <img src="web/icons/qlaunchpad-512.png" width="128" alt="QLaunch">
</div>

---

<p align="center">
  简单、高性能的 macOS Launchpad 替代方案。设计师级别图标高质量渲染、120Hz 高帧率、液态玻璃、丝滑过渡动画。
</p>

<p align="center">
  <b>本分支基于 <a href="https://github.com/qzrzz/QLaunch">qzrzz/QLaunch</a> 进行了多项手势、动画与稳定性的深度重构优化。</b>
</p>

- 📦 **本分支最新下载**：[BiKing567/QLaunch Releases (V1.1)](https://github.com/BiKing567/QLaunch/releases)
- 🏠 **原项目主页**：[https://qzrzz.com/QLaunch/](https://qzrzz.com/QLaunch/)
- 🔗 **原项目仓库**：[https://github.com/qzrzz/QLaunch](https://github.com/qzrzz/QLaunch)

<table>
  <tr>
    <td><img src="web/assets/s1.png" alt="QLaunch" width="100%"></td>
    <td><img src="web/assets/s2.png" alt="QLaunch" width="100%"></td>
  </tr>
</table>

## 🌟 本分支重点改进与优化

本项目在原版 QLaunch 的优秀基础上，针对触控板多指手势、动画交互细节、系统原生兼容性进行了全面深度优化与修复：

### 🖐️ 触控板手势全面升级与防系统冲突
- **彻底接管系统启动台与 Spotlight 手势**：阻断系统全局启动台及 Spotlight FluidGesture 的抢占，彻底解决四指进入时系统启动台或聚焦搜索同时弹出的问题。
- **退出手势无冲突设计**：展开状态下支持自然张开退出，解决与系统「显示桌面」的手势冲突；优化捏合手势防误触逻辑。
- **手势收尾平滑中断与动态接管**：解决上一轮手势收尾期间新手势被直接丢弃的问题，支持连续快速捏合与即时反向打断，操作不再漏接与迟钝。
- **睡眠唤醒自动恢复**：系统休眠唤醒后自动重新接管触控板与触发角手势监听，解决长时间待机后手势失效的问题。

### 🎬 动画过渡与视觉细节修复
- **彻底消除取消打开时的重亮闪烁**：深度修复手势中途反向取消时，在窗口隐藏前一瞬间内容被错误复位为 100% 亮度重绘的闪烁缺陷（覆盖飞入、经典、缩放、淡入淡出、无动画全部 5 种模式）。
- **自然动画节奏**：修复动画由于双重缓动被过度加速的问题，恢复原生丝滑过渡质感。
- **严格遵循用户偏好**：触控板进出动画严格遵循设置中选定的动画风格（飞入、经典、缩放、淡入淡出、无动画），消除默认强制飞入。
- **防重复触发**：修复捏合展开时极小概率重复触发两次动画的卡顿。

### 🔄 独立更新检查与界面体验
- **GitHub 直连更新检查**：本分支默认直连 GitHub Releases 检查新版本，内置后台静默检查与手动检测对话框，更新便捷无干扰。
- **关于页面重构**：GitHub 入口改用原生系统卡片与弹出菜单，支持快速访问原作者仓库与本仓库。

---

## 原作者的话

我很喜欢 Launchpad 满屏图标的感觉，macOS 遗弃 Launchpad 后我
就在寻找替代品，但试过一圈，始终没有找到真正满意的。

有些做得比较粗糙，有些塞进了太多功能，反而连 Launchpad 最基础的体验都没有做好。比如 LaunchNext 用起来太卡，LaunchOS 功能很丰富，但偶尔也会莫名卡顿，而且图标显示不够清晰。

所以我决定做一个流畅、图标显示清晰的 Launchpad ，功能要简单，效果要好。

这就是 QLaunch。

## 特性

- Metal 渲染
- 图标高画质显示
- 多种过渡动画样式（飞入、经典、缩放、淡入淡出、无动画）
- 拼音搜索
- 触控板多指原生手势与触发角呼出
- 文件夹支持

## 性能

QLaunch 追求设计师级别的最高画质图标显示效果和流畅的操作响应性，Display P3 16bit 的高精度图标也可以完美显示。考虑到画质优化会占用 3 倍以上的内存，我们提供了性能优先模式和低内存占用模式。

| 模式     | 😍 画质优先       | 😀 性能优先     | 🙂 低内存占用   |
| -------- | ----------------- | --------------- | --------------- |
| 图标纹理 | float16 4× 超采样 | RGBA8 2× 超采样 | RGBA8 2× 超采样 |
| 屏幕缓冲 | float16 ×3        | bgra8Unorm ×3   | bgra8Unorm ×2   |
| 文字图集 | 2048px float16    | 2048px RGBA8    | RGBA8           |
| 驻留     | 全部页            | 全部页          | 当前页 ±1       |

## 构建与开发

需要 Xcode、macOS 14+ SDK 与 Bun / Deno：

```sh
bun install
bun run dev               # 构建 Debug .app 并前台运行
bun run debug             # 构建 Debug .app 并用 Instruments 打开
bun run debug -- --record # 同上，并用 xctrace Time Profiler 直接录制
bun run build             # 构建 Release .app、DMG、ZIP（不发布）
bun run release           # 签名、公证，经 QRls 发布到 R2 与 GitHub
bun run clean             # 清理构建产物
bun run check             # 检查 Swift Package 结构
bun run layout:export     # 导出当前网格顺序 / 文件夹 / 隐藏列表为 JSON
bun run layout:import     # 导入布局 JSON（默认 merge；请先手动加 --dry-run --strict）
bun run layout:validate   # 校验布局 JSON（不扫描磁盘）
```

### 架构

```
AppDelegate          NSPanel 生命周期、热键、状态栏、手势分发、fade 展示
LaunchpadContainer   背景 + Metal 网格 + SwiftUI 覆盖层
DesktopBackground    CIGaussianBlur 壁纸
LaunchpadMetalView   图标 / 标签实例化绘制、DisplayLink 动画、翻页
AppStore             扫描结果、搜索、分页状态机、展示状态
Updater              GitHub Releases 自动更新检测与提醒
```

### 官网

产品官网在 `web/`，架构与 QCopy/web 一致（Vite + React + TypeScript，多语言 SEO，构建同步到 `docs/` 供 GitHub Pages）。

```sh
cd web
bun install
bun run dev               # 本地预览
bun run build             # 打包并同步到 ../docs（en + zh-Hans）
```

详见 [web/README.md](web/README.md)。
