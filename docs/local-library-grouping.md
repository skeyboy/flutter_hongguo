# 0.2.2：本地缓存按剧目展示

本地缓存入口改为首页同款封面网格：每部剧一张卡片，点击后查看本地分集，再选择清晰度文件播放或删除。主代码位于新项目 `packages/app`；[实施前设计](design/local-library-grouping.md)。

## 展示与交互

- PC 展示多列卡片；手机保持两列。支持按剧名或视频 ID 搜索。
- 卡片显示剧名、离线封面、已缓存/总集数和体积，按最近缓存时间排列。
- 分集页按集号排序，显示分集标题、清晰度、大小和占用状态。同一视频的多个清晰度计为一集、多个文件。
- 同名但 series ID 不同的剧不合并。缺少可靠映射的文件统一放入“待识别视频”，这一入口不是一部虚构剧目。
- 播放仅打开选中的本地 MP4；保留文件引用和删除保护，不查询片源、不下载视频、不自动预缓存。

## 剧目资料缓存

原来只在播放时记录详情，并会用新结果整体替换旧记录；新实现从详情请求成功时就保存标题、封面、简介、分集 ID/集号/标题。首页资料可补充详情缺失字段，详情页传入播放器的也是合并后的资料。

同一剧目的部分分集更新不会抹掉兄弟分集，空标题/封面不会覆盖已有内容；剧目资料独立于目录快照的 7 天过期和 80 条上限。增加分集 ID 索引与批量读取，同一剧的详情在一次缓存枚举中只反序列化一次。若一个视频出现在不同剧的资料中，不猜测归属。

正常视频准备完成后，封面使用不带会话头的独立客户端缓存；单图最多 2 MB、图片缓存总量最多 32 MB，临时文件完成后原子发布。封面 URL 变化使用不同缓存文件；图片失败不阻止视频播放。列表直接读取本地图片，没有本地图时显示剧名占位图，不在离线入口偷偷请求远程海报。

设置中的视频空间统计仍是 MP4 大小；图片缓存独立受 32 MB 上限控制。

## 旧缓存补全

“补全剧目信息”提供按剧名搜索与已有目录候选。选择剧目后获取目录详情，只有其中的分集 ID 与本地视频匹配时才保存归类。不能仅凭标题相似、相邻 ID 或文件顺序推断。

这一操作只补全剧目资料和封面，不下载、解密或改写视频文件。没有任何可匹配资料的旧文件仍可通过“待识别视频”直接离线播放。

## 源码位置

| 职责 | 文件 |
|---|---|
| 剧目归类、计数与分集排序 | [local_library.dart](../packages/app/lib/catalog/local_library.dart) |
| 资料合并、持久化与视频索引 | [library_cache.dart](../packages/app/lib/catalog/library_cache.dart) |
| 封面缓存 | [artwork_cache_native.dart](../packages/app/lib/catalog/artwork_cache_native.dart) |
| 剧目网格与本地分集页 | [local_cache_page.dart](../packages/app/lib/features/local_cache_page.dart) |
| 旧缓存资料搜索与匹配 | [cache_metadata_page.dart](../packages/app/lib/features/cache_metadata_page.dart) |
| 首页与缓存共用卡片/封面组件 | [library_page.dart](../packages/app/lib/features/library_page.dart) |
| 在播放前保存合并资料 | [detail_page.dart](../packages/app/lib/features/detail_page.dart) |
| 原生资料、封面和完成文件关联 | [runtime_native.dart](../packages/app/lib/platform/runtime_native.dart) |

## 验证

| 验证证据 | 结论 | 对应路径 |
|---|---|---|
| 分组单测：同剧多分集/多清晰度、同名不同 ID、未知文件 | 集数不重复计算，不混合不同剧 | `test/local_library_test.dart` |
| 资料单测：部分更新、空字段、重启、目录清空、歧义 ID | 已有标题、封面和兄弟分集保留 | `test/library_cache_test.dart` |
| 页面测试：详情未播放时持久化、匹配/不匹配、占用/删除 | 资料补全真实生效，删除后剧目卡片更新 | `test/interaction_cache_test.dart` |
| 封面单测：重启、去重、过大/HTML 响应、请求头 | 无会话头，失败不发布坏缓存文件 | `test/artwork_cache_test.dart` |
| Mac 原生：网格→分集→本地解码、原有 5 集预缓存 | 离线播放不增加下载，原有预缓存回归通过 | `integration_test/offline_playback_test.dart` |

本轮重新运行 **42 项 App 单元/页面测试、3 项 Mac 原生集成**，全部通过；静态分析无问题。共享算法和 API 未修改，此轮未重复其他平台设备测试。

[测试日志与摘要](evidence/local-library-update)。原生测试截图使用明确标记的离线验证素材：

- [手机剧目卡片](assets/local-library/hongguo-local-cache-mobile-ui.png)
- [PC 剧目列表](assets/local-library/hongguo-local-cache-pc-ui.png)
- [本地分集页](assets/local-library/hongguo-local-episodes-mobile-ui.png)

## 复测

```bash
cd /Users/lee/Desktop/flutter_hongguo
.fvm/flutter_sdk/bin/dart analyze --fatal-infos
(cd packages/app && ../../.fvm/flutter_sdk/bin/flutter test --no-pub)
./tool/verify_native.sh macos
```

## 独立安装包

macOS arm64 0.2.2（build 4）已构建并通过签名校验。[App](../artifacts/macos/20261019-182611/Hongguo.app) · [ZIP](../artifacts/macos/20261019-182611/Hongguo-macos-arm64.zip)。

## 已有缓存实测

在 0.2.2 独立包中使用“补全剧目信息”，通过分集 ID 匹配现有《十年恩，一生还》的 6 集，形成带本地封面的剧目卡片。现有 15 个 MP4（14 个不同视频，包含清晰度变体）的文件集合和大小均未变化；另外 8 个无法确认归属的视频保留在“待识别视频”。测试过不匹配候选会被拒绝，不写入错误归类。详见 [已有缓存补全记录](evidence/local-library-update/existing-cache-repair.json)。
