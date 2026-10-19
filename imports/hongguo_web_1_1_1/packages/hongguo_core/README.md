# hongguo_core

无 Flutter / dart:io 依赖的 Dart 协议、密码算法和 MP4 核心。公共入口为 `lib/hongguo_core.dart`；具体架构、已支持范围与验收记录见 [移植说明](../../docs/Dart-Flutter-implementation.md)。

```bash
dart pub get
dart analyze
dart test
```

通过 Transport、Clock、RandomSource、RandomAccessStore、KeyValueStore 注入平台能力。纯核心不会自行访问网络、文件或启动进程。来源声明见根目录 THIRD_PARTY_NOTICES.md。
