# 0.2.4：本地缓存剧集连续播放

从“设置 → 本地缓存剧集 → 剧目 → 分集”进入播放器，现在会传入该剧全部已缓存分集，按集号排序，从用户选中的那一集开始。不同清晰度的同一视频只出现一次；“待识别视频”不合并成连播队列，避免跨剧播放。

## 连播规则

- 沿用设置中的“自动连播”偏好。手机播放器底部新增“本地连播”开关，PC 选集面板的连播开关现在也可用于本地播放；操作会保存偏好。
- 当前集结束后自动进入下一集。播到本地队列末集停止，不回到第一集循环。
- 优先使用用户最初选择的清晰度。下一集没有该版本时，只从已有缓存中选择替代版本；后续有原清晰度时恢复原选择，不下载缺少的版本。
- 每次切集重新枚举完成文件，再调用只读本地的 `prepareCached`；正常下载及预缓存路径不会被调用。
- 中间缺集时停止并提示，例如缓存第 1、3 集不会自动跳过第 2 集。用户仍可手动选择其他已缓存分集。
- 已排入队列的文件被删除或校验失败时显示错误并停止，不静默联网补下，也不自动无限重试。
- 切换时先关闭旧数据源再释放文件引用；正在播放的文件仍受清理保护。

在某集结束后重新开启播放器中的连播开关，会继续到下一集；关闭开关后，当前集播完停留。

## 实现位置

| 职责 | 文件 |
|---|---|
| 同剧队列、清晰度选择与连续集号判断 | [local_playlist.dart](../packages/app/lib/playback/local_playlist.dart) |
| 从分集入口传入完整缓存队列及起播位置 | [local_cache_page.dart](../packages/app/lib/features/local_cache_page.dart) |
| 本地完成事件、开关、缺集提示与文件租约交接 | [player_page.dart](../packages/app/lib/features/player_page.dart) |
| 队列/质量/未知视频/缺集测试 | [local_playlist_test.dart](../packages/app/test/local_playlist_test.dart) |
| 真实原生播放器离线连播验证 | [offline_playback_test.dart](../packages/app/integration_test/offline_playback_test.dart) |

## 验证

本轮 52 项 App 单元/页面测试、5 项 Mac 原生集成测试通过，静态分析无问题。

新增原生测试在预置测试缓存后主动关闭网络客户端，连续播放三集，实际选择为 `720p → best → 720p`。验证开关偏好保存、关闭后不切集、重新开启后继续、末集停止，下载次数保持不变；另验证缺集停止、下一文件删除后离线报错以及旧文件引用释放。测试素材和设置均使用临时测试目录，不修改真实会话。

[验收摘要与日志](evidence/local-autoplay)。本轮仅在当前 Mac 上执行原生集成，其他平台由已配置的 GitHub 流程在登录上传后执行。

## 独立包

macOS arm64 0.2.4（build 6）已构建并通过签名校验。[App](../artifacts/macos/20261019-190733/Hongguo.app) · [ZIP](../artifacts/macos/20261019-190733/Hongguo-macos-arm64.zip) · [手机本地连播开关](assets/local-autoplay/hongguo-local-player-mobile-ui.png)。
