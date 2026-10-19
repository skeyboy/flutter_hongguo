# 目录迁移记录

日期：2026-10-19。

本次将 `/Users/lee/Downloads/hongguo-web-1.1.1-macOS-arm` 中创建的 Dart / Flutter 实现迁至用户指定仓库下：

`/Users/lee/Desktop/flutter_hongguo/imports/hongguo_web_1_1_1/`

目标仓库已有另一套 `packages/core`、`packages/api`、`packages/app`，其核心包也名为 `hongguo_core`。本次采用独立迁入工程，保留这两套实现的边界，未覆盖已有实现或更改其 workspace 成员、依赖声明。目标根 README 增加迁入入口。

## 迁入内容

- `apps/hongguo_flutter/`：Flutter 平台工程、lib、test、tool、包声明与锁文件。
- `packages/hongguo_core/`：models / crypto / upstream / media / services / ports，以及全部测试与 fixture。
- `tools/`：验证、Node oracle 生成、合成媒体生成和 macOS 播放冒烟脚本。
- `docs/`：原可行性分析、实现/验收说明、既有验证摘要与实际解码帧。
- `artifacts/macos/hongguo_flutter.app`：此前验收的常规 release 成品，迁移后未重新编译。
- 来源与许可声明、迁入工程入口及独立分析配置。

应用和核心包使用移动操作迁入；原路径不保留代码副本。原 Node / Web 源码保留，原实施文档改为新位置的入口，原可行性文档增加迁移说明。

## 路径适配

应用到核心包的相对路径与测试 fixture 布局保持不变。清理旧 `.dart_tool` 并重新解析依赖；清理旧 SDK 编译的测试资源，消除旧 shader 与新引擎不兼容。普通运行与回归均不依赖原 Node 工程。

验证脚本优先使用目标仓库 `.fvm/flutter_sdk`。迁移后的 Flutter SDK 为 3.47.4 / Dart 3.13.3。新 SDK 更新 Flutter 自带测试依赖对应的锁定版本和生成分析配置，未改动 lib、test 或应用 Dart 工具源码。

Node 真值/媒体生成脚本通过 `HONGGUO_NODE_ROOT` 定位原参考工程，默认值记录原路径；播放器验证脚本使用 PATH 中的 Node，不再假设迁入目录自带 Node runtime。

## 验证结果

- 48 个 lib/test/tool/fixture 文件的 SHA-256 与移动前一致，清单为 `migration-source-hashes.json`。
- 核心包：静态分析无问题，69 项测试通过。
- Flutter：静态分析无问题，8 项测试通过。
- 两个 shell 脚本语法与两个 Node 生成脚本语法检查通过。
- 既有目标 workspace 三个包的源码未改动；本次未重跑其原有测试。
- 本次只验证迁移后的依赖、分析与离线回归；未重新执行各平台打包或在线上游检查。历史验收结果保留其原时点。

运行入口见上级 [README](../README.md)。
