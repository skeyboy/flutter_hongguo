# hongguo_core

主工程的共享 Dart 算法包。

- `lib/hongguo_core.dart`：签名、URL 解码、Spade、摘要/AES、MP4 算法与离线诊断；不依赖 Flutter 或 dart:io。
- `lib/hongguo_native.dart`：原生文件随机读写与 isolate 解密入口。
- `lib/src/crypto/`：算法实现。
- `lib/src/media/`：MP4 解析、解密与文件适配。
- `test/`：Node oracle 对拍、MP4 用例及离线媒体样本。

从本目录运行：

```bash
../../.fvm/flutter_sdk/bin/dart test
```

[分析与源码对应表](../../docs/project-map.md) · [实现报告](../../docs/native-playback-pipeline.md) · [文档索引](../../docs/README.md)
