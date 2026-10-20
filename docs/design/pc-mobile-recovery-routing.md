# PC / Mobile：失败恢复、续播、路由与封面

本轮沿用 TV 已接入的共享网络重试、个人播放记录及图片组件，补齐 PC/mobile 的业务路由和恢复交互。没有为各平台复制一套进度或配置存储。

## 交互规则

| 场景 | PC | 手机 |
| --- | --- | --- |
| 首次数据失败 | 明确错误和手动重试 | 同一错误/重试，不将错误当作空列表 |
| 已有列表刷新失败 | 保留内容和滚动操作，点击重试刷新 | 保留缓存，可继续点选，避免空白等待 |
| 题材失败 | 面板独立重试，影视列表不被阻塞 | 同样独立重试；加载中禁用重复请求 |
| 详情网络失败 | 有本地元数据则展示并提示重试刷新 | 同样保留可读信息；没有快照才显示错误页 |
| 返回 | 标准返回、Alt+左箭头，播放页仍保留原 Esc 层级 | 系统返回与页面返回进入同一路由栈 |
| 续播 | 详情显示继续观看/重新观看及上次集数 | 同一记录，缓存观看也恢复进度 |
| 封面失败 | 图片内独立重试，不触发卡片导航 | 标准触摸按钮重试；本地图片不退回网络 |

网络底层共用 `NetworkRetry` 的有界只读重试：首次请求加最多三次重试，默认间隔 1/2/4 秒；仅针对临时网络、部分服务器状态或明确不完整响应。达到上限后交给页面手动重试；不无限循环。分页失败保留已有项并暂停自动加载，用户可手动重试。

## 路由管理

使用已锁定的 auto_route 11.2.0，采用与 TV 相同的 `RootStackRouter.build + NamedRouteDef`，不增加代码生成步骤。PC/mobile 通过 `MaterialApp.router` 注册系统返回分发。路由实例在主题、系统语言、设置和 runtime 加载状态变化时保持稳定。

| route name | path | 页面 |
| --- | --- | --- |
| Catalog | / | 发现、分类、我的所在的主界面 |
| DramaDetail | /detail | 剧集详情 |
| VideoPlayer | /player | 统一播放器 |
| AppSettings | /settings | 设置 |
| LocalCache | /cache | 按剧目归组的缓存 |
| LocalEpisodes | /cache/episodes | 本地剧集 |
| CacheMetadata | /cache/metadata | 缓存元数据修复 |

`pushAppPage<T>` 提供统一命名枚举、页面构建参数和返回值。对话框与底部选集仍是临时 Flutter route，不被当作业务页面；现有 PopScope 管理播放器的面板/全屏层级。主界面三种视图保留原有状态管理，避免切换后丢失筛选和滚动位置。TV 的独立路由及单独挂载页面的 widget 测试使用兼容分支，不接入 PC/mobile 根路由。

这是原生 App 的内存参数路由，不宣称实现了从外部 URI 重建含 runtime/视频元数据的页面或进程重启后还原路由栈。

## 播放进度

沿用共享个人库的“每部剧最近记录 + 每集记录”。进入详情的主播放按钮会定位最近一集；明确点选集号只恢复该集自己的位置，不串用其他分集进度。视频准备、重试及清晰度切换会先保存/等待旧记录提交，再读取播放起点。已完成的集从头重看。

原生播放用 `Media.start` 设置起播位置，避免 open 后立即 seek 的加载竞争。暂停、切集、后台、退出补存；常规播放最多每 10 秒提交一次。本地路径重新校验缓存，缺失时不会擅自联网。PC/mobile 清晰度切换保留之前的播放/暂停状态。详情返回后重新展示最新续播提示。

## 异步封面

共用 `widgets/drama_cover.dart` 和 cached_network_image 4.0.4，在线图片使用库管理的内存/磁盘缓存。按布局像素和设备像素比限制内存解码宽度（上限 1600），有固定尺寸占位和加载提示，不随图片加载推动卡片布局。140ms 渐入，减少动画模式关闭渐变和旋转提示。

失败后图片内出现“重试加载封面”；点击只淘汰该 URL 的缓存并重建图片组件，不刷新影视列表。显式本地 ImageProvider 优先；`allowNetwork=false` 时绝不创建网络图片组件。图片缓存与加密视频缓存是两个不同的存储域。

参考：[auto_route 官方包文档](https://pub.dev/packages/auto_route)、[cached_network_image 官方 API](https://pub.dev/documentation/cached_network_image/latest/)。`flutter_cache_manager` 与 `file` 是已有传递依赖，本轮显式列为 dev dependency 以测试异步失败、重试、解码和离线边界。

## 验证与边界

日志位于 `docs/evidence/pc-mobile-recovery/`。路由用例覆盖手机系统返回和桌面 Alt+左箭头，以及详情/设置返回后仍复用主列表实例。数据用例覆盖已保存详情、手动刷新、独立题材恢复。图片用例使用可控缓存和真实 PNG 解码，验证失败后的独立重试以及本地模式不取网络图片，不是外网速度基准测试。

macOS 原生路由/续播用例使用确定性本地加密视频，经过实际解密及播放器起播、暂停、返回；不将桌面虚拟手机尺寸截图当作 Android/iOS 真机验证。旧的综合截图用例在设置页滚动步骤停滞后已中止，不计为通过；本轮采用有界、针对路由和续播的原生用例验证。

### 本轮通过的验证

- 应用层 117 项通过，1 项 TV 构建专用用例条件跳过；最终改动后路由/恢复/图片 5 项复核通过。
- API 层 44 项通过；应用静态检查通过。
- macOS 原生与 Android 真机各 1 项路由/播放用例通过：从详情“继续观看”定位第 2 集，读取约 700ms 进度，暂停补存；逐级返回后保持同一个主列表实例。两者均使用真实播放器。
- Android mobile arm64 Debug 正常入口重新构建并更新安装真机；macOS Debug 正常入口也已重新构建。没有卸载原 App。APK 校验值见证据目录，构建文件位于 `artifacts/android/hongguo-0.2.7+9-routed-arm64-debug.apk`。
- iOS / Windows / Linux 本轮未运行原生测试，不能把共享 Dart 测试等同于这些平台的原生验证。

若刚从 TV 构建切回 Android 手机测试且 mobile APK 不存在，先执行 `flutter build apk --debug --flavor mobile --target-platform android-arm64 -t lib/main.dart`，再运行手机 integration test；否则 Flutter 工具可能无法从 flavor overlay 发现启动 Activity。
