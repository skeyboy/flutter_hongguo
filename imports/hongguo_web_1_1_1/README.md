# hongguo-web Dart / Flutter 迁入版本

原工程的 Flutter 应用及纯 Dart 核心已完整迁至本目录；保持原有分层、测试和相对包依赖。此实现与目标仓库原有 `packages/core/api/app` 独立，不覆盖或混用同名 `hongguo_core` 包，也不加入根 workspace。

## 运行

从目标仓库根目录运行：

```bash
cd imports/hongguo_web_1_1_1/apps/hongguo_flutter
../../../../.fvm/flutter_sdk/bin/flutter pub get
../../../../.fvm/flutter_sdk/bin/flutter run -d macos
```

## 验证

从本目录执行 `./tools/verify_dart.sh`；脚本优先使用目标仓库的 FVM SDK。默认验证仅使用随源码迁入的离线测试样本，不依赖原 Node 工程。

- `apps/hongguo_flutter/`：Flutter 界面、原生/Web 适配、播放器。
- `packages/hongguo_core/`：models、crypto、upstream、media、services、ports。
- `tools/`：离线校验和开发期真值/播放器工具。
- `artifacts/macos/hongguo_flutter.app`：此前验收的独立 macOS 成品。
- [迁移记录](docs/migration.md) · [实现与验收说明](docs/Dart-Flutter-implementation.md)。

仅重新生成 Node 真值时需要原参考工程：`HONGGUO_NODE_ROOT` 可覆盖生成脚本记录的原路径，使用 PATH 中的 Node；运行 App 和普通回归不需要 Node。
