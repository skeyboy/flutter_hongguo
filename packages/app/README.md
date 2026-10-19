# hongguo_app

主 workspace 的 Flutter 宿主应用。原生端通过共享 Dart 核心取内容、准备本地 MP4，再交给 media_kit 播放。

- `lib/main.dart`：正常 App 入口。
- `lib/bootstrap.dart`：GetIt / Riverpod 依赖装配。
- `lib/features/`：常驻筛选的首页/分类/搜索、设置、本地缓存剧集、详情选集和播放器。
- `lib/catalog/library_cache.dart`：缓存优先的目录快照与离线剧集元数据。
- `lib/platform/`：原生私有目录与媒体 runtime、平台契约及可选 Web 远程适配。
- `test/`：页面与交互测试。
- `integration_test/offline_playback_test.dart`：离线原生播放验收。
- `integration_test/macos_live_poc_test.dart`：显式启用的 Mac 真实上游单集验收。
- `android/`、`ios/`、`macos/`、`windows/`、`linux/`：原生宿主工程。

从本目录运行当前 Mac App：

```bash
../../.fvm/flutter_sdk/bin/flutter run -d macos
```

不要把集成测试入口当作正常 App 入口；Release 使用 `lib/main.dart`。

[文档总索引](../../docs/README.md) · [代码对应表](../../docs/project-map.md) · [当前 Mac 验收](../../docs/macos-independent-app-poc.md)

[0.2.1 交互、主题与缓存验收](../../docs/interaction-cache-validation.md)

[0.2.2 按剧目展示本地缓存](../../docs/local-library-grouping.md)
