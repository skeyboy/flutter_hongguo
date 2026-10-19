# 独立原生 App：当前 Mac 验收

> 文档与源码目录见 [项目索引](README.md)；已有验收结果的持久化快照见 [证据索引](evidence/README.md)。

日期：2026-10-19。正式目标为 Android、iOS、macOS、Windows、Linux 五个原生端，共享 Dart 核心。本轮以当前 Mac 验收算法和真实单集播放 POC。

## 结论

本机已通过原生算法与真实单集播放 POC，并生成、签名校验、启动了可独立运行的 macOS Release App。媒体准备不经过 Node、旧本地 HTTP 服务或远程解密中转服务。

Release 主程序为 arm64 Mach-O；Dart 业务与算法 AOT 编译，播放器及其原生解码框架随 App 打包。用户双击 App 即可运行，不需要另装 Dart/Flutter/Node，也不调用外部 ffmpeg 程序。

## 环境

| 项目 | 本次值 |
|---|---|
| 系统 | macOS 27.0.1，26A434 |
| 架构 | Apple Silicon / arm64 |
| 工具链 | Flutter 3.47.4 / Dart 3.13.3 |
| 当前验收平台 | macOS；不把本机结果外推为其余原生端真机验收 |
| Release | `artifacts/macos/20261019-162900/Hongguo.app` |
| 压缩包 | `artifacts/macos/20261019-162900/Hongguo-macos-arm64.zip` |

## 算法 POC

运行已有原生 AOT 对拍程序，无需启动 Node：

```bash
./build/verification/native_oracle
```

结果：103 个正向向量通过，其中包括 96 组全部六个请求签名头的逐字节对拍，以及 spade、URL 解码和 AES-CTR 向量。Node 仅是历史开发期 oracle 的来源，不是当前 App 运行依赖。

证据：`build/verification/macos-algorithm-poc.log`。

## 真实单集 POC

本轮使用未替换的 NativeRuntime、真实内容 API、真实视频模型、Dio 下载、Dart 解密和 macOS 原生播放器。未注入模拟 HTTP 响应，未使用本地测试片代替真实视频。

| 检查 | 观测结果 |
|---|---|
| 真实目录 | 返回 17 条 |
| 剧集 | 《十年恩，一生还》 |
| series_id | `7697273659248872472` |
| 分集信息 | 返回 48 集；测试固定第 1 集 |
| vid | `7697275565593611289` |
| 模型 | 1080p，存在内容加密 |
| 本地普通 MP4 | 9,763,991 字节，约 9.31 MiB |
| 实际解码尺寸 | 1080 × 1920 |
| 时长 | 66,780 毫秒 |
| 音频 | 识别真实音轨，Mac 音频输出无设备错误 |
| seek | 目标 10,000 毫秒，实际位置 10,000 毫秒 |
| 图像证据 | 实际原生播放器成功提取 PNG 帧 |
| 本地媒体源 | App 私有支持目录 `media-cache/..._best.mp4` |
| 中转服务 | 无 |

音轨识别、设备无错误不等于人工听音测试；自动化测试将播放器静音。POC 的分集列表被限制为这一集，以避免测试时预热其他集。

执行过程分为：

1. 原生 Dart CLI 探测真实目录、详情、视频模型并准备这一集，独立保存可分析日志。
2. macOS 集成测试重新走 App 的真实 NativeRuntime，在沙盒目录准备同一 vid，打开实际 PlayerPage，检查本地文件、manifest、解码尺寸、音轨、seek 和退出。
3. 构建普通 `lib/main.dart` 的 Release，不将集成测试入口作为交付入口。
4. 启动交付 App，核对进程来自 Release bundle，并观察到真实目录/题材/封面页面。

证据：

- `build/mac-poc/live-probe.json`：CLI 请求/下载/解密结果。
- `build/verification/macos-live-playback.log`：真实原生播放集成测试通过。
- `build/mac-poc/app-live-result.json`：实际 App 播放、音轨、seek 结果。
- `build/mac-poc/mac-acceptance.json`：平台、算法、播放、Release 和进程汇总。
- `build/verification/macos-release-binary.txt`、`macos-release-linkage.txt`：架构与框架链接信息。

本次仅验证上述一集在当前时间与网络环境中的可用性；不据此承诺其他剧集、其他加密格式或未来上游接口均可用。

## 如何复测

所有命令从项目根目录执行。

真实上游的显式探测（普通离线回归不会执行）：

```bash
.fvm/flutter_sdk/bin/dart run packages/api/bin/mac_poc_probe.dart \
  "$PWD/build/mac-poc" --prepare
```

针对已知剧目第 1 集进行 Mac 真正播放验收：

```bash
./tool/verify_mac_live.sh 7697273659248872472 7697275565593611289
```

构建当前 Mac 的主入口 Release，只对这次命令选择 arm64，不修改全局 Flutter 配置：

```bash
cd packages/app
FLUTTER_MACOS_ARM64_ONLY=true ../../.fvm/flutter_sdk/bin/flutter build macos \
  --release --no-pub --target lib/main.dart
cd ../..
./tool/package_macos_release.sh
```

每次打包生成新的时间戳目录；App、ZIP 和 SHA256SUMS 均保留。最新路径记录在 `artifacts/macos/latest-release.txt`。打包脚本校验代码签名，不上传或公开发布任何文件。

## 本轮构建阻塞与处理

Release 首次因磁盘仅余约 106 MiB，明确报 `No space left on device`。本轮为新工程初始化 Git（无提交），通过项目 manifest、ignore 规则和无跟踪产物校验后，使用 cleanmymac 的白名单 `safe_rm` 仅清理本工程可重建目录：Android intermediates、重复 APK 输出、iOS build、test_cache，恢复约 3.9 GiB 可用空间。

源码、配置、测试日志、真实 POC 媒体和规范路径下已有 Android APK 均保留；未清理其他工程或用户文件。随后串行完成 Mac 播放测试及 arm64 Release 构建。

## 当前阶段范围

原生五端继续使用同一共享 Dart 核心。本轮交付重点是 Mac 独立 App 和单集可行性，不把原有 Web 远程适配作为主运行路径。后续可在此基线推进其他原生端验证、更多真实格式与播放体验。
