# 0.2.1：筛选常驻、主题即时生效与本地缓存

代码位于新主工程 `packages/app` 与 `packages/api`，没有修改参考项目或 `imports` 中的实现。先完成 [体验设计](design/interaction-cache-v2.md)，再实施。

## 使用方式

- **PC**：搜索栏下方的筛选工具栏随滚动置顶。发现/分类均可切类型、题材和排序，发现页还可切推荐/最新/榜单。窄桌面横向滚动工具栏。
- **Mobile**：顶部品牌与搜索可滚走，列表类型、内容类型和筛选入口保持可达。筛选从底部面板展开，确认后应用。
- **主题**：选择浅色、深色或跟随系统后立即保存并应用；其他表单仍需点保存。主题保存不会连带提交尚未保存的缓存/凭据配置，失败回退原选择。
- **本地缓存**：设置 → 缓存管理 → 本地缓存剧集。可查看、直接离线播放和删除已完成视频；使用中的文件不能删除。旧缓存缺少剧目元数据时显示 VID，新的播放记录会保存剧名和集号。

## 列表缓存路径

参考代码：`/Users/lee/Desktop/hack-news-flutter/packages/api/lib/src/storage/local_cache.dart`、`cache_store.dart`、`cache_policy.dart`。复用其“本地存储与仓库分离、保留有序列表快照、联网失败保留本地内容”的设计思想，结合本项目加入先显示缓存再联网刷新的过程。

1. 页面/筛选/搜索/榜单组合生成独立缓存键，读取有序快照和对应分页游标。
2. 有缓存立即展示，同时请求最新第一页。刷新期间暂不自动追加旧游标的下一页。
3. 网络成功后替换列表和游标，保存新快照；后续分页保存完整已加载快照。
4. 网络失败保留缓存并提供刷新入口；迟到的其他页面响应由 revision 校验丢弃。
5. 写盘失败保留本次网络结果并显示缓存保存失败，不伪装成离线可用。

原生磁盘：应用私有支持目录的 `library-cache.json`；内存用于当前进程快速切换。最近 80 个列表，每列表最多 500 条，7 天过期；截断时不保存后续游标，避免跳过中间内容。持久化使用临时文件和原子重命名。更改协议/会话/设备身份时清空列表快照；剧集元数据单独保留。浏览器及测试适配器默认仅使用内存快照，原生五端共享同一文件实现。

目录快照与媒体 MP4 缓存相互独立。此轮缓存目录数据与封面 URL，未添加封面图片离线下载，因此完全断网时海报可能显示占位图。

## 本地播放路径

缓存页仅列出具有完成清单、文件名/VID/清晰度一致且文件大小匹配的 MP4，过滤 `.part` 和损坏清单。打开时再次检查普通 MP4，并在检查前持有文件引用，避免同时清理导致文件消失。

本地入口调用 `prepareCached`，不进入片源解析或下载逻辑。缺失/失效时明确报错；不静默回源。播放器复用现有页面，但关闭清晰度切换、自动连播和预缓存，避免离线观看触发联网。返回后释放文件引用。

## 问题、改动与验证对应

| 原行为 / 需求 | 对应修改 | 验证证据 |
|---|---|---|
| 筛选随内容滚出屏幕 | 64px pinned SliverPersistentHeader；PC 直接菜单、手机底部面板 | 390/1280 宽度长列表滚动后控件 hitTestable，操作后请求题材改变 |
| 主题仅修改草稿 | 即时保存独立 theme 字段；全局设置流先订阅再发布初值 | 页面实际 Brightness、系统亮暗变化、失败回退；Mac 无需点击保存即可变暗 |
| 切换列表重新空白加载 | LibraryCache 有序快照 + 后台刷新 | 慢请求先显示缓存，失败保留，重试替换新内容/游标，迟到响应被丢弃 |
| 设置缺少实际行为验证 | 保存、文件重启和原生协议重建检查 | 缓存数量/空间、连播/预缓存/自动分页、清理、签名刷新、凭据掩码与事务测试 |
| 看不到本地剧集 | 缓存列表、只读本地播放、逐项删除 | 完成清单筛选、占用保护、删除更新；Mac 解码本地文件且下载数不增加 |

## 源码入口

| 模块 | 文件 |
|---|---|
| 常驻筛选、缓存优先与刷新 | [library_page.dart](../packages/app/lib/features/library_page.dart) |
| 快照、边界、剧集元数据 | [library_cache.dart](../packages/app/lib/catalog/library_cache.dart) |
| 主题即时保存、本地缓存入口 | [settings_page.dart](../packages/app/lib/features/settings_page.dart) |
| 本地剧集列表与删除 | [local_cache_page.dart](../packages/app/lib/features/local_cache_page.dart) |
| 离线播放器模式 | [player_page.dart](../packages/app/lib/features/player_page.dart) |
| 原生存储和运行时设置 | [runtime_native.dart](../packages/app/lib/platform/runtime_native.dart) |
| 全局主题订阅 | [bootstrap.dart](../packages/app/lib/bootstrap.dart) |
| 完成项枚举与只读本地文件租约 | [media_cache.dart](../packages/api/lib/src/media_cache.dart) |

## 验收

本轮重新运行：核心 113 项、API 28 项、App 单元/页面 34 项，共 **175 项**通过；静态分析无问题。

当前 Mac 原生集成 3 项通过，覆盖真实解码/seek、主题立即生效、缓存列表 → 本地播放不增加下载，以及原有 5 集预缓存与布局切换。使用离线合成媒体和测试目录，不访问用户会话，不下载真实上游内容。

日志和机器可读摘要见 [本轮证据](evidence/interaction-cache-update)。此轮未新增其他平台设备验收，也未重新执行真实上游内容验收。

## 截图

以下为当前 Mac 运行 Flutter 原生集成测试所得，内容为明确标记的离线测试素材。

- [PC 常驻工具栏](assets/interaction-cache/hongguo-library-pc-ui.png)
- [手机布局](assets/interaction-cache/hongguo-library-mobile-ui.png)
- [主题即时切换后](assets/interaction-cache/hongguo-theme-dark-mobile-ui.png)
- [本地缓存剧集](assets/interaction-cache/hongguo-local-cache-mobile-ui.png)
- [本地播放器](assets/interaction-cache/hongguo-local-player-mobile-ui.png)

## 复测命令

```bash
cd /Users/lee/Desktop/flutter_hongguo
.fvm/flutter_sdk/bin/dart analyze --fatal-infos
(cd packages/core && ../../.fvm/flutter_sdk/bin/dart test)
(cd packages/api && ../../.fvm/flutter_sdk/bin/dart test)
(cd packages/app && ../../.fvm/flutter_sdk/bin/flutter test --no-pub)
./tool/verify_native.sh macos
```

## macOS 独立包

已构建并启动 0.2.1 arm64 独立包，签名校验通过。在独立包中打开设置及本地缓存页，成功识别已有的 15 个完成文件；未删除或播放这些已有内容。

[Release App](../artifacts/macos/20261019-180911/Hongguo.app) · [ZIP 安装包](../artifacts/macos/20261019-180911/Hongguo-macos-arm64.zip) · [SHA256](../artifacts/macos/20261019-180911/SHA256SUMS.txt)
