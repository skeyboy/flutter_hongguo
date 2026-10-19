# 分析结论与代码目录对应表

根目录 `pubspec.yaml` 定义主 workspace。主工程源码均在 `packages/` 内；`imports/` 是单独保留的迁入参考实现。

## 目录布局

```text
flutter_hongguo/
├── README.md                      项目入口、运行与验收说明
├── docs/
│   ├── README.md                  文档总索引
│   ├── project-map.md             本文：分析结论到代码的映射
│   ├── analysis/                  原始流程 / API / AI / 可行性分析
│   ├── evidence/                  持久化验收结果、原分析记录、SHA256 清单
│   ├── assets/                    验收截图
│   └── *-poc.md / *-pipeline.md    当前主工程实现与验收说明
├── packages/
│   ├── core/lib/                  签名、解码、密钥与 MP4 算法
│   ├── core/test/                 算法对拍、MP4 测试、离线样本
│   ├── api/lib/                   内容接口、视频取址、下载与缓存
│   ├── api/bin/                   显式执行的真实上游 POC 探测
│   ├── api/test/                  请求、内容解析与缓存测试
│   └── app/
│       ├── lib/                   Flutter 页面、DI 与平台 runtime
│       ├── test/                  页面与交互测试
│       ├── integration_test/      离线原生播放 / Mac 真实单集 POC
│       └── android/ ios/ macos/ windows/ linux/ web/
├── tool/                          对拍、回归、媒体和打包脚本
├── artifacts/                     本地 App 与安装包，不属于源码
├── imports/hongguo_web_1_1_1/      独立参考实现，不加入主 workspace
└── build/                         可清理的临时构建与测试输出
```

## 核心流程映射

| 分析内容 | 主工程实现 | 主要测试 |
|---|---|---|
| 六头签名、分支选择、随机源和时间戳 | [pure_sign.dart](../packages/core/lib/src/crypto/pure_sign.dart) | [oracle_test.dart](../packages/core/test/oracle_test.dart) |
| URL 派生与 AES-CBC 解码 | [media_url.dart](../packages/core/lib/src/crypto/media_url.dart) | oracle_test.dart |
| spade v1 内容密钥解包 | [spade.dart](../packages/core/lib/src/crypto/spade.dart) | oracle_test.dart |
| 摘要与标准 AES 原语 | [bytes.dart](../packages/core/lib/src/crypto/bytes.dart) | oracle_test.dart |
| MP4 盒、样本索引、各轨 IV、CTR 与 CENC 信令处理 | [mp4.dart](../packages/core/lib/src/media/mp4.dart) | [mp4_test.dart](../packages/core/test/mp4_test.dart) |
| 原生文件随机读写、worker isolate | [file_decryptor.dart](../packages/core/lib/src/media/file_decryptor.dart) | mp4_test.dart |
| 搜索、分类、AI短剧、题材、详情与分集 | [catalog.dart](../packages/api/lib/src/catalog.dart) | [catalog_test.dart](../packages/api/test/catalog_test.dart) |
| App 模型签名 POST、fallback、选流 | [video_model_client.dart](../packages/api/lib/src/video_model_client.dart) | [video_model_client_test.dart](../packages/api/test/video_model_client_test.dart) |
| 流式下载、取消、并发合并、原子缓存、淘汰 | [media_cache.dart](../packages/api/lib/src/media_cache.dart) | [media_cache_test.dart](../packages/api/test/media_cache_test.dart) |
| Flutter 入口与依赖装配 | [main.dart](../packages/app/lib/main.dart)、[bootstrap.dart](../packages/app/lib/bootstrap.dart) | [widget_test.dart](../packages/app/test/widget_test.dart) |
| 首页、搜索、分类与题材 | [library_page.dart](../packages/app/lib/features/library_page.dart) | widget_test.dart |
| 详情与选集 | [detail_page.dart](../packages/app/lib/features/detail_page.dart) | widget_test.dart |
| 本地播放器、seek、切集、预热与生命周期 | [player_page.dart](../packages/app/lib/features/player_page.dart) | [离线原生集成测试](../packages/app/integration_test/offline_playback_test.dart) |
| 原生运行链路与私有目录 | [runtime_native.dart](../packages/app/lib/platform/runtime_native.dart) | [Mac 真实单集测试](../packages/app/integration_test/macos_live_poc_test.dart) |

## 新增：设置、预缓存与响应式 UI

| 职责 | 主工程代码 |
|---|---|
| 共享配置 / 协议校验 | [app_settings.dart](../packages/core/lib/src/config/app_settings.dart) |
| 前后台优先级 / 字节预算 | [media_cache.dart](../packages/api/lib/src/media_cache.dart) |
| 预缓存滑动窗口 | [prefetch_window.dart](../packages/app/lib/playback/prefetch_window.dart) |
| 设置存储事务 | [settings_store.dart](../packages/app/lib/settings/settings_store.dart) |
| 原生安全存储 | [settings_store_native.dart](../packages/app/lib/settings/settings_store_native.dart) |
| PC / Mobile 设置页 | [settings_page.dart](../packages/app/lib/features/settings_page.dart) |

[设计](design/pc-mobile-ui.md) · [实现与验证](pc-mobile-settings-prefetch.md)

## 工具与成品

| 目的 | 文件 / 目录 |
|---|---|
| 完整离线回归 | [tool/verify_all.sh](../tool/verify_all.sh) |
| 原生播放验收 | [tool/verify_native.sh](../tool/verify_native.sh) |
| Mac 显式真实单集验收 | [tool/verify_mac_live.sh](../tool/verify_mac_live.sh) |
| 真实上游探测 | [mac_poc_probe.dart](../packages/api/bin/mac_poc_probe.dart) |
| 从原实现重新生成开发期真值 | [generate_oracle.cjs](../tool/generate_oracle.cjs) |
| 生成离线媒体样本 | [generate_media_fixtures.cjs](../tool/generate_media_fixtures.cjs) |
| 媒体解密独立检查 | [verify_media.dart](../tool/verify_media.dart) |
| macOS 打包 | [package_macos_release.sh](../tool/package_macos_release.sh) |
| macOS 独立成品 | [artifacts/macos](../artifacts/macos) |

运行 App 与普通回归不依赖原分析目录。只有显式重新生成 Node oracle 或素材时，生成脚本才需要传入原 Node 工程路径。验收快照已归档至 [docs/evidence](evidence/README.md)。

## 0.2.1 交互与缓存更新

常驻筛选、主题即时应用、目录快照与本地剧集入口的源码/测试对应见 [交互与缓存验收](interaction-cache-validation.md)。
