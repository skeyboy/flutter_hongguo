# Flutter Hongguo

正式目标：**Android / iOS / macOS / Windows / Linux 独立原生 App + 共享 Dart 核心**。当前以本机 Mac 验收算法与单集播放。

Flutter UI → 共享 Dart 核心 → 本地普通 MP4 → 原生播放器的第一版已实现。

- 首页、分类、题材筛选、搜索、详情和选集。
- Dart 六头签名、URL 解码、Spade v1、MP4 音视频样本 AES-CTR 解密与 CENC 信令处理。
- Dio 流式下载、worker isolate、并发请求合并、取消、原子缓存和清理。
- media_kit 本地文件播放、清晰度、seek、上一集/下一集、自动连播与下一集预热。

原生 App 不运行 Node 或 ffmpeg。Node/ffmpeg 仅用于开发机的离线对拍和测试素材生成。实际内容接口需可用上游返回，不保证所有格式/内容可播放。

本轮验证：52 项 App 单元/页面测试、5 项 macOS 原生离线集成通过。此前共享核心 113 项、API 28 项通过。此前 1 项真实预缓存验收以及 macOS 与 iOS 模拟器实际播放/seek 集成通过；Android 调试包、macOS 与 Web 均构建成功。iOS 模拟器音频输出有设备初始化告警，真机声音仍需独立验收。当前 Mac 已进一步通过真实上游第 1 集 1080p 播放与 seek POC。

Android 调试包：`packages/app/build/app/outputs/flutter-apk/app-debug.apk`。

## 目录与文档入口

分析结果、主工程代码及验收记录均已集中在本目录。

- [文档总索引](docs/README.md)：原始分析、API、AI 流程、实现与验收报告。
- [分析结论与代码目录对应表](docs/project-map.md)：每项流程对应的源码、测试与工具。
- 主工程源码：[共享核心](packages/core/README.md)、[API/缓存](packages/api/README.md)、[Flutter App](packages/app/README.md)。
- [持久化验收证据](docs/evidence/README.md)：清理 build 后仍保留的结果快照。

## 按需 GitHub 打包

在 Actions 选择平台运行，普通 push/PR 不自动打包；构建一次后上传附件或 Release，中间文件保留 1 天。默认跳过高成本集成测试和无签名 iOS 编译。[操作与成本估算](docs/github-release.md)。

## 0.2.4：本地缓存连播

同一剧目的缓存分集按集号连续播放，支持连播开关与本地清晰度回退；缺集或文件失效时停止，不自动联网补下。[规则与验收](docs/local-cache-autoplay.md)。

## 0.2.3：横向筛选与 GitHub 发布

发现/分类使用入口下方的统一横向面板，点击即切换，连续选择 250ms 合并请求。[筛选实现与截图](docs/design/horizontal-filter-panel.md)。

已接入上游 submodule 并配置五端 CI、安装包与 Release 附件；[私有仓库上传与签名说明](docs/github-release.md)。

## 0.2.2：本地剧目库

本地缓存按剧目展示首页同款封面卡片，点击查看已缓存分集；补齐标题/封面/分集资料持久化、离线海报及旧缓存资料匹配。本轮 42 项 App 测试和 3 项 Mac 原生集成通过。

[设计与验收](docs/local-library-grouping.md)

## 0.2.1：交互与本地缓存

- 发现/分类筛选保持置顶；PC 直接菜单，mobile 底部筛选面板。
- 主题选择立即应用并保存，其他设置仍显式保存。
- 列表先显示本地快照，再联网刷新；失败保留缓存。
- 设置增加本地缓存剧集，可直接离线播放和逐项删除。

[体验设计](docs/design/interaction-cache-v2.md) · [实现与验证](docs/interaction-cache-validation.md)

## 0.2.0：预缓存与 PC / Mobile UI

- 播放时自动准备后续 3～5 集，前台优先、复用既有任务和已缓存文件。
- 新增设置页：缓存容量与清理、清晰度/并发/连播、明暗主题、会话安全保存、签名/设备与高级协议参数。
- 下滑自动加载更多，包含去重、游标停滞保护和手动重试。
- PC 侧栏、常驻搜索、双栏播放器与键盘；mobile 底部导航、沉浸画面、底部选集与滑动切集。

已先落地 [UI 设计草案](docs/design/pc-mobile-ui.md)，再实施响应式改造；[本轮实现与验证](docs/pc-mobile-settings-prefetch.md)。

## 工程

参考 `hack-news-flutter` 的 workspace、core/api/app 分包，以及 Dio、Riverpod、GetIt；根目录集中依赖版本。Flutter **3.47.4** / Dart **3.13.3**，`.fvm/flutter_sdk` 已关联本机 SDK。

| 包 | 职责 |
|---|---|
| hongguo_core | Web 安全的纯 Dart 签名/加密/MP4 算法；单独的 hongguo_native.dart 提供文件/isolate 适配 |
| hongguo_api | 内容 Repository、App 取址、Dio；hongguo_native_api.dart 提供原生媒体缓存 |
| hongguo_app | 自适应 Flutter 页面、平台 runtime、播放输出与生命周期 |

## 当前 Mac 独立 App

已构建并启动 [macOS arm64 Release App](artifacts/macos/20261019-190733/Hongguo.app)，以及 [ZIP](artifacts/macos/20261019-190733/Hongguo-macos-arm64.zip)。不需要另启 Node 或开发服务。

算法 103 个原生向量通过；真实《十年恩，一生还》第 1 集已完成下载、本地解密、1080×1920 原生播放、音轨识别和 10 秒 seek。详见 [Mac 独立 App 验收报告](docs/macos-independent-app-poc.md)。

## 运行

```bash
cd packages/app
../../.fvm/flutter_sdk/bin/flutter run -d macos
```

Android/iOS/Windows/Linux 使用相应设备与本机工具链。App 首次运行会在私有支持目录创建设备身份与缓存目录，不读取参考项目的 .env、账号或数据库。

浏览器版使用远程服务适配：

```bash
cd packages/app
../../.fvm/flutter_sdk/bin/flutter run -d chrome \
  --dart-define=HONGGUO_API_BASE=https://your-service
```

远程服务须实现已有本地 API 文档中的路由，并允许必要跨域请求；原生 App 使用本地 Dart 流水线，不依赖这个服务。

## 验证

```bash
./tool/verify_all.sh
./tool/verify_native.sh macos
```

第一条执行静态分析、单测、页面测试、AOT/JS 对拍、离线媒体处理；第二条启动本机原生 App，以模拟的网络媒体响应验证实际播放/seek，不请求真实上游。日志与本地测试视频在 `build/verification/`。

测试样本已随项目保存，普通回归不需要原 Node 工程。重新生成 oracle/素材的方法见报告。

## 文档

- [当前 Mac 独立 App 与真实单集验收](docs/macos-independent-app-poc.md)
- [第二阶段实现与验证](docs/native-playback-pipeline.md)
- [第一阶段签名核心验证（历史记录）](docs/initial-core-validation.md)
- [源代码来源与许可声明](NOTICE.md)

限制：当前支持非 fragmented CENC AES-CTR，明确拒绝不支持的容器/加密模式。真实上游的可用性按具体剧集验收，当前 Mac 已验证上述单集；其余格式/平台不由这一结果自动覆盖。

## 迁入的 hongguo-web 实现

本次从参考项目迁入的独立 Dart / Flutter 实现位于 [imports/hongguo_web_1_1_1](imports/hongguo_web_1_1_1/README.md)。保留其分层与测试，不与上述 workspace 的同名核心包混用。
