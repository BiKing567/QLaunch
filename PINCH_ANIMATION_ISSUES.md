# 捏合动画问题说明：五种模式

- 记录日期：2026-10-11
- 审查版本：`2d5fcb58da26e0b6d04d637b60a34e7e8928f236`
- 工程：`/Users/manfred/code/projects/Qlaunch`
- 状态：问题已记录，未实施产品修复；本次只新增本文档。

## 1. 结论

问题不只在经典模式。五种模式共用的交互收尾存在同一个状态错误：取消打开并归零后，窗口尚未隐藏，渲染器却提前解除交互保护，随后把本应透明的内容恢复为不透明。

五种模式的可见程度不同：经典、淡入淡出、无动画的普通图标透明度链允许重亮；飞入、缩放的独立入场透明度在普通网格中遮住了这次错误。后两种不能因此视为完全安全。

此外，五种模式都存在收尾期间漏接新手势的源码路径。它与归零重亮是两件事，需要分别处理。

证据分级：共同状态错误和透明度输出已通过当前源码片段的可执行回放确认；手势漏接来自源码调用链；真实触控板、GPU 屏幕画面及完整文件夹／搜索切换尚未完成视觉验收。

## 2. 各模式的问题

下表对应相同输入：部分打开到进度 0.20，反向后取消至 0，在异步隐藏回调执行前检查收尾帧。采用普通分页 6×4 网格，遍历 24 个图标。

| 模式 | 归零时共用 gridAlpha | 普通图标透明度上界 | 问题表现与判断 |
|---|---:|---:|---|
| 飞入 Fly | 1 | 0 | 共用状态已错误重亮，但图标自身入场透明度为 0，普通网格没有同款图标重亮输出。若独立图标运动被禁用，遮挡可能失效。 |
| 经典 Classic | 1 | 1 | 原本应透明的内容重新允许完整亮度，并把整体缩放复位为 1，可能表现为隐藏前整组静止图标闪一下。与用户报告最吻合。 |
| 缩放 Zoom | 1 | 0 | 共用状态已错误重亮，整体缩放也被复位；径向入场透明度为 0，普通网格遮住图标重亮。若独立图标运动被禁用，遮挡可能失效。 |
| 淡入淡出 Fade | 1 | 1 | 没有独立入场透明度抵消，归零后重新允许亮图标，破坏淡出至隐藏的连续性。 |
| 无动画 None | 1 | 1 | 即使选择无动画，交互取消仍经过共用收尾；归零时恢复不透明，可能在隐藏前重新亮一下。 |

“普通图标透明度上界”计算为 `gridAlpha × entrance.opacity × zoom.opacity`，未计入页面边缘、懒加载揭示及其他不大于 1 的倍率。上界为 0 表示该普通图标被透明度阻断；上界为 1 只表示透明度链允许重亮，不保证纹理已驻留或该帧实际显示到屏幕。

## 3. 问题 A：取消打开归零后，隐藏前被错误重亮

严重程度：P2。影响范围：五种模式的共用状态；普通网格中三种模式允许亮图标输出。

### 触发条件

1. 用捏合开始打开 Launchpad，进入 `presenting` 状态。
2. 尚未完成打开就反向，松手时未达到提交条件，或收到取消事件。
3. 进入 `finishInteractivePresentation(to: 0)`。
4. 收尾到达 0，但异步完成回调还没有执行，窗口仍可见。

### 原因与时序

1. [AppDelegate.swift:652](/Users/manfred/code/projects/Qlaunch/Sources/QLaunchpad/AppDelegate.swift:652) 开始交互打开，store 进入 `presenting`。
2. [AppDelegate.swift:678](/Users/manfred/code/projects/Qlaunch/Sources/QLaunchpad/AppDelegate.swift:678) 启动到 0 的收尾动画；真正隐藏要等完成回调。
3. [MetalRenderer.swift:3117](/Users/manfred/code/projects/Qlaunch/Sources/QLaunchpad/MetalRenderer.swift:3117) 收尾结束，先清除动画标志；[3124](/Users/manfred/code/projects/Qlaunch/Sources/QLaunchpad/MetalRenderer.swift:3124) 又在目标为 0 时提前清除 `isInteractivePresentationActive`。
4. [MetalRenderer.swift:3139](/Users/manfred/code/projects/Qlaunch/Sources/QLaunchpad/MetalRenderer.swift:3139) 用主队列异步调用完成回调。此时窗口还没有隐藏，store 仍是 `presenting`。
5. 同一次绘制内，[MetalRenderer.swift:3155](/Users/manfred/code/projects/Qlaunch/Sources/QLaunchpad/MetalRenderer.swift:3155) 的零透明度补救逻辑只排除 `dismissing`，没有排除“取消打开、等待隐藏”的 `presenting`。它将 `contentAlpha` 改成 1、`contentScale` 改成 1、`contentOffsetY` 改成 0。
6. 随后才由 [AppDelegate.swift:856](/Users/manfred/code/projects/Qlaunch/Sources/QLaunchpad/AppDelegate.swift:856) 完成隐藏并标记 `hidden`。

因此，问题不是完成回调丢失，而是“归零”与“实际隐藏”之间的帧状态错误。Classic、Fade、None 没有第二层入场透明度抵消；Fly、Zoom 在普通网格中恰好被第二层透明度遮住。

### 经典模式的关键数值

| 时刻 | 进度 | 原逻辑 gridAlpha | 临时因果对照 gridAlpha |
|---|---:|---:|---:|
| 收尾 0.072 秒 | 0.0128 | 0.0128 | 0.0128 |
| 收尾 0.120 秒 | 0 | 1.0000 | 0.0000 |
| 执行完成回调后 | 0 | 窗口隐藏，回调一次 | 窗口隐藏，回调一次 |

原逻辑归零时缩放为 1；对照仍为 1.12，但完全透明。归零取样时回调尚未执行、窗口仍可见。

正常关闭路径先进入 `dismissing`，不会触发该补救分支；正常打开到 1 不存在归零重亮。这两项是路径对照，不是完整功能验收。

## 4. 问题 B：收尾期间新手势被丢弃

影响范围：五种模式。证据状态：源码确认存在丢弃路径，未完成真实设备连续输入验证。

[AppDelegate.swift:335](/Users/manfred/code/projects/Qlaunch/Sources/QLaunchpad/AppDelegate.swift:335) 在 `isAnimating` 为 true 时直接丢弃交互事件。[678](/Users/manfred/code/projects/Qlaunch/Sources/QLaunchpad/AppDelegate.swift:678) 开始收尾时清除打开／关闭交互标志，并设置 `isAnimating = true`；完成回调才解除门禁。

如果新一轮捏合的 `began` 发生在收尾期间，它会被丢弃。即使后续 `changed` 到达时动画已经结束，[347](/Users/manfred/code/projects/Qlaunch/Sources/QLaunchpad/AppDelegate.swift:347) 仍要求对应交互标志为 true，不能靠变化事件自动补建这轮交互。

这会造成快速连续捏合或反向后的漏接、迟钝；不是问题 A 的必要原因，也不能靠修复透明度恢复顺带消除。当前收尾时长最少为 0.12 秒，即便距离已经为 0，也存在这段门禁窗口。

## 5. 条件性风险与尚未确认的线索

### 飞入／缩放的透明度遮挡可能失效

在 `viewTransitionActive` 条件下，绘制路径会把独立缩放和入场运动的透明度替换为 1，见 [MetalRenderer.swift:3714](/Users/manfred/code/projects/Qlaunch/Sources/QLaunchpad/MetalRenderer.swift:3714) 和 [3743](/Users/manfred/code/projects/Qlaunch/Sources/QLaunchpad/MetalRenderer.swift:3743)。`suppressPerIconMotion` 也会使该条件成立。

条件数值对照中，这时 Fly／Zoom 的图标透明度上界也变成 1，普通网格原有的遮挡不再成立。但真实文件夹／搜索切换还有额外透明度、时序和状态，不能把这一条件上界写成已经实测的界面闪烁。

### 新帧到达前显示旧画面的风险

[LaunchpadUI.swift:428](/Users/manfred/code/projects/Qlaunch/Sources/QLaunchpad/LaunchpadUI.swift:428) 的 `prepareForInteractiveShow` 在新 GPU 帧到达前把 Metal 视图设为可见，存在旧 drawable 短暂暴露的时序风险。本次没有取得旧画面观测，不列为已确认根因。

### 不应混入本问题的旧缺陷

当前 `applyInteractivePresentationProgress` 已在交互收尾时保留动画推进，见 [MetalRenderer.swift:1515](/Users/manfred/code/projects/Qlaunch/Sources/QLaunchpad/MetalRenderer.swift:1515)。本问题不是此前“收尾停在第一帧”的旧缺陷。

同一手势反向本身只回退进度；有效接触数仍至少为三时，当前重定基准计算保持进度连续。尚未发现这两项必然制造本次归零重亮，不能把它们写成已确认原因。

## 6. 已执行的验证与结果

使用当前源码片段、实际 `ClassicPresentationTransform`、`iconEntrance` 和 `iconZoom` 方法编译执行；窗口和资源等依赖使用无副作用替身，完成回调保留真实主队列异步调度。

| 回放 | 共用状态错误 | 普通网格允许重亮 | 退出码 |
|---|---:|---:|---:|
| 原逻辑 | 5/5 | 3/5 | 1 |
| 临时单变量对照 | 0/5 | 0/5 | 0 |
| 再次原逻辑 | 5/5 | 3/5 | 1 |

临时对照仅改变一处语义：目标为 0 时不提前解除交互保护，目标为 1 时保持原行为。结果形成失败→通过→再次失败的因果对照；各模式完成回调仍执行一次，最终窗口隐藏。

该对照没有应用到工程源码，不是生产修复，也不代表完整功能测试通过。

## 7. 建议修复范围

### 对问题 A

修复共用交互收尾／待隐藏状态，不要只修改 Classic 分支。

取消打开至 0 时，交互显示保护应持续到窗口真正隐藏，再统一清理；或者让零透明度补救分支明确排除这类待隐藏状态。需要核对 `hideImmediately`、状态重置和完成回调的清理顺序，不能只保留标志却不安排最终清理。

不要无差别删除零透明度补救逻辑；其它正常显示路径仍可能依赖它。

### 对问题 B

为收尾期间的新手势明确选择输入策略：允许中断并接管当前进度，或保留足够的起始状态供收尾后接续。不能仅删掉 `isAnimating` 门禁，因为旧完成回调、交互标志和 generation 仍需一起处理。

旧动画不能覆盖新交互状态；取消、接管和完成路径应各自清理一次。具体策略属于实现设计，本文未实施或验证该方案。

## 8. 修复后的验收条件

以下均为待验收项目，不是本次已通过结果。

- 五种模式分别检查：正常打开、正常关闭、部分打开后反向取消、进度已到 0 再释放、Escape 中断。
- 从归零到窗口实际隐藏之间，内容透明度持续为 0，不得被补救显示逻辑恢复为 1。
- 快速重复捏合、连续开关、在收尾期间发起相反方向新手势，不能因为起始事件被丢弃而漏接整轮交互。
- 取消／接管后，旧完成回调不能隐藏新打开的窗口或覆盖新状态；完成与清理不得重复执行。
- Fly／Zoom 增加文件夹、搜索或禁用独立图标运动的组合检查，不能只验普通网格。
- 取得真实触控板输入及实际 AppKit／Metal 画面的验证；数值回放通过不等于视觉验收通过。

## 9. 证据与适用边界

本文结论绑定上述完整 SHA，创建文档前工作树干净。本次整理没有重跑完整项目测试、没有修改源码或偏好、没有启动或替换安装包。现有回放不能证明用户安装包恰好对应这个 SHA，也没有验证所有纹理驻留、真实 GPU 显示时序或所有过渡组合。

工程内源码位置以当前版本行号为准，后续提交变更后应重新核对。以下详细报告与原始输出保留在工程外，本文已包含核心结论和数值：

- [五模式详细对照](/Users/manfred/.codex/visualizations/2026/09/11/01a08e9b-bb42-7053-96a4-859a69170cd9/qlaunch-pinch-modes-2026-10-11.md)
- [五模式原始输出](/Users/manfred/.codex/visualizations/2026/09/11/01a08e9b-bb42-7053-96a4-859a69170cd9/qlaunch-pinch-modes-evidence-2026-10-11/mode-results.txt)
- [五模式原逻辑回放](/Users/manfred/.codex/visualizations/2026/09/11/01a08e9b-bb42-7053-96a4-859a69170cd9/qlaunch-pinch-modes-evidence-2026-10-11/mode-repro.swift)
- [五模式临时对照](/Users/manfred/.codex/visualizations/2026/09/11/01a08e9b-bb42-7053-96a4-859a69170cd9/qlaunch-pinch-modes-evidence-2026-10-11/mode-control.swift)
- [经典模式详细因果报告](/Users/manfred/.codex/visualizations/2026/09/11/01a08e9b-bb42-7053-96a4-859a69170cd9/qlaunch-classic-pinch-flicker-2026-10-11.md)
- [经典模式原始输出](/Users/manfred/.codex/visualizations/2026/09/11/01a08e9b-bb42-7053-96a4-859a69170cd9/qlaunch-classic-pinch-flicker-evidence-2026-10-11/replay-results.txt)
