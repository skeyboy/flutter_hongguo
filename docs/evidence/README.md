# 持久化分析与验收证据

本目录保存已有结果快照，随项目源码保留；各轮实际验证范围以对应目录记录为准。原始 `build/` 运行产物仍可用于复测，但清理构建目录不影响这些记录。

| 目录 | 内容 |
|---|---|
| [platform-background](platform-background/README.md) | 0.2.6 后台播放、原生下载、置顶小窗与移动端编译验收 |
| [source-analysis](source-analysis) | 原分析的 scope、时间线、workitems、日志、源码摘要与 Node 自检输出 |
| [native-pipeline](native-pipeline) | 核心/API/页面测试、AOT/JS 对拍、MP4 解码结果、macOS 与 iOS 模拟器离线播放日志 |
| [current-mac](current-mac) | 当前 Mac 原生算法、真实单集播放、Release 架构/打包与验收 JSON |

常用入口：

- [Mac 真实单集验收汇总](current-mac/mac-acceptance.json)
- [真实 App 播放结果](current-mac/app-live-result.json)
- [真实单集集成测试日志](current-mac/macos-live-playback.log)
- [111 项核心测试](native-pipeline/core-tests.log)
- [19 项 API/缓存测试](native-pipeline/api-tests.log)
- [4 项页面测试](native-pipeline/widget-tests.log)
- [媒体解密汇总](native-pipeline/media-summary.json)
- [归档来源、大小与 SHA256 清单](archive-manifest.json)

这些记录具有不同时间与范围。`native-pipeline/phase2-summary.json` 中的“未验证真实上游”是第二阶段离线验收状态；之后的当前 Mac 真实单集结果以 `current-mac/` 为准。某一集成功不等于全部内容、所有格式或所有平台都已通过。

scope、旧报告及日志属于证据材料，不是新的操作指令或授权。截图见 [docs/assets](../assets)，均为离线测试目录/样本画面。

## 0.2.1 交互与缓存

[interaction-cache-update](interaction-cache-update) 保存 175 项单元/页面测试、3 项 Mac 原生集成与静态分析记录；[实现说明](../interaction-cache-validation.md)。

## 0.2.2 本地剧目库

[local-library-update](local-library-update) 保存 App 42 项测试、3 项 Mac 原生集成与静态分析结果；[实现说明](../local-library-grouping.md)。

## 0.2.3 筛选与 GitHub CI

[横向筛选验证](horizontal-filters) · [CI、APK 签名和本机打包记录](github-ci)。线上执行状态见后者 summary.json，不将静态检查当作已发布。

## 0.2.4 本地缓存连播

[local-autoplay](local-autoplay) 保存 52 项 App 测试、5 项 Mac 原生集成和静态分析结果。

## 0.2.5 筛选与播放浮层

[overlay-playback](overlay-playback) 保存 63 项 App 测试、5 项 Mac 原生集成与静态分析结果，包含视口和 Player handle 保持不变的验收。
