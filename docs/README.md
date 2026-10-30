# 项目文档索引

本项目的分析文档、主工程代码、参考实现与验收证据均集中在 `flutter_hongguo/` 内。日常开发和运行以根 workspace 的 `packages/core`、`packages/api`、`packages/app` 为主。

## 后台与悬浮能力

- [真实移动端测试与 ADB 安装](mobile-testing.md)
- [平台设计](design/platform-background.md)
- [实现与使用限制](platform-background.md)
- [0.2.6 验收记录](evidence/platform-background/README.md)

## 当前浮层与播放空间

- [设计与平台交互](design/overlay-playback.md)
- [0.2.5 实现、截图与验证](overlay-playback-validation.md)

## 本地连播

- [缓存剧集连播规则与验收](local-cache-autoplay.md)

## 筛选与发布

- [横向筛选面板实现](design/horizontal-filter-panel.md)
- [发现页顶部筛选分层与榜单拆成目的地](design/discover-filters-and-ranking.md)：四层筛选的一层一义、逐层人机规格、PC 与移动按输入族分派，词表以四次实机取样为据（[原始读数](evidence/ranking-fields/README.md)、[可交互原型](design/prototypes/discover-filters-ranking.html)）。
- [私有仓库、五端 CI 与 Release](github-release.md)

## 本地剧目库

- [本地缓存按剧目展示与验证](local-library-grouping.md)
- [实施前设计](design/local-library-grouping.md)

## 交互与缓存改进

- [体验设计](design/interaction-cache-v2.md)
- [0.2.1 实现、设置验证与缓存验收](interaction-cache-validation.md)
- [筛选词表与列表的 SQLite 缓存 + 差异 patch](design/catalog-sqlite-cache.md)：表设计、四条「不许删」护栏、DB-first 时序与 JSON→SQLite 迁移口径。

## 投屏

- [DLNA 投屏设计与分期实施](design/cast-dlna.md)：市面做法调研、协议选型、后端配合清单与验收口径。
- [协议核心模块](../packages/cast/README.md)：SSDP、设备描述、SOAP、DIDL、局域网媒体源与会话状态机。

## PC / Mobile 初版改造

- [实施前 UI 设计](design/pc-mobile-ui.md)
- [搜索聚焦下拉设计](design/search-focus-suggestions.md)：最近搜索与推荐位的交互、存储、标记语义与后端配合清单。
- [播放页竖滑切集设计](design/player-episode-swipe.md)：市面手势惯例、触屏限定与互斥、边界反馈、首次提示文案矩阵。
- [播放控制条重构设计](design/player-controls-redesign.md)：PC 与移动四态按钮簇、自绘进度条、中心层、点按/双击/长按语义、快捷键补齐，以及落地后与规格的出入（§8）。
- [预缓存、设置与响应式 UI 实现及验证](pc-mobile-settings-prefetch.md)

## 建议阅读顺序

1. [文档与代码对应表](project-map.md)：定位每项流程对应的源码、测试和工具。
2. [当前 Mac 独立 App 与真实单集验收](macos-independent-app-poc.md)：最新的本机原生 POC 结果。
3. [下载、解密、缓存与播放器实现](native-playback-pipeline.md)：已经落地的完整链路。
4. [第一阶段核心验证](initial-core-validation.md)：初始算法迁移与对拍记录。

## 原始分析结果

这些资料是分析阶段快照，部分“尚未实现”描述属于当时状态；当前实现状态以上面的项目验收报告为准。

| 文档 | 内容 |
|---|---|
| [流程、签名、密钥与视频播放分析](analysis/2026-10-19_流程与签名-hongguo-report.md) | 原 Node 模块、签名链路、URL 与内容密钥区分、MP4 解密与代码问题 |
| [API 文档](analysis/API-reference.md) | 原本地 HTTP 服务与上游接口映射、参数、返回与错误语义 |
| [AI 流程](analysis/AI-workflow.md) | AI短剧分类与建议的 AI 调用编排；建议编排不是已实现功能 |
| [Dart / Flutter 可行性评估](analysis/Flutter-Dart-feasibility.md) | 迁移难点、原生五端边界与分阶段方案 |

API 文档中的 `/search`、`/stream` 等属于原 Node 服务路由；独立原生 App 的接口与本地播放入口见 [代码对应表](project-map.md)。

## 已落地代码

- [共享 Dart 核心](../packages/core/README.md)
- [内容接口、取址与原生缓存](../packages/api/README.md)
- [局域网投屏协议核心](../packages/cast/README.md)
- [Flutter 原生 App](../packages/app/README.md)
- [开发与验收工具](../tool)

## 证据与截图

- [验收证据索引](evidence/README.md)：持久保存的日志与结果，避免依赖可清理的 build 目录。
- [归档 SHA256 清单](evidence/archive-manifest.json)：来源、目标相对路径、大小和摘要。
- [首页截图](assets/hongguo-library-ui.png)、[详情截图](assets/hongguo-detail-ui.png)、[解码帧](assets/hongguo-native-frame.png)：使用离线测试样本，不代表线上内容搜索结果。

## 导入参考实现

另一份从原分析工程迁入的 Dart / Flutter 实现已保存在 [imports/hongguo_web_1_1_1](../imports/hongguo_web_1_1_1/README.md)。其源码、工具、文档及成品保留在原有分层中，作为独立参考；未加入根 workspace，也不覆盖主工程包。

相关记录：[参考实现报告](../imports/hongguo_web_1_1_1/docs/Dart-Flutter-implementation.md)、[参考实现验收日志](../imports/hongguo_web_1_1_1/docs/dart-flutter-verification.txt)。
