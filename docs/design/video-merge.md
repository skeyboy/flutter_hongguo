状态：P0/P1 已实现（PC + 移动端）。设计先于功能代码落地；原型见 `docs/design/prototypes/video-merge.html`。
2026-11-02 补充需求 6–8（导出可选追加或新片段、离线剧集内部合成、后台执行），功能设计 §1/§5/§6 与交付阶段已同步更新。
实现范围与差异见下文「本期实现记录」。
2026-11-05 归一与拆片已落地；同日补「二期设计：兼容合成（ffmpeg 转码轨）」——跨设备播不了的成因分类、画质优先的编码规则、依赖选型与验证路由成文。同日的 Dart 侧已实现（转码规格、ffmpeg 参数构造、队列的兼容道、面板的合成方式段与任务/产物文案，见「兼容合成实测（2026-11-05）」），未落的只剩原生绑定：接 `ffmpeg_kit_flutter_new` 让手机也有 ffmpeg，以及 CI 真跑一次 ffmpeg 参数数组。

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
  - 无画质下拉（合成跟随源文件已下载画质）；跨画质混选分辨率不同，预检按片拆开后再入队，不落单的集在面板说明原因。
  - 确认按钮两步：选择步"下一步 · 预检"，预检步"开始合成"，拆片后改说"合成 N 片"（见实现记录）。
- 预检（客户端本地，不解码全片）：读取每部源 mp4 的 `trak/stsd` 与 sample 表（复用 `Mp4Track` 解析），与写入同源。要求的是 `stsd` 条目一致（codec/宽高/音频参数同一）与轨道构成可配对；`timescale` 不同、轨道顺序相反、`ctts` 有无/版本差异都由内核归一，不再是拒因。真拒时先按兼容键分桶，把这次选择能拆成的片一并报出（`可拆成 N 片`），确认后一次排入 N 个任务；无一片可成时才提示"这 N 集编码参数不同，暂时无法无损合并"——设备上有转码器时，这句话下面附一条"改用兼容合成"的出路（见「二期设计：兼容合成」）。

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
| B FFmpeg fork | [ffmpeg_kit_flutter_new](https://pub.dev/packages/ffmpeg_kit_flutter_new)（V2 embedding 维护 fork，4.6.8 / 2026-11-03）、[ffmpeg_kit_extended_flutter](https://pub.dev/packages/ffmpeg_kit_extended_flutter)（FFmpeg 9.x，走 code_assets + build hooks） | **二期兜底**：跨设备播不了的 codec 差异，用重编码合并解决。选型与规则见「二期设计：兼容合成」——采用 `ffmpeg_kit_flutter_new`，extended 因构建期 hooks 与本机验证困境叠加而排除。代价：原生二进制体积、各端构建链、license 审计 |
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
- P2：方案 B 兼容合成（重编码轨）——Dart 侧本期已落地（规格、参数、队列兼容道、面板合成方式段），剩原生绑定：`ffmpeg_kit_flutter_new` 让手机端也有 ffmpeg、CI 用同一份参数数组真跑一遍。设计与判据见「二期设计：兼容合成」。边下边合；TV 端合成；Android 合成前台服务通知；iOS `BGProcessingTask` 尽力调度；孤儿源提示与容量治理。

## 二期设计：兼容合成（ffmpeg 转码轨）

状态：Dart 侧已实现（规格、参数构造、队列兼容道、面板合成方式段），原生 ffmpeg 尚未接入——桌面靠 PATH 上的 `ffmpeg` 可执行文件，手机端等 `ffmpeg_kit_flutter_new`。规则与判据即下文，实现与文档的偏差记在「兼容合成实测（2026-11-05）」。

需求：合并产物要能在别的手机上正常播。跨设备失败只有三类原因，本期只对第一类引转码：

1. 目标设备没有源分集的解码器——最典型是 HEVC/H.265 与 10-bit 面。这类差异改表解决不了，只能重编码成 H.264/8-bit。
2. 色彩标签：写入器有意把 `pasp/clap/colr/btrt` 排除在比对之外（`mp4_merger.dart` 的 `_cosmetic`），拼接产物的 `colr` 静默继承第一段。各段 `colr` 不同时，后几段在别的设备上可能偏色——无损轨无法补救（一条 `stsd` 表达不了两个色彩标签），转码轨逐帧重编码，能统一写一个。
3. `moov` 在尾部：只影响边下边播/HTTP 渐进播放，本地文件播放不受影响；纯 Dart 就能修（faststart 改写），与转码无关。

2、3 都不需要新依赖，只有 1 需要 ffmpeg——所以转码轨按显式 opt-in 设计，无损仍是默认。

### 两轨制

- 默认轨（已实现）：纯 Dart 的 `-c copy` 等价拼接，零画质损失、零新依赖、可在 Dart 套件字节级验证。
- 兼容轨（二期）：ffmpeg 解码 → 过滤 → 编码 → mux，用户在合成面板显式选"兼容模式（重编码）"，且只在该设备的转码器可用时这个选项才出现。
- 不做"无损失败自动降级到转码"：一次转码消耗 CPU、电量、时间并引入画质损失，静默降级等于让用户以为拿到的是无损产物。拒因文案直接指向兼容模式，点不点由用户决定。

### 画质优先的编码规则

保留画质优先 = 转码只解决"能不能解码"，不解决"省空间"：

- 分辨率不改：不加 `scale`、不套 720p 模板；源 1080×1920 就出 1080×1920，过滤链只做 `format=yuv420p` + `setsar=1`（+ 必要时 `fps` 归一）。
- 混合分辨率仍不并片：并成一片必须缩放，缩放就是画质损失，与本条冲突。跨画质混选继续走本期已实现的拆片，兼容轨不改动写入判据。
- 码率只升不降：视频目标码率取各段实测 `bit_rate`（`stsd`/`btrt`）按帧数加权后上浮，估不出来就用源文件字节数 ÷ 时长换算；不允许出现"合成完反而糊了"。OS/HW 编码器不吃 CRF，只能给 `-b:v`/`-maxrate`，这也是这条要写死的原因。
- 奇数宽高直接拒：编码器要求偶数，而 `scale=trunc(iw/2)*2` 属于改分辨率，不在画质优先的允许范围内。
- 帧率保持源帧率；VFR 由 `fps=` 归一到源的中位帧率——这是转码轨必需的归一，不是画质降级。
- 音频统一 AAC，码率不低于源；转码轨因此顺带解决"音频参数不一致"这类无损轨表达不了的拼接。

### 一遍做完：concat filter，不做"逐集转码再拼接"

一条命令里解码全部输入、只编一次、只写一个文件（纯 Dart 构造 `List<String>` 交给 runner，不经 shell）：

```
-i 1.mp4 -i 2.mp4
-filter_complex "[0:v]format=yuv420p,fps=<r>,setsar=1[v0];[1:v]…[v1];[v0][0:a][v1][1:a]concat=n=2:v=1:a=1[v][a]"
-map [v] -map [a]
-c:v <探测到的 h264 编码器> -b:v <≥源> -c:a aac -b:a <≥源>
-movflags +faststart out.mp4
```

不逐集转码再拼的理由：中间产物体积翻倍、画质损失发生两次、每个中间文件都要落盘校验与清理，续位逻辑要同时管 N 个中间态——而这些复杂度换来的只是"能复用现有无损拼接器"，不值得。

### 编码器按运行时探测选

- 输入侧：LGPL 构建仍带 in-tree 的 HEVC 软件解码（解码不受 GPL 约束），H.265 源读得动——这是"能不能转"的前提。
- 输出侧：探测 `-encoders` 后按平台优先级取第一个可用的 H.264 编码器：Android `h264_mediacodec` → iOS/macOS `h264_videotoolbox` → Windows `h264_mf`（再 `h264_nvenc`/`h264_amf`/`h264_qsv`）→ 全都没有才回退 `libx264`。
- `libx264`（CRF）不在 LGPL 构建里，属 GPL 变体：默认不引。只有探测不到任何 OS/HW 编码器、且用户接受 license 变化时才建议换 GPL 变体，届时同步补 license 说明（仓库已在 NOTICE.md 按 GPL-3.0 血统记录，根目录无 LICENSE）。
- 画质代价如实说：OS/HW 编码器同码率画质普遍略逊 x264，所以"画质优先"本期落地为"不低于源码率 + 不缩放 + 不降帧"，而不是"与 x264 CRF 同级"。

### 依赖选型

- 采用 `ffmpeg_kit_flutter_new` 4.6.8（2026-11-03 发布）：classic plugin 形态，平台覆盖 android/ios/macos/windows/linux，依赖只有 `platform_interface` + flutter，变体齐（`_video`/`_full`/`_gpl` 等）可按 license 与体积取舍。
- 排除 `ffmpeg_kit_extended_flutter` 1.0.0：FFmpeg 9.x 虽新，但走 `code_assets` + build hooks + ffigen，绑定在构建期生成——"本机 ARM64 编不了 x64 原生"的验证困境会叠加到每次 `pub get`，风险与收益不匹配。
- 上游背景：arthenica FFmpegKit 2025-01 停更，FFmpegKitNext 2026-07 起仅源码；故选维护 fork，并把"二进制来自第三方 fork"列入法务/审计待办。
- 代价：每端一份原生库（数十 MB 量级，Android 还要按 ABI 拆）。本期未引依赖，体积与构建链数字等 `pub get` + CI 出包后回填，不预先承诺。

### 队列、续位与 UI

- 代码落位 `packages/app/lib/merge/merge_transcode.dart`：`TranscodeSource`（一集的事实：路径、 coded 宽高、时长、各轨实测码率、milli-fps）与 `transcodeRejectOf`/`planTranscode`（画质优先的拒因与目标规格都在这里判，二者共用同一条规则），`ffmpegArgs` 把计划展开成 argument 数组，`MergeTranscoder` 是可注入的接缝——桌面 `FfmpegTranscoder` spawn PATH 上的 `ffmpeg`，手机 `UnavailableTranscoder` 直接说明没有。纯 Dart 构造与拒因全部单测，不经 shell。
- `MergeTask.mode`（`lossless` / `compatible`）是车道标记，`kind` 仍是 merge/append/export 三值不加 `'transcode'`：转码是同一件工作（合成一个新产物）的另一种做法，卡片标题按 mode 改说"兼容合成"，控件、让位与队列语义完全复用。manifest 同样记 `MergedVideo.mode`，产物详情与列表都据此标明是哪条道写的；实际编码器不落盘，读回时按产物的 `stsd` 现算。
- 无字节级续位：转码不是"复制 N 字节"，`merge-journal` 的 offset 检查点没有意义，中断即从头（暂停文案直说"继续时重新从头编码"）；进度用 ffmpeg 回报的 `out_time_ms`/`out_time_us`（都是微秒）÷ 总时长。取消与失败只删 `<product>.<job>.part`，删除在 Windows 上带重试——刚关闭的文件可能被扫毒或子进程瞬时占用，一个留在 `merged/` 的 part 是列表看不见的几 GB。
- 并发仍为 1、仍向播放器让位；转码更吃 CPU，让位的必要性只增不减。
- 发布前读回：产物用同一个 `probe` 再读一遍，断言 `codec ∈ {avc1, avc3}`、时长与计划相符（容差按段数给），不合规就不发布、任务失败——兼容合成不会拿出一个"以为能播其实播不了"的文件。执行前还把预检表重读一次再展开参数：确认到执行之间重新下载过的一集，由这条道自己发现，不靠面板当时的答案。
- 面板：合成方式段（无损合成 / 兼容合成），兼容只在 `MergeTranscoder.available` 为真时出现且默认不选，追加时整段消失（追加就地长文件，重编码做不到）；无损的拆片判据先跑，兼容轨把同一份预检表按编码器自己的规则再读一遍——`stsd` 只差 profile/level 的各集在无损是两片，在兼容是一片。无损整体被拒时，拒因下面给一条"改用兼容合成"。任务卡与产物详情按 mode 换文案与图标。

### 验证路由

1. 纯 Dart 本地：参数数组构造、画质优先的拒因（分辨率不同、奇数宽高）、mode 落盘与 manifest 往返，全部用注入的 fake transcoder，无需原生。
2. CI 真 ffmpeg：新增 job 安装 ffmpeg，用**同一份 Dart 产出的 argument 数组**对 `packages/core/test/fixtures/media/clear.mp4` 执行一遍，断言退出码 0、产物可读回、宽高与帧率未变——这条命令字符串第一次被执行，不依赖任何设备。
3. 原生编译：`build.yml` 的原生矩阵验 Android/iOS/macOS/Windows 依赖编得过（本机 ARM64 无法构建 x64，仍按 windows-verify 路由）。
4. 设备实播：HEVC 源 → H.264 产物，在未带 HEVC 解码的旧机实播一次；同一段在 Mac 与 x64 CI 各验一次；`colr` 是否偏色要肉眼比对，只能落在这一步。

未验边界（如实）：本机既不能构建原生也不能实播，前 3 步之外的结论一律等 CI 与真机；OS/HW 编码器的画质读数、每端体积增量、`ffmpeg_kit_flutter_new` 的 license 审计都还没取过。

## 本期实现记录（P0/P1，PC + 移动端）

内核按方案 A 落地，链路全部纯 Dart，可在 Dart 套件直接验证：

- 拼接内核 `packages/core/lib/src/media/mp4_merger.dart`：预检（要求各源 `stsd` 条目字节一致——即 codec/宽高/音频参数同一，且轨道构成可按 `hdlr` 配对；`timescale` 不同取精确 LCM 重标 `mdhd/stts/ctts/elst`，轨道顺序相反按 handler 配对，`ctts` 缺失补零游程、版本按偏移符号升到 v1，都不再是拒因。归一越出字段边界（乘积 > 2^32）才以"时间基差异过大"拒绝）→ 流式拼接 → sample 表偏移重映射（`stts/stss/ctts/stsz/stco`，`stsd` 沿用首部）→ 重写 `moov` → 读回校验。追加走尾部快路径（删尾部 `moov` → 追加 `mdat` → 基于全量 sample 表写新 `moov`），`moov` 前置的源退化为全量重写；两条路径产物都规范可读。
- 同一规则两处用：`Mp4Merger.rejectOf/growRejectOf` 是预检的判据，`MergeReject` 带 `code`（分辨率/编码参数/轨道构成/时间基）与 `position`，`compatibilityKeyOf` 由 `_compare` 实际比对的字段构成。预检的分桶键只是提示，每个候选片仍回头问一次写入本身的判据，所以面板不会承诺合成会反悔的结果。
- 队列与产物 `packages/app/lib/merge/`：`merge_manager.dart`（`MergeTask` + `merge-tasks.json` 持久化 + 并发 1 + 让位 + `reconcile` 采纳已落盘产物）、`merge_worker.dart`（worker isolate + `merge-journal/` 字节检查点）、`merged_library.dart`（`merged/{id}.mp4` + `merged/{id}.merge.json` 唯一事实源）、`merge_selection.dart`（选择面板，Dialog/底部 sheet 自适应）、`merge_export.dart`（导出形态与目标选择）。
- UI 接入：详情页下载旁"合成"；本地缓存分组面板与单剧页"合成成本地资源"；下载管理页按剧组的"合成已下载的分集"；我的 → 合并资源 / 合成任务（`AppScreen.merged`/`mergeTasks`）。合并资源详情提供 播放 / 查看构成 / 追加剧集 / 导出 / 删除；导出在 PC 用目录选择器（`file_picker`），移动端用系统分享（`share_plus`），目标目录记忆到 `AppSettings.mergeExportDir`。
- 预检与拆片：`merge_worker.dart` 的 `probeMerge` 在 worker isolate 里读表，除整体判据外返回 `batches`（按兼容键分桶、每桶再问一次 `rejectOf`）；`merge_selection.dart` 的预检步把可成的片逐条列出（`可拆成 N 片` / `可合成一片`），一次确认排入 N 个任务并按片命名（无名=各片自己的集数区间，有名=名称编号），落单的一集带着差异原因留在面板里不进队列。追加只有一次确认一个产物，不提供拆片。
- 播放：合并产物作为单条整片资源进 `PlayerPage(cachedOnly: true, mergeId: ...)`；`NativeRuntime.prepareMerged` 直接把 `merged/{id}.mp4` 以 `file://` 交给播放器（产物不在 `media-cache` 命名规则内，不需要缓存文件那套取用—改名协议），文件已不在时给出"请重新合成"。产物不是目录剧集，故不写逐集观看历史——否则继续观看会给出无法续播的行。
- 让位与后台：`playbackEntered()/playbackLeft()` 与播放器生命周期配对，播放器占用时任务停在检查点、空闲后自动继续（`_blocked`）；桌面与移动端在进程存活期间持续写，TV 按前台策略退回后台即等待。进程被系统挂起或杀死由 `merge-journal/` 字节检查点接住：重启后 `reconcile()` 采纳已落盘产物，未完成的部分要么续写要么整体重做，发布始终靠校验后的原子 rename。任务卡按阶段给出 暂停/继续/取消，取消只删 part 与 journal，不动既有产物与目标原文件。

与设计文档的差异（如实记录，非缺陷清单）：

1. manifest 记录 `sourceSize` + `sourceModifiedMs`，不记 §3 的 `sourceSha`：追加前校验不必再整读一遍源文件，代价是对"同大小同修改时间的替换文件"不敏感。
2. §2 的"磁盘不足直接失败"实现为面板显示预计写入量（`Σ源大小 × 1.05`，`MergeManager.expectedBytes`），不做剩余空间硬失败——测剩余空间要新增跨端依赖。写满由写入自身报错并写进任务卡。§5 的"显示目标剩余空间"同样未做。
3. §7 的组级入口不默认全选本组完成集，改为列出后手动勾选：新建合成需 ≥2 集，追加剧集允许 1 集。
4. Android 前台服务通知、iOS `BGProcessingTask` 未接入本期：移动端进程被系统挂起时写入随进程停下，靠 `merge-journal` 检查点在回前台或重启后续写/重做，UI 文案不承诺无限制后台；"点通知回到任务"的可点按入口也未做（任务页仍在"我的 → 合成任务"）。与 §8 的差距记在 P2。
5. TV 不接入合成与导出（需求限定 PC + 移动端）：入口由 `!tvBuild` 隐藏，写文件动作不进 TV；`merged_page`/选择面板的 TV 分支保留但休眠，等 P2。
6. 任务模型命名 `MergeTask`（文档写作 `MergeJob`）。
7. §1 的"任一不满足 → 提示无法无损合并"实现为两条路：能归一的差异（时间基/轨道顺序/`ctts`）不进拒绝列表，由内核改写表；不能归一的按兼容键分桶，面板把可成的片列出来、一次确认排入 N 个任务。只有没有任何一片成立时才回到"暂时无法无损合并"的一句话。落单的一集不合成——本地播放本来就按 `localPlaybackQueue` 连续播整部剧的离线集，本期不再做"合集"这个新对象。

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

## 归一与拆片实测（2026-11-05）

- `packages/core`：135 例全绿（`mp4_merger_test.dart` 10 例）。新增覆盖：时间基不同的两集从拒因改判为可合——LCM 精确重标 `mdhd/stts/ctts/elst`（`elst` 的 media_time 同步放大），读回时长=两段之和、样本字节逐条相等；无 `ctts` 的源补零游程，v0/v1 混排升到 v1 且偏移不变；`trak` 顺序相反按 handler 配对并交叉核对每条轨道的样本内容；只有乘积越出 2^32 才以 `code = timescale` 拒绝。分桶键与写入判据的一致性由一条断言钉住：四种可归一的编辑键相同且 `rejectOf` 为 null，两种真差异键不同且 `rejectOf` 非 null。
- `packages/app`：`merge_manager_test.dart` 11 例，走真实 `probeMerge` isolate——时间基不同的一集与孪生集预检放行并合成成功、产物读回时长=两段之和；`avcC` 差异的两集整体判拒且各自成单集桶（无可成片）；四集两格式预检成两片、按片入队后两片都落成 [1,2] / [3,4]，追加一次只有一个产物、不拆片。`merge_ui_test.dart` 10 例覆盖面板：`可拆成 2 片` 与两片区间、一次确认排两个任务并按名称编号、`可合成一片` 时落单的集带着原因留在面板不进队列（既有"任一不一致即拒绝"的例仍判 `编码参数不一致` + 按钮按下无效）。
- 全量回归：`packages/app` 整套 471 例通过、2 例跳过；`dart analyze packages` 仅余既有的两条 `library_private_types_in_public_api`（`core/lib/src/media/progressive_decrypt.dart:31`、`api/test/progressive_lane_test.dart:86`），与合成无关；`dart format` 已跑。
- 边界（未验，如实说明）：以上都是合成 fixture 与临时目录夹具上的字节级断言，证明的是"表改写后仍能读回、时长相加、样本字节不变、面板不会承诺写入会反悔的结果"，不是任何真实播放器对归一产物的实播观感；`elst` 重标后各端（media_kit / Android / iOS）的起始偏移表现仍未在真机或 x64 CI 取过读数。真实下载流里"同剧不同画质 / 不同参数集"的分布也未取样——拆片的触发频率、每片大小都未经真实内容验证。

## 兼容合成实测（2026-11-05）

- `packages/core`：136 例全绿（`mp4_merger_test.dart` 11 例）。为兼容轨补的读数落在 `MergeTrack.codedWidth/codedHeight`：只有 handler 为 `vide` 的轨道才从 sample entry（`avc1`）取编码尺寸，`tkhd` 的显示尺寸保持自己的含义——夹具正是 160×0 的显示尺寸配 160×288 的编码尺寸，测试钉住"改 hint 只动 `width/height`、音频轨的两个字段恒为 0"。分桶键没有为此变宽：编码尺寸本就在 `stsd` 里，所以尺寸不同的集在无损必然已经不同桶，兼容的组不会比无损的桶更宽。
- `packages/app` 的规则与参数：`merge_transcode_test.dart` 24 例，分五组。画质优先 8 例——共尺寸共码率放行、"不降级"（视频/音频码率与帧率只取各源的最高：3M+24fps 与 5.5M+29.97fps 出的是 5.5M/29.97）、分辨率不同判"分开合成"而不是缩放（句子带第几集与实际尺寸）、奇数边长直接拒（唯一的修法就是缩放，故拒绝）、静音集与有声集并片被拒而全静音放行（`a=0` 的图能表达）、单集不成片、测不出的轨退回整文件平均而不会落到 0、"面板的判据与轨自己的判据是同一条规则"由一例同时调用 `transcodeRejectOf` 与 `planTranscode` 并比对拒因文本钉住。参数数组 6 例——一次解码 → `concat` → 一次编码（滤镜图整串逐字断言、`-map [v]/[a]`、`-c:v` 用平台编码器、`-b:v` 是承诺的平均、`-maxrate/-bufsize` 是 1.5×/3× 的 VBV 窗口、`-movflags +faststart`、首尾元素）、不经 shell（带空格、反斜杠与 `" && del *` 的路径原样成一个数组元素）、全静音不写 `-c:a` 也不写 `[a]`、fps 未知时滤镜串里不含 `fps=`、`fpsLabel` 出 "30"/"29.97"/"23.976"、写盘预估跟着承诺码率走。编码器探测 3 例（只吃 `(codec ` 的编码行、跳过 legend、平台硬编优先而软件 `libx264` 兜底、一个 H.264 编码器都没有时兼容道不出现）。runner 6 例（探测回答前 `available` 为假、没有 ffmpeg 的机器说明原因、`out_time_ms`/`out_time_us`/`out_time=` 三种进度都换算成毫秒且不越过总时长、非零退出把 ffmpeg 最后一行带进任务卡、`stop` 杀进程、未实现的轨拒绝而不是假装）。最后 1 例走 `toJson`/`fromJson` 往返，断言计划要用的每条事实（各轨码率、milli-fps、宽高、字节数）都能越过 isolate 的边界，兼容轨不必为了补一个数字再读一次文件。
- `packages/app` 的队列道：`merge_manager_test.dart` 17 例，其中 `兼容合成` 组 6 例走注入的 `FakeTranscoder`——它把命令里 `-i` 点名的各集用真实的 `executeMerge` 写进命令最后一个参数命名的 part，所以队列的读回校验对着的是真表而不是空壳。测到的是：一遍编完（`runs` 只有一条，理由写"不逐集转码再拼接"）、数组带 `-c:v libx264` 与 `-movflags +faststart` 和 `concat=n=2`、进度按总时长的毫秒上报、发布仍是队列自己的 rename、manifest 记 `mode: compatible` 与读回的 `avc1`、各集的偏移等于前一段时长、part 发布后不存在、兼容作业不产生 journal（无字节续位）；另有 mode 随重启读回且已完成的编码不重跑、拒绝在既有产物上追加（"不能追加"且一条命令都没发出去）、设备没有 ffmpeg 时 `enqueue` 在入队前就抛"无法执行兼容合成…ffmpeg"且任务表为空、编码器没写出文件时任务失败说"读不回来"且不留产物、取消把 part 删掉。两支判据有代码但没被构造出来：读回不是 `avc1/avc3`、以及时长超出 `_durationSlack` 而拒绝发布——本轮的假车道每次都写出合规文件，这两条要么补畸形产物夹具，要么等 §验证路由 第 2 步的真 ffmpeg 撞上才看得见。
- UI：`merge_ui_test.dart` 14 例（10 → 14，靠 `MergeUiTranscoder` 让轨"可用"，本机不需要 ffmpeg）。有转码器的设备：面板出现"合成方式"段且默认无损；切到兼容把同一次预检的表按编码器规则再读一遍，无损判成两片（[1,2] 与 [3]）的同一选择读成"重编码可合成一片"，页脚写"将排入 1 片 · 3 集 · 产物约 …"与"源文件合计 3.0 MB"，确认后落成一个 `mode: 'compatible'`、集号 [1,2,3] 的任务，任务卡标题是"兼容合成 · 山海之间 合集"；切回无损仍是两片、页脚回到"2 集"。无损整体被拒时拒因下面附"改用兼容合成"，按下只把 `mode` 换掉（`_setMode` 只做 setState），同一份预检表换一条规则再读一遍，不再探一次盘。没有 ffmpeg 的设备只有一条路（无"合成方式"段、无出路按钮）。追加时整段消失但预检照常——重编码不能就地长文件。合并资源列表的副标题带"· 兼容合成 ·"，详情"方式"行写明"兼容合成 · 重编码为 H.264，其他设备也能播"，与无损的"直接搬运源文件字节"分列，产物不会被认为是没损的。
- 全量回归：`packages/app` 整套 505 例通过、2 例跳过；`packages/core` 136 例；`dart analyze lib test`（app）无告警，`dart analyze packages` 仅余既有的两条 `library_private_types_in_public_api`（`core/lib/src/media/progressive_decrypt.dart:31`、`api/test/progressive_lane_test.dart:86`），与合成无关；`dart format` 已跑，本轮触及的 14 个文件 0 处待改。跑的是 `git archive HEAD` 展开的临时树加上本轮合成文件，不含同期未提交的 TV 搜索框改写（那批评测在 2026-11-04 记录里拖红过 `tv_feed_test.dart`）。
- 边界（未验，如实说明）：本机是 ARM64 Windows 且没有 ffmpeg，上面全部跑在 `FakeTranscoder` / `MergeUiTranscoder` 与合成 fixture 上。那份 `ffmpegArgs` 数组从未被真实 ffmpeg 执行过一次——OS/HW 编码器（`h264_mf` / `h264_videotoolbox` / `h264_mediacodec`）的画质、耗时、是否吃 `-b:v/-maxrate/-bufsize` 的 VBV 约束都没有读数；产物没有在任何真机上播过，"换到其他手机也能播"目前是 `+faststart` + H.264/AAC + 编码尺寸规则推出的设计承诺，不是测得的事实。`format=yuv420p` 会把 10-bit 源压成 8-bit，这是兼容道自认的唯一损失，是否可见要等 §验证路由 第 4 步的肉眼比对；`colr` 是否偏色同理。手机端仍未接 `ffmpeg_kit_flutter_new`：`packages/app/lib/platform/runtime_native.dart:212` 在非桌面平台给的是 `UnavailableTranscoder`，所以移动端目前只有无损一道。剩下的原生步骤按 §验证路由 排队——CI 用同一份参数数组对 `packages/core/test/fixtures/media/clear.mp4` 真跑一遍并读回断言、各 ABI 的体积增量、以及 `ffmpeg_kit_flutter_new` 的 license 审计。
