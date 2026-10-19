> 迁移记录（2026-10-19）：本实现已迁至 `/Users/lee/Desktop/flutter_hongguo/imports/hongguo_web_1_1_1/`，以下相对路径均以迁入根目录为准。目标仓库原有 `packages/core`、`packages/api`、`packages/app` 保留独立维护，本实现未加入其 workspace。

# Dart / Flutter 核心移植与验收

日期：2026-10-19。原生本地 Dart 核心、Flutter 应用及 Web 远程适配已实现。当前已通过本地对拍、macOS release 播放与上游单集准备；其他平台的真机验收仍未完成。原 Node 服务和网页源码保留不变。

## 运行应用

首次实现验收工具链为 Flutter 3.41.4 / Dart 3.11.1。迁移后验证使用目标仓库的 FVM SDK，记录见本目录 migration.md。工程最低 Dart SDK 为 3.11；macOS 最低目标为 12.0，当前默认构建宿主 CPU 架构。

在项目根目录运行：

```bash
cd apps/hongguo_flutter
flutter pub get
flutter run -d macos
```

原生默认独立运行，直接使用 Dart 进行分类、搜索、详情、签名取址、下载和解密，不启动 Node、loopback server 或 ffmpeg。选集后先完整下载、在 worker isolate 中解密，再打开本地文件。界面包括短剧、漫剧、AI短剧、搜索、选集、上下集、清晰度、收藏和观看历史；已有历史可恢复集号与播放进度。

Web 使用远程服务。可对接现有 Node 服务：

```bash
cd apps/hongguo_flutter
flutter run -d chrome \
  --dart-define=HONGGUO_API_BASE=http://127.0.0.1:8000 \
  --dart-define=HONGGUO_API_KEY="$HG_LOCAL_API_KEY"
```

`HG_LOCAL_API_KEY` 使用现有本地服务的 key。未设置 API_BASE 的 Web 默认请求当前站点；由同源部署提供原 API 路径。Web 构建中的配置可由客户端读取，API key 不是浏览器内的保密设施。原生也可通过相同的 API_BASE / API_KEY 切换为远程模式。

构建命令：

```bash
cd apps/hongguo_flutter
flutter build macos --release
flutter build web --release
flutter build apk --debug
```

macOS 与 Web release 已构建通过。常规 macOS App 保留在根目录 `artifacts/macos/hongguo_flutter.app`，Web 产物在 `apps/hongguo_flutter/build/web`；本次原生编译中间文件已清理。Android 首次在 Flutter 启动阶段、第二次在 Gradle 解包原生库/写缓存阶段因本机磁盘空间不足停止，不能视为 Android 构建通过；iOS、Windows、Linux 构建与真机均待验收。macOS 工程采用宿主架构，避免本机 Flutter/Xcode 组合的多架构 lipo 参数兼容问题；不表示已提供 Intel/ARM 通用二进制。

## 第 6 节分层的实际落地

标准 Dart package 在 `lib/src` 下放实现、`lib/hongguo_core.dart` 暴露公共入口。

| 层 | 代码路径 | 职责 |
|---|---|---|
| models | `packages/hongguo_core/lib/src/models` | 字符串 ID、Series/Episode、分页、PlaybackTrack、MediaSource |
| crypto | `packages/hongguo_core/lib/src/crypto` | MD5/SHA512/SM3、AES-CTR/CBC、Spade v1、PureSign 六头及 AesV3 |
| upstream | `packages/hongguo_core/lib/src/upstream` | 有序 query、签名请求、AppSource/fallback/选流、官网 SSR 数据源 |
| media | `packages/hongguo_core/lib/src/media` | 严格盒解析、样本索引、IV、CTR、视频 key/IV 自证、CENC 减壳 |
| services | `packages/hongguo_core/lib/src/services` | 原生目录 Repository、远程 Repository、持久详情缓存、单任务调度 |
| ports | `packages/hongguo_core/lib/src/ports` | Transport、Clock、RandomSource、随机读写文件、KeyValueStore、Repository、取消令牌 |
| features | `apps/hongguo_flutter/lib/features` | 分类/搜索、详情、收藏和历史 |
| native adapters | `apps/hongguo_flutter/lib/adapters/native` | 应用目录、身份存储、流式下载、文件随机读写、worker isolate、媒体缓存 |
| web adapters | `apps/hongguo_flutter/lib/adapters/web` | 远程 API 初始化及远程媒体地址 |
| playback | `apps/hongguo_flutter/lib/playback` | media_kit 控制、状态、切集代次、seek、后台暂停与取消、资源释放 |

核心不导入 Flutter、`dart:io`、`dart:isolate` 或进程接口。平台通过 ports 注入；原生与 Web 共享 CatalogRepository / PlaybackRepository 契约。`tools/verify_dart.sh` 静态检查这一边界。页面不实现签名、MP4 解析或文件下载。

## 已移植的关键行为

### 签名与上游

- PureSign 实现 x-gorgon、x-khronos、x-ladon、x-argus、x-helios、x-medusa。AesV3 独立实现；64 位字表使用 BigInt，32 位右移与截断显式处理。
- Clock、RandomSource、进程 nonce、启动时间可注入。48 组 Node 真值对拍覆盖 branch 0/1/2、中文、null/空/非空 body、四种时间戳低位，以及 0、2³¹、2³² 边界。
- JSON 仅编码一次，签名与 HTTP 发送复用同一 Uint8List；query 使用固定插入序和 Python 保留字符规则，`*` 编码为 `%2A`。最多尝试 32 次 ticket，避开 branch 1；未找到可用分支时明确报错。
- AppSource 支持对象/字符串 video_model、fallback 地址、seed 双 SHA512 派生 CBC URL 解密、H.264 优先排序及备用 URL；候选 spade 不可解析时跳过。
- 官网 SSR 获取正确 await HTTP Future，不继承旧源码的同步误用。App 目录分页保留游标并拒绝不前进的 offset；Web 远程 browse 自动为缺省 seen 提供兼容值。
- CDN 媒体重定向最多 5 次，每跳都重新校验 HTTPS、无用户信息、443 和域名。除原 3 个域外，增加本次上游实际返回的 `idouyinvod.com`，不开放任意重定向。

### 媒体与缓存

- 只读顶层盒头定位头部或尾部 moov，限制 moov 64 MiB、嵌套深度、样本数量和单样本预算。按 stsz/stsc/stco/co64 展开样本表；验证所有样本属于 mdat 且互不重叠。
- 读取 8/16 字节逐样本 IV，兼容原项目 compact tenc 与标准 CENC tenc，缺少逐样本 IV 时使用原项目的 base-IV 按样本号递增规则；音视频分别按各自样本表解密。视频先抽样验证 AVCC，再写入工作文件。
- 减壳重建 moov、恢复 encv/enca 的原始条目类型、删除 sinf/senc/saio/saiz/pssh，用 free 盒补齐原长度。绝对样本偏移保持不变，因此也支持 moov 在尾部。成品重新解析校验。
- 下载逐块写盘并施加背压；worker 仅接收路径和小参数，整段媒体不跨 isolate 复制。一个媒体准备任务执行，其余排队；同 key 等待前一任务完成后复用成品。
- 状态为 queued/downloading/decrypting/remuxing/ready/failed/cancelled。此处 remuxing 是验证和发布阶段，不执行 ffmpeg。
- `.part` 文件始终不算缓存。验证后先 rename MP4，再原子发布 `.ready.json`；重启只接受 marker 与文件长度匹配的成品。异常/取消删除工作文件，启动清理遗留 `.part`。
- 缓存默认 1 GiB / 30 文件，按最近使用时间淘汰；详情持久缓存 6 小时，上游不可用时允许使用旧详情，以配合历史/收藏和已缓存视频离线打开。
- 切集通过取消令牌和串行播放器命令防止旧结果覆盖新选择；进入后台暂停并取消准备。大文件 worker 可直接终止。

## 验收证据与复现

核心包 69 项、Flutter 8 项测试全部通过，Dart 与 Flutter 静态分析均无问题。所有默认测试都离线运行；只读上游冒烟是独立显式命令。

```bash
# 根目录：分层边界、格式、静态分析、核心与 Flutter 测试
./tools/verify_dart.sh

# 用原 Node 工程重新生成真值（可用 HONGGUO_NODE_ROOT 指定工程目录；无网络）
node tools/generate_dart_fixtures.cjs

# 开发期可选：需要 PATH 中的 ffmpeg，重建 3 秒测试画面与 440 Hz 音频
node tools/generate_playable_fixture.cjs

# macOS release：解密、真实视频帧、音视频轨道与 seek；静音
./tools/smoke_playback_macos.sh
```

`smoke_playback_macos.sh` 使用专门的开发入口，运行后如需分发常规 App，重新执行 `flutter build macos --release`，恢复 `lib/main.dart` 入口。

| 证据 | 结果 | 对应代码/下一步 |
|---|---|---|
| Node 签名固定输入 | 48 组，全部六头逐字节一致 | `test/sign_test.dart`；上游协议变更时重新生成对拍 |
| Spade 真值 | 5/5，包括 base64 入口 | `test/algorithms_test.dart`；只支持 v1 |
| 头/尾 moov fixture | 明文样本一致，减壳后索引不变，错误 key 不改写样本 | `media/mp4.dart` 与 algorithms_test |
| Repository/调度测试 | query/body 一致、远程接口映射、长 ID、分页停滞、离线详情与串行调度 | `test/repository_test.dart` |
| 原生媒体文件测试 | 下载/worker/重启缓存/去重/取消/失败重试/淘汰/不可信重定向 | Flutter `test/native_media_test.dart` |
| Widget 测试 | 分类、AI短剧、搜索、收藏、历史及持久恢复 | Flutter `test/catalog_test.dart` |
| 合成 H.264/AAC | Dart 解密后解码 SHA-256 与明文相同：`54f0bc28384487fa4972c550cddaea2ab8aee43655bc76916ecbea2acb47fd26` | `playable-clear/encrypted.mp4`；非上游媒体 |
| macOS release 播放 | duration 3021ms，识别音视频轨道，seek 后 position 1866ms，实际 PNG 视频帧 38999 字节 | `tool/playback_smoke_app.dart`，截图见下 |
| Web release | 构建通过，含 Wasm dry-run | UI/API 实际同源部署仍需独立验收 |
| 上游只读冒烟 | 分类 1 条、搜索 1 条、详情 48 集；1080p 加密模型；完整准备进入 ready，成品 9,763,991 字节 | `tool/upstream_smoke.dart --prepare`；检查后删除临时视频，不保存内容密钥/媒体 URL |

实际视频帧来自本地合成样本：

![Dart 解密后由播放器取得的视频帧](assets/dart-decrypted-frame.png)

按需复现在线检查（会访问上游；`--prepare` 会下载单集到临时目录，结束删除）：

```bash
cd apps/hongguo_flutter
# 只检查目录、搜索、详情、取址
dart run tool/upstream_smoke.dart
# 另检查完整下载/解密/缓存发布
dart run tool/upstream_smoke.dart --prepare
```

测试输出只报告计数、阶段和尺寸；不输出签名 URL、凭据或 content key。在线结果代表本次时点与本机网络，不保证其他账号/IP/日期的上游可用性。

## 当前边界

- 当前是核心闭环版本，不是旧 Node 管理服务的逐路由替代。管理 key、批量指标、完整筛选面板、排行榜细项、导出 UI 与下一集预热未迁入；当前主页使用分类列表。
- 不支持 spade v2、fragmented MP4、CENC subsample/pattern encryption；不支持的格式明确失败并清理缓存。不会自动调用桌面/移动端 ffmpeg 兜底。
- 尚无边下边播、持久任务恢复或多播放器并行缓存租约；取消与重启会清理工作文件，重新准备。缓存预算不包括所有 SDK/应用元数据。
- macOS 已验收合成媒体的解密、音视频轨道、真实帧和 seek；真实上游单集验收到成品 ready，未将其作为播放器截图或保留媒体。
- 尚未完成 Android/iOS 真机性能、功耗、低磁盘、长时间播放、系统回收与所有平台编码组合验收；Windows/Linux/iOS 的工程入口已创建，不等同于对应系统验收通过。
- Web 依赖远程 API/Range 服务和目标站点的 CORS/HTTPS 部署；浏览器不执行本地文件解密管线。
