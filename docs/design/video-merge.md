状态：P0/P1 已实现（PC + 移动端）。设计先于功能代码落地；原型见 `docs/design/prototypes/video-merge.html`。
2026-11-02 补充需求 6–8（导出可选追加或新片段、离线剧集内部合成、后台执行），功能设计 §1/§5/§6 与交付阶段已同步更新。
实现范围与差异见下文「本期实现记录」。

# 剧集合成：把多部已下载分集合并为一个影视资源

## 需求来源

用户希望有一个与下载平行的"合成"能力：

1. 能选择剧集（多部分集）进行合成；
2. 合成产物能导出到用户指定位置；
3. 合并后的资源能查阅它由哪些源分集合成（含顺序与状态）；
4. 已合成的资源能追加新的分集再合并；
5. 需要的库优先从 pub.dev 选型，不自带未审计的二进制；
6. 导出合成时可以选择在原基础上追加已有的合并，也可以导出为一个新的合成片段（文件）；
7. 已下载的离线剧集可直接在应用内（下载管理/本地剧集）选择进行合成并导出，不依赖网络详情；
8. 合成与导出这类耗时任务支持放到后台执行。

## 与现有下载体系的关系

合成完全构建在下载的产物之上，不新建第二套传输/解密链路：

- 输入 = `MediaCache` 已发布的解密产物 `<media-cache>/{vid}_{quality}.mp4`（`packages/api/lib/src/media_cache.dart`，tmp→校验→原子 rename 发布，未校验完成的文件不可作为合成输入）。
- 交互 = 复用 `showDownloadSelection()`（`packages/app/lib/downloads/download_selection.dart`）的多选面板骨架（Dialog/底部 Sheet 自适应、全选/清空、TV 走 `TvGrid`）。
- 调度 = 镜像 `DownloadManager` 的模式：`ChangeNotifier` + JSON 持久化 + 并发槽位 + 播放让位（`packages/app/lib/downloads/download_manager.dart`）。
- 产物 = 独立目录 `<app-support>/merged/`，不与 `{vid}_{quality}.mp4` 命名正则冲突（`media_cache.dart:651 _retainedPath` 约束）。

## 用户路径

详情/下载管理/本地剧集 → 合成 → 勾选已下载分集 → 预检（编解码/分辨率/画质一致性、磁盘空间）→ 命名与选择"新建或追加"→ 合成任务（可后台）→ 合并资源列表 → 播放 / 查阅构成 / 追加 / 导出（新片段或在原导出上追加，可后台）。

| Before | After | Why |
| --- | --- | --- |
| 只能逐集离线观看 | 一部剧可合成单个连续文件 | 便于投屏、拷贝到设备外播放 |
| 下载面板只能入队 | 面板新增"合成"动作，仅已下载集可选 | 合成输入必须完整，避免半成品 |
| 无合并产物概念 | "合并资源"独立列表 + manifest | 可追溯由哪些 vid/画质/顺序合成 |
| 产物只在应用目录 | 导出到用户选择的目录 | 交付到应用外仍是显式动作 |
| 一次合成定死 | 追加式合并（尾部快路径） | 追剧场景增量合成，不重做全量 |
| 合成入口只在详情页 | 下载管理/本地剧集可对已下整组直接发起合成 | 离线内容无需联网详情即可消费 |
| 导出只产出新文件 | 导出时可选"新的合成片段"或"在原导出基础上追加" | 交付形态跟随用途：归档 vs 增量更新 |
| 任务仅前台执行 | 合成/导出可放后台，离开应用不中断、重启可续 | 大文件合成被中断不可接受 |

## 功能设计

### 1. 选择剧集进行合成

- 入口：详情页"下载"旁新增描边"合成"次按钮；下载管理页与本地剧集页对已下载分集提供组级"合成"入口（离线路径见 §7）；合并资源页也提供入口。
- 面板逻辑同下载选择器，差异点：
  - 只有 `phase == complete` 且校验通过的集可勾选；未下载集置灰并标"未下载"（可提供"先下载"跳转，本期不做边下边合）。
  - 无画质下拉（合成跟随源文件已下载画质）；跨画质混选在预检阶段拦截。
  - 确认按钮为"合成 N 集"。
- 预检（客户端本地，不解码全片）：读取每部源 mp4 的 `trak/stsd`（复用 `Mp4Track` 解析），要求 video codec（avc1/hvc1 一致）、宽高一致、`timescale` 可归一；音频轨存在且 codec/采样率一致。任一不满足 → 提示"这 N 集编码参数不同，暂时无法无损合并"。

### 2. 合成任务与产物

- `MergeManager extends ChangeNotifier`（`packages/app/lib/merge/merge_manager.dart`），任务模型 `MergeJob { id, title, items:[{vid,index,quality,sourcePath}], targetMergeId?, phase, fraction }`，队列持久化到 `<app-support>/merge-tasks.json`（镜像 `episode-downloads.json` 的 tmp→rename 写法）。
- 并发固定 1（顺序写大文件，不与播放/下载抢 IO）；播放器活动占用时让位，沿用 `_slots` 思路。
- 写入流程：`merged/{mergeId}.mp4.<micros>.part` 流式拼接 → 重写 `moov` → 读回校验 box 表 → 原子 rename 发布 + 同写 manifest。失败只删 part，不动已有产物。
- 磁盘预检：`Σ源大小` 为下限估算，预留 5% 边距，不足直接失败并在任务卡说明。

### 3. 查阅合并构成（manifest）

`merged/{mergeId}.merge.json` 为唯一事实源：

```json
{
  "schemaVersion": 1,
  "mergeId": "m_20261102_xxxx",
  "title": "玫瑰深浅处 1-24集",
  "createdAt": "...", "updatedAt": "...",
  "codec": "hvc1", "width": 1080, "height": 1920,
  "items": [
    {
      "vid": "7xxxxxxxxxx", "index": 1, "episodeTitle": "第 1 集",
      "dramaId": "...", "quality": "1080p",
      "sourceFile": "media-cache/7xxx_1080p.mp4",
      "sourceSize": 123456789, "sourceSha": "...",
      "durationMs": 143000, "offsetMs": 0, "addedAt": "..."
    }
  ],
  "exports": [ { "path": "...", "at": "...", "mode": "new|append", "targetOf": "上一条导出记录", "status": "ok|missing" } ]
}
```

- UI：合并资源卡片 →"查看构成"弹出按序分集清单：集号、剧集名、画质、时长、在合成片中的起始偏移、源文件当前状态（存在/已失效）。源文件被删除不影响已合成产物，但清单如实标注"源已删除"。
- 追加历史与导出历史同样展示。

### 4. 追加合并

- 合并资源详情/列表提供"追加剧集"→ 复用同一选择面板，置灰已在 manifest 中的集。
- 校验：新集与 manifest 记录的 codec/宽高一致；对既有尾部做完整性校验（大小/sha 与 manifest 相符——sha 记录的是源文件而非产物，产物完整性靠发布时读回校验 + 可选后台抽检）。
- 快路径（本期实现）：MP4 常规产物 `moov` 在尾部时，删除尾部 `moov` → 追加新 `mdat` → 基于全量 sample 表写新 `moov`，无需重写既有视频数据；`offsetMs` 与时长在 manifest 增量累加。
- 若某源 mp4 是 `moov` 前置（faststart）形态，则退化为全量重写路径（同一实现，只是搬移既有 `mdat`）；两种路径产物均规范可读。

### 5. 导出到指定位置

- "导出"= 把合并 mp4（连同 manifest 的一份可读副本）复制到用户选择的目标；应用内 `merged/` 原件保留，导出不删除、不移动。
- PC（Windows/macOS）：`file_picker` 选择目录或保存路径，显示目标剩余空间；移动端/TV 无稳定任意目录写权限时用系统分享面板（`share_plus`），文案说明"通过系统分享保存到您选择的位置"。
- 导出进度复用任务卡；`exports[]` 记入 manifest，重复导出同路径提示覆盖确认。
- 导出目录选择记忆到 `AppSettings.mergeExportDir`（`packages/core/lib/src/config/app_settings.dart` 扩展），默认系统下载目录不可行——仍每次显式确认。

### 6. 导出的两种形态：新合成片段 / 在原基础上追加（补充需求 6）

导出合并资源时选择形态：

- **导出为新的合成片段（默认）**：在目标位置生成全新文件，不触碰既往导出物；适合归档、按档期命名。
- **在原基础上追加导出**：选择此前已导出的合并文件（`exports[]` 历史路径直接列出，或由用户选文件），把本次新增分集追加到该文件尾部。PC 上目标文件可读写时复用尾部快路径（删尾部 moov → 追加 mdat → 写新 moov）原地追加；移动端无稳定任意目录写权限，等价操作是"应用内追加剧集合并 → 将更新后的产物整体重新导出到原路径（覆盖确认）"，两种路径的文案与原型如实区分。
- 追加前对目标文件做同一预检（codec 参数、时长连续、`exports[]` 记录与目标大小/sha 相符）；失败不得损坏原文件——沿用 part→校验→原子替换约定，原地追加同样先写目标目录 `.part`，校验通过后替换。
- manifest `exports[]` 记录 `mode: new|append`、`targetOf`（追加基于哪条导出记录）与时间/状态。

### 7. 离线剧集的内部合成（补充需求 7）

- 合成消费的是"已下载且校验通过"的分集，整条链路不依赖网络：从下载管理页/本地剧集页进入合成面板时，剧目名、集号与封面取自 `LibraryCache` / `LocalDramaGroup`（`catalog/local_library.dart`），不在线拉详情；无网时面板正常打开，"拉取最新剧集"类在线动作禁用。
- 入口：下载管理页按剧归组的完成组提供组级"合成"动作（默认全选本组已完成集，可去选）；本地剧集页同；详情页入口保持。
- 未知 vid 的本地分集（`LocalDramaGroup` 的未知桶）可参与合成，构成清单如实标注"来源未知"；满足散装离线文件合并的需要。
- 预检、磁盘检查、合成、后台执行、导出在离线状态全部可用；仅源文件缺失（被清理）时提示先重新下载。

### 8. 后台执行合成与导出（补充需求 8）

- 执行离开 UI isolate：合成/导出 job 在专用 worker isolate 内运行（与 `FileDecryptor` 的 Isolate 模式同构），`MergeManager` 只经 SendPort 收进度事件渲染任务卡；关闭页面、切走 Tab 不影响执行。
- 状态续位：写入过程在 `<app-support>/merge-journal/` 记录字节 offset 检查点（对齐 `download-journal/` 的既有模式），队列持久化 `merge-tasks.json`；应用重启/进程被杀后 `reconcile`——journal 覆盖范围内续写，否则重做该 job，任何情况不产生半成品被当作完成产物（发布仍靠校验后原子 rename）。
- 平台策略如实区分：桌面（Win/mac）进程存活期间天然可后台写；Android 用前台服务通知（"正在合成 55%，点按回到任务"）避免系统挂起，复用既有 platform/background 通道；iOS 后台执行窗口受限，采用回前台续位 + `BGProcessingTask` 尽力调度，文案不承诺无限制后台；TV 仅前台。
- 并发与让位：合成与导出共享并发 1 的队列；下载带宽高峰或播放器占用时让位，条件恢复自动继续；后台任务可在"我的 → 合成任务"或系统通知里暂停/继续/取消，取消只删 part/journal，不动既有产物与目标原文件。

## 库选型（pub.dev）

| 方案 | 包 | 结论 |
| --- | --- | --- |
| A 纯 Dart MP4 拼接 | 无新依赖，复用 `packages/core/lib/src/media/mp4.dart`（`Mp4Track` offsets/sizes/encryption、box 解析） | **本期采用**。零原生二进制，避开 FFmpegKit 上游停更与本机 ARM64 无法构建 x64 原生的验证困境；前提是同编码参数无损拼接，预检保证 |
| B FFmpeg fork | [ffmpeg_kit_extended_flutter](https://pub.dev/packages/ffmpeg_kit_extended_flutter)（FFmpeg 9.x，六端）、[ffmpeg_kit_flutter_new](https://pub.dev/packages/ffmpeg_kit_flutter_new)（V2 embedding 维护 fork） | **二期兜底**：参数不一致时 `concat -c copy` 失败后的重编码合并。代价：原生二进制体积、各端构建链、验证成本 |
| C 轻量编辑插件 | [easy_video_editor](https://pub.dev/packages/easy_video_editor)（无 ffmpeg，Android/iOS merge） | 不采用：仅移动端、桌面端（本项目主战场）不覆盖，能力与黑盒不可审计 |
| 辅助 | [file_picker](https://pub.dev/packages/file_picker)（目录选择）、[share_plus](https://pub.dev/packages/share_plus)（系统分享） | 采用，均为成熟无原生视频链路依赖 |

明确排除：原 `ffmpeg_kit_flutter`（上游已停更且依赖已删除的二进制）。

## 平台布局

- 手机：合成选择底部 sheet；合并资源列表页 + 构成详情；导出走系统分享（追加形态=应用内追加后整体重导出）；Android 前台服务通知显示进度，点按回到任务页。
- PC/macOS：选择用居中 Dialog（复用 ≥720×400 分支）；合并资源页双栏（列表+构成）；导出用目录选择器，支持"新片段/在原导出上追加"两种形态；窗口关闭后进程存活期间任务继续，任务页与托盘/角标可见。
- TV：本期不接入——合成与导出入口由 `!tvBuild` 隐藏（用户范围为 PC 与移动端）；页面保留 TV 分支（浏览/播放/查看构成，不提供导出），待 P2 打开。
- Web/无本地媒体 runtime：隐藏合成与导出入口。

## 数据与代码落位

- `packages/core/lib/src/media/mp4_merger.dart`：`Mp4Merger.plan(List<MergeInput>)`（预检+sample 表归一）/ `execute(plan, sink)`（流式写 part）。纯 Dart，可在 Dart 测试套件直接验证（无需原生）。
- `packages/app/lib/merge/`：`merge_manager.dart`、`merge_worker.dart`（worker isolate：执行 job、写 `merge-journal/` 检查点、经 SendPort 上报进度）、`merged_library.dart`（`MergedVideo` 列表，监听 `merged/` 目录与 manifest）、`merge_selection.dart`（从 `download_selection.dart` 提取公共多选面板后衍生）。
- `packages/app/lib/features/merged_page.dart` 并入导航：`AppScreen` 枚举扩 `merged`（`navigation/app_navigation.dart`），"我的"页新增"合并资源"与"合成任务"入口（`features/my_page.dart`）；下载管理页/本地剧集页的组级"合成"动作复用 `DownloadsPage` / `LocalDramaGroup` 行卡（`features/downloads_page.dart`、`catalog/local_library.dart`）。
- 播放：`player_page` 已按路径播放本地文件，合并资源作为单条"虚拟剧集"进入 `local_library` 分组（独立 `merged` 组，不与逐集组混淆）。
- 删除联动：删除下载源文件不级联合成片；删除合并片仅清 `merged/` 下该 id 的两个文件并确认。
- 持久化文件新增：`merge-tasks.json`（队列）、`merge-journal/<jobId>.json`（字节检查点）、`merged/<mergeId>.merge.json`（manifest）。

## 交付阶段

- P0（已完成）：`Mp4Merger` 核心 + 单测；`MergeManager` 队列/持久化；选择面板"合成"动作；合并资源列表、查看构成、新建合成。
- P1（已完成，Android 前台服务通知除外，见实现记录差异 4）：离线入口（下载管理/本地剧集组级合成，纯本地数据驱动）；追加快路径；导出双形态（新片段 / 在原导出上追加）与 PC 目录选择、移动端分享；后台执行（worker isolate + `merge-journal` 续位 + reconcile + Android 前台服务通知）；磁盘预检与失败恢复。
- P2：方案 B 重编码兜底（参数不一致）；边下边合；TV 端合成；Android 合成前台服务通知；iOS `BGProcessingTask` 尽力调度；孤儿源提示与容量治理。

## 本期实现记录（P0/P1，PC + 移动端）

内核按方案 A 落地，链路全部纯 Dart，可在 Dart 套件直接验证：

- 拼接内核 `packages/core/lib/src/media/mp4_merger.dart`：预检（要求各源 `stsd` 条目字节一致——即 codec/宽高/音频参数同一，`timescale` 相同；`ctts` 有无混排直接拒绝，不做归一）→ 流式拼接 → sample 表偏移重映射（`stts/stss/ctts/stsz/stco`，`stsd` 沿用首部）→ 重写 `moov` → 读回校验。追加走尾部快路径（删尾部 `moov` → 追加 `mdat` → 基于全量 sample 表写新 `moov`），`moov` 前置的源退化为全量重写；两条路径产物都规范可读。
- 队列与产物 `packages/app/lib/merge/`：`merge_manager.dart`（`MergeTask` + `merge-tasks.json` 持久化 + 并发 1 + 让位 + `reconcile` 采纳已落盘产物）、`merge_worker.dart`（worker isolate + `merge-journal/` 字节检查点）、`merged_library.dart`（`merged/{id}.mp4` + `merged/{id}.merge.json` 唯一事实源）、`merge_selection.dart`（选择面板，Dialog/底部 sheet 自适应）、`merge_export.dart`（导出形态与目标选择）。
- UI 接入：详情页下载旁"合成"；本地缓存分组面板与单剧页"合成成本地资源"；下载管理页按剧组的"合成已下载的分集"；我的 → 合并资源 / 合成任务（`AppScreen.merged`/`mergeTasks`）。合并资源详情提供 播放 / 查看构成 / 追加剧集 / 导出 / 删除；导出在 PC 用目录选择器（`file_picker`），移动端用系统分享（`share_plus`），目标目录记忆到 `AppSettings.mergeExportDir`。
- 播放：合并产物作为单条整片资源进 `PlayerPage(cachedOnly: true, mergeId: ...)`；`NativeRuntime.prepareMerged` 直接把 `merged/{id}.mp4` 以 `file://` 交给播放器（产物不在 `media-cache` 命名规则内，不需要缓存文件那套取用—改名协议），文件已不在时给出"请重新合成"。产物不是目录剧集，故不写逐集观看历史——否则继续观看会给出无法续播的行。
- 让位与后台：`playbackEntered()/playbackLeft()` 与播放器生命周期配对，播放器占用时任务停在检查点、空闲后自动继续（`_blocked`）；桌面与移动端在进程存活期间持续写，TV 按前台策略退回后台即等待。进程被系统挂起或杀死由 `merge-journal/` 字节检查点接住：重启后 `reconcile()` 采纳已落盘产物，未完成的部分要么续写要么整体重做，发布始终靠校验后的原子 rename。任务卡按阶段给出 暂停/继续/取消，取消只删 part 与 journal，不动既有产物与目标原文件。

与设计文档的差异（如实记录，非缺陷清单）：

1. manifest 记录 `sourceSize` + `sourceModifiedMs`，不记 §3 的 `sourceSha`：追加前校验不必再整读一遍源文件，代价是对"同大小同修改时间的替换文件"不敏感。
2. §2 的"磁盘不足直接失败"实现为面板显示预计写入量（`Σ源大小 × 1.05`，`MergeManager.expectedBytes`），不做剩余空间硬失败——测剩余空间要新增跨端依赖。写满由写入自身报错并写进任务卡。§5 的"显示目标剩余空间"同样未做。
3. §7 的组级入口不默认全选本组完成集，改为列出后手动勾选：新建合成需 ≥2 集，追加剧集允许 1 集。
4. Android 前台服务通知、iOS `BGProcessingTask` 未接入本期：移动端进程被系统挂起时写入随进程停下，靠 `merge-journal` 检查点在回前台或重启后续写/重做，UI 文案不承诺无限制后台；"点通知回到任务"的可点按入口也未做（任务页仍在"我的 → 合成任务"）。与 §8 的差距记在 P2。
5. TV 不接入合成与导出（需求限定 PC + 移动端）：入口由 `!tvBuild` 隐藏，写文件动作不进 TV；`merged_page`/选择面板的 TV 分支保留但休眠，等 P2。
6. 任务模型命名 `MergeTask`（文档写作 `MergeJob`）。

## 验证

- Dart 测试（本机可跑）：构造两个小 mp4 fixture，`Mp4Merger` 拼接后读回断言 `mdat` 尺寸、`stsz/stco/stts/ctts/stss` 表正确、时长=各段之和；追加路径断言既有字节区间不变。
- 后台与续位：kill 后重启 `reconcile` 的 journal 覆盖/重做两条路径用假时钟单测覆盖（镜像 `download_manager_test.dart` 的 `download_fakes.dart` 模式）；导出追加失败不得损坏原目标文件（断言原字节完整）。
- 离线路径：无网假 runtime 下从下载管理页/本地剧集页打开合成面板并入队（`merge_ui_test.dart` 第 4 例断言目录详情请求失败也能开面板）；一次真实合成与导出的字节落盘由 `merge_manager_test.dart` 覆盖。
- 原生验证按既有路由：`packages/app/test/merge_ui_test.dart`；产物用 media_kit 实播在 Mac 与 x64 CI 上各验一次；Android 前台服务通知在真机验一次后台不被挂起。

本期实测（2026-11-04）：

- `packages/core`：132 例全绿，含 `mp4_merger_test.dart` 的拼接读回、追加区间不变、导出失败不损坏原文件。
- `packages/app`：`merge_manager_test.dart` 9 例（队列持久化、journal 续写、reconcile 采纳已落盘产物、播放器让位、删除不级联源文件）与 `merge_ui_test.dart` 5 例（我的两个入口、构成与导出记录、追加去重与入队、离线面板入队、任务卡按阶段给控件）全绿；`flutter analyze --no-pub lib test` 无告警。
- 全量回归：`packages/app` 整套 468 例通过、2 例跳过，失败仅 `tv_feed_test.dart` 3 例，报错帧在同期未提交的 TV 搜索框改写（`packages/app/lib/features/tv/tv_library_page.dart:487`、`:491`），与合成无关。
- UI 夹具的约束：`testWidgets` 的 fake-async 区域永不完成真实磁盘读，所以 `test/merge_fakes.dart` 用内存版合并库（`MergeMemoryLibrary`）承接列表与读写，视频与 manifest 仍以同步写入落在临时目录里供存在性检查；真实 `MergedLibrary` 的 IO 只在普通 `test()` 中跑。合成/导出的执行被"播放器占用"按住，UI 测试因此只看队列与控件，不看字节。
- 仍待验（本机不可做）：media_kit 实播合成产物（Mac 与 x64 CI，本机 ARM64 Windows 无法构建原生）；macOS 沙盒导出到用户目录需 `com.apple.security.files.user-selected.read-write`；Android 后台不被挂起（本期未接前台服务，见差异 4）。
