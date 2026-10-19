# Flutter / Dart 跨平台移植可行性评估

日期：2026-10-19。基于当前包源码与 Dart/Flutter、候选依赖官方文档。已按第 6 节创建 Dart 核心与 Flutter 工程，并完成算法对拍、macOS release 合成媒体播放及上游单集准备；跨平台真机性能仍待实测。实施范围与证据见 [Dart / Flutter 核心移植与验收](Dart-Flutter-implementation.md)。

## 1. 结论与方案选择

可将业务、六头签名、URL 解码、spade v1、MP4 样本解密与缓存移植到 Dart，在 Flutter 实现 Android、iOS、macOS、Windows、Linux App。已有核心为公开可读 JS 逻辑，无必须调用 Node/unidbg 才能完成的算法。

不能原样翻译后保证可用。需要重写 Node API、校准整数/编码语义、适配文件和播放器，移动端替换 ffmpeg 子进程。上游签名/接口的实时可用性与编程语言无关，迁移不会消除现有协议失效或 spade v2 不支持问题。

| 方案 | 适用场景 | 判断 |
|---|---|---|
| Flutter UI + 现有远程 Node API | 先验证交互和播放器、快速覆盖平台 | 最短验证路线；客户端不独立，服务承担取址/解密和流量 |
| Flutter 原生 App + 本地 Dart 核心 | 希望安装后独立使用、无 Node 和业务服务器 | 原生五端的建议目标；核心移植成本较高 |
| Flutter 原生本地核心 + Web 远程 API | 同时覆盖原生与浏览器 | 推荐的完整产品架构，统一 UI/业务接口，区分媒体后端 |
| Flutter 内嵌 Node/JS 运行时 | 试图复用原 JS | 不作为首选：增加运行时、包体和平台适配；普通 JS 引擎并不提供 Node crypto/fs/child_process |

原生 App 不必保留本地 HTTP server：Dart service 可直接返回解密后的文件，播放器打开本地文件。只有需要 URL/Range 型数据源或逐步兼容旧 UI 时才增加 loopback server。

## 2. 源码迁移映射

| 当前模块 | Dart 对应 | 难度与注意点 |
|---|---|---|
| util/json/http、Client 数据解析 | dart:convert、HTTP transport、强类型 DTO | 中；保留 ID 字符串、上游空值/对象或 JSON 字符串兼容 |
| Client 分页与缓存 | Repository、Future、Map/队列 | 中；不能复制已发现的 seen 空值和分页标记问题 |
| device/keystore | 平台应用目录、设备身份存储、配置服务 | 低至中；单用户独立 App 通常不需要本地多租户 API Key 管理 |
| pure-sign.js（916 行） | Uint8List、ByteData、显式 u32/i32、BigInt、摘要实现 | 高；最先验证的阻塞点 |
| app-source.js | SignedTransport、候选排序、URL decoder | 中；保持 query/body 最终字节与签名一致 |
| spade.js（144 行） | Uint8List、XOR、popcount、边界检查 | 低至中；可复用 5 组已有真值 |
| mp4.js（1247 行） | MP4 parser、RandomAccessFile、样本 AES-CTR、盒重建 | 高；不能只做 AES 而跳过容器索引/IV/减壳 |
| stream.js（690 行） | DownloadManager、DecryptWorker、CacheStore | 高；改为真正流式写盘，支持取消、完成状态、并发去重 |
| ffmpeg spawn | 优先纯 Dart 减壳；必要时原生插件/FFI/服务端 | 平台适配高；不假定手机可执行 PATH 中的 ffmpeg |
| web/app.js（1746 行） | Flutter 页面、状态与播放器控制器 | 中；UI 重建，不是转换 DOM 代码 |

## 3. 签名移植的正确性要求

1. 32 位操作：JS `|0` 表示有符号截断，`>>>0` 表示无符号视图。Dart 用具名 i32/u32 辅助函数和显式掩码实现，尤其关注乘法中间值、算术/逻辑右移与轮转。
2. 64 位操作：对应 JS BigInt 的路径使用 Dart BigInt，并在相同位置约束到 64 位。不要假设 Dart int 溢出与 JS BigInt.asUintN 自动相同。
3. query：直接构造最终有序编码字符串，明确 `%XX`、空格、`*` 等行为。通用 Uri/queryParameters 工具不能未经对拍就用于签名串归一化。
4. body：JSON 只序列化一次，签名和 HTTP 发送复用同一 Uint8List。注意空 body 使用零摘要的代码分支。
5. protobuf：移植现有 varint/zigzag/wire type 字节规则；不必接入 protobuf 框架，但必须对齐字节。
6. SM3、MD5、SHA512 与标准 AES 可使用成熟实现；`AesV3`、hashF13、xmxor、Gorgon/Helios 变体仍需自行移植。PointyCastle 的普通 AES 不能替代 AesV3。
7. 测试注入时钟、随机源、进程 nonce/启动时间。原签名随机性较强，只有固定全部非确定输入后才能逐字节对拍。
8. branch=0/2、URL 编码、非 ASCII、空 body、32 位高位与进位边界需要覆盖；branch=1 仍要验证其本地分支识别逻辑。

Dart Web 的整数表示与原生有区别，跨平台数值逻辑不能依赖原生 int 行为；ID 继续使用字符串。[Dart 数值表示](https://dart.dev/resources/language/number-representation)。

## 4. 视频解密与播放器

建议原生流程：

```text
选集 → 解析 vid → Dart 签名取模型 → fallback → URL 解码/选流
→ 流式下载到加密临时文件
→ 工作 isolate 解析 moov / 解 spade / 验证 key 与 IV
→ 逐样本 CTR 解密到工作文件 / 减壳
→ 成品验证 / 原子发布到缓存
→ 播放器打开本地文件
→ 按预算预热下一集
```

### 4.1 性能与状态

- UI isolate 只处理展示与调度；大文件解析/纯 Dart AES 放 worker isolate。是否需要 native AES/FFI，依据 release 构建在实际手机上的吞吐和功耗测试决定。
- worker 接收文件路径和任务参数，避免反复复制整段 MP4。下载必须流式写盘，不复刻当前 Http.send 全文件 Buffer 聚合。
- 先保持完整下载后播放的正确链路；边下边播是另一个项目，需要 Range、moov 可得性、样本索引、CTR 起始状态与播放器数据源设计，不能承诺由换播放器自动获得。
- 状态明确区分 downloading/decrypting/remuxing/ready/failed/cancelled；只让完成成品进入缓存，失败 raw 不当成 ready。
- 移动端从 1 个媒体准备任务 + 至多 1 个下一集预热起步；并发预算根据实测调节，不照搬服务端 4 并发。
- 暂停、退出页面、切换清晰度时取消旧任务，避免旧结果覆盖新播放请求。

Flutter 官方说明 isolate 可避免 CPU 工作阻塞 UI；Web compute 不提供相同的后台 isolate 执行行为。[并发与 isolates](https://docs.flutter.dev/perf/isolates)。

### 4.2 播放器候选

- 覆盖原生五端可先验证 media_kit。包文档列出 Android/iOS/macOS/Windows/Linux/Web 视频支持；仍需分别验收具体编码、硬解、字幕、音轨、前后台行为与打包依赖。[media_kit](https://pub.dev/packages/media_kit)。
- 官方 video_player 当前列出 Android、iOS、macOS、Web；若要求 Windows/Linux，不能仅依赖它的官方默认实现，需要额外平台实现或统一播放器方案。[video_player](https://pub.dev/packages/video_player)。
- 优先选择上游 H.264；HEVC 是否可播由目标系统/硬件/播放器构建决定。播放器“支持跨平台”不表示全部编码在所有设备上均可用。
- 默认纯 Dart 减壳，不能把现有 ffmpeg 命令直接作为移动端回退。桌面可独立适配 ffmpeg；移动端若确需转码，需要明确引入原生库或服务端能力，否则返回清晰的格式不支持错误。

## 5. 各平台边界

| 平台 | 本地 Dart 业务/解密 | 额外工作 |
|---|---|---|
| Android | 可行 | 应用目录、网络权限、前后台任务生命周期、播放器硬解与存储导出 |
| iOS | 可行 | 沙盒路径、网络配置、前后台限制、音视频会话与真机性能；无 Node/ffmpeg 子进程依赖 |
| macOS | 可行 | 网络/文件权限与应用目录、播放器原生依赖和签名打包 |
| Windows | 可行 | 播放器平台实现、路径处理、原生依赖分发 |
| Linux | 可行 | 播放器及系统库依赖、桌面打包、GPU/解码环境 |
| Web | UI 与部分纯计算可共享；完整本地管线需专门设计 | 浏览器网络头限制/CORS、不同文件存储 API、不同并发模型与媒体源；建议使用远程媒体后端 |

`dart:io` 的 File/RandomAccessFile/HttpClient/HttpServer 属于非 Web 能力，Web 需 conditional imports 与其他实现。[dart:io](https://api.dart.dev/dart-io/dart-io-library.html)。

即使 Web 可计算签名，也不能据此推断能直接访问上游：当前需要的 UA/请求头和跨域请求不能按原生客户端方式任意使用。生产 Web 应规划 HTTPS 同源 API/媒体服务，不能默认浏览器可访问用户本机 127.0.0.1 的服务。

## 6. 建议的代码分层

```text
packages/hongguo_core/
  models/                 # ID 字符串、上游 DTO、播放轨道
  crypto/                 # 标准摘要/AES 接口、AesV3、PureSign、Spade
  upstream/               # query builder、HTTP、Client、AppSource
  media/                  # MP4 parser、IV、CTR、减壳
  services/               # Repository、任务调度、缓存策略
  ports/                  # Transport、RandomSource、Clock、FileStore

apps/hongguo_flutter/lib/
  features/               # 首页、AI短剧、搜索、详情、播放器、收藏历史
  adapters/native/        # dart:io 文件、下载、worker
  adapters/web/           # 远程 API、Web 播放源
  playback/               # 播放器封装、状态/事件、生命周期
```

上述分层已落地：Dart 包实际实现位于 `packages/hongguo_core/lib/src/` 各同名目录，公共入口为 `lib/hongguo_core.dart`；Flutter 工程位于 `apps/hongguo_flutter/`。核心模块不依赖 Widget 或 dart:io；平台文件/网络/播放器隔离。Flutter 原生直接调用 core，Web 使用相同 Repository 接口的远程实现。详细实现、运行命令和验收结果见 [移植与验收记录](Dart-Flutter-implementation.md)。

## 7. 分阶段实施与验收门槛

1. **协议基线**：修正/单独记录已有官网 async、browse、Range、失败缓存问题；固定 Node 测试向量、随机源、时钟和中间状态。现有 165 项自检作为起点，不能全部视为已能直接转换的 Dart 用例。
2. **纯 Dart 算法 POC**：先 Spade 和 URL decoder，再 PureSign；各摘要/中间字节与 Node 对拍。未通过前不展开全部 UI。
3. **单集媒体 POC**：使用本地确定性 MP4 fixture，验证音视频各轨 IV、样本边界、CTR、减壳、输出文件结构；再实际播放并 seek。
4. **原生最小闭环**：macOS 与 Android 优先验证；搜索/分类→详情→单集准备→播放→下一集；再验证 iOS 与桌面其余平台。
5. **体验与鲁棒性**：流式下载、取消、历史收藏、缓存淘汰、应用重启恢复、离线已缓存播放、低磁盘和失败清理。
6. **Web 适配**：接已有 Node 或新的 Dart 服务端；独立验收 HTTPS、CORS、视频 Range 和 key 处理。

成功门槛：签名固定输入对拍一致；Spade 真值全过；MP4 明文与 fixture 一致；release 真机可播、可 seek、有音频；后台/取消/缓存失败不会出现损坏成品。上游在线验收另行记录，不能只用本地对拍代替。

## 8. 主要不确定性

- Dart 核心 POC 和最小 Flutter 闭环已实现；已有 macOS 本地合成样本与单次上游证据，但仍不能据此承诺真机解密吞吐或首播延迟。
- 上游可返回空模型、失效 URL、不同格式；移植不增加对 spade v2 的支持。
- 现有源码规模与 Node API 替换决定工作量，自动语法转换只能辅助，不能作为兼容性证明。
- 安装包跨平台不等于同一台机器能完成所有平台构建；各平台仍需对应工具链与真机/系统验收。

推荐决策：若目标是独立 App，采用“Flutter 原生五端 + 共享 Dart 核心”，先通过算法和单集播放 POC；若还要 Web，再增加远程 API 适配。若只想最快看到 UI，可先对接现有 Node，但明确它是过渡/服务端方案。
