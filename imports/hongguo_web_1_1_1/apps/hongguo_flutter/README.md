# 红果 Flutter

原生默认直接调用共享 Dart 核心；Web 使用同一 Repository 契约对接远程 API。运行、构建、平台边界与测试证据见 [移植说明](../../docs/Dart-Flutter-implementation.md)。

```bash
flutter pub get
flutter run -d macos
```

上游模型有效且格式受支持时，选集后完整下载并在 worker isolate 中解密后播放。核心协议在 `../../packages/hongguo_core`，页面、原生/Web 适配和播放器控制分别位于 `lib/features`、`lib/adapters` 和 `lib/playback`。
