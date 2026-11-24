# iOS / macOS `pod install` 失败修复手册

> 记录日期：2026-11-24。适用：在本机 macOS 上为 `packages/app` 的 iOS / macOS 工程执行 `pod install`。

## 0. 直接照做（TL;DR）

在**仓库根目录**依次执行：

```bash
cd /Volumes/PSSD/own/flutter_hongguo

# 1) 用工程指定版本的 Flutter 重新解析依赖（关键）
/Users/lee/fvm/versions/3.47.4/bin/flutter pub get

# 2) 在 app 包内重建 iOS 生成配置（会顺带跑一次 pod install）
cd packages/app
/Users/lee/fvm/versions/3.47.4/bin/flutter build ios --config-only --no-codesign

# 3) 两端分别安装 Pod
cd ios   && pod install && cd ..
cd macos && pod install && cd ..
```

验收标准：iOS 输出 `Pod installation complete! There are 16 dependencies ... 16 total pods installed.`；macOS 输出 `... 15 dependencies ... 15 total pods installed.`；两条命令退出码均为 0。

> 注意：不要用本机默认的 `flutter`（`/Users/lee/develop/flutter`）。它是 Flutter 3.41.4 / Dart 3.11.1，低于工程要求的 Dart `>=3.13.0`。工程版本记录在根 `.fvmrc`（`3.47.4`），对应 Dart 3.13.3。
>
> 本机的 `fvm` CLI 目前因 Kernel 版本不匹配无法直接运行（提示 `Can't load Kernel binary`），所以命令里写死 SDK 绝对路径。

## 1. 症状

| 端 | 报错 | 出现位置 |
|---|---|---|
| iOS | `Invalid "Podfile" file: cannot load such file -- .../C:\Users\lee\Documents\developments\fvm\versions\stable/packages/flutter_tools/bin/podhelper` | `ios/Podfile` 第 26 行 `require ... podhelper` |
| macOS | `No podspec found for \`audio_service\` in \`Flutter/ephemeral/.symlinks/plugins/audio_service/darwin\`` | `pod install` 的 Analyzing dependencies 阶段 |

## 2. 根因

不是 Podfile 写错，而是**仓库里残留了 Windows 环境生成的 Flutter 中间产物**：

- `packages/app/ios/Flutter/Generated.xcconfig` 里的 `FLUTTER_ROOT=C:\Users\lee\Documents\developments\fvm\versions\stable`、`FLUTTER_APPLICATION_PATH=W:\own\...`。Podfile 通过它定位 Flutter SDK，得到的却是 Windows 路径，导致 `podhelper.rb` 加载失败。
- `packages/app/.flutter-plugins-dependencies` 里 15 个 macOS 插件的路径全部指向 `C:\Users\lee\AppData\Local\Pub\Cache\hosted\pub.dev\...`。`podhelper` 按这些路径建 symlink，得到的断链目录没有 podspec，于是 `audio_service` 等插件解析失败。

这些文件都是生成物、已被 `.gitignore` 忽略；**修复方式是重新生成，不是手改 Podfile 或手动补 symlink**。

## 3. 分步说明

### 3.1 刷新插件依赖映射

```bash
cd /Volumes/PSSD/own/flutter_hongguo
/Users/lee/fvm/versions/3.47.4/bin/flutter pub get
```

作用：重新解析 workspace 依赖，把 `packages/app/.flutter-plugins-dependencies` 中的插件路径改为本机 `~/.pub-cache/hosted/pub.dev/...`。

核对：

```bash
grep -c 'C:' packages/app/.flutter-plugins-dependencies || true   # 期望 0
```

### 3.2 刷新 iOS 生成配置

单纯 `pub get` **不会**重写已经存在的 `Generated.xcconfig`，需要触发一次 Xcode 配置生成：

```bash
cd /Volumes/PSSD/own/flutter_hongguo/packages/app
/Users/lee/fvm/versions/3.47.4/bin/flutter build ios --config-only --no-codesign
```

作用：重写 `ios/Flutter/Generated.xcconfig`、`ios/Flutter/flutter_export_environment.sh`，写入本机 `FLUTTER_ROOT` / `FLUTTER_APPLICATION_PATH` 等；该命令内部也会自动执行一次 `pod install`。

核对：

```bash
grep -E 'FLUTTER_ROOT|FLUTTER_APPLICATION_PATH' \
  /Volumes/PSSD/own/flutter_hongguo/packages/app/ios/Flutter/Generated.xcconfig
```

期望：

```
FLUTTER_ROOT=/Users/lee/fvm/versions/3.47.4
FLUTTER_APPLICATION_PATH=/Volumes/PSSD/own/flutter_hongguo/packages/app
```

### 3.3 重新执行两端 pod install

```bash
cd /Volumes/PSSD/own/flutter_hongguo/packages/app/ios && pod install
cd /Volumes/PSSD/own/flutter_hongguo/packages/app/macos && pod install
```

`flutter_install_all_macos_pods` 每次都会根据刷新后的 `.flutter-plugins-dependencies` 删除并重建 `macos/Flutter/ephemeral/.symlinks/plugins/`，因此 macOS 的断链 symlink 无需手动清理。

## 4. 可以安全忽略的残留警告

执行成功后仍可能看到下面两类输出，均不影响安装与构建：

1. **`Invalid key/value pair: DART_DEFINES=...`（macOS，约 20 行）**：来自 Flutter 自带 `podhelper.rb` 的 `flutter_parse_xcconfig_file`，它用 `line.split('=')` 解析 xcconfig；`DART_DEFINES` 的 base64 值末尾带 `==`，被误判为非法行。Flutter 3.47.4 / 3.47.8 均有此问题，属于上游工具缺陷。
2. **CocoaPods did not set the base configuration...**：Flutter 模板用 `#include? "Pods/Target Support Files/Pods-Runner/Pods-Runner.<config>.xcconfig"` 间接引入 Pods 配置，CocoaPods 只检查直接引用故给出提示。iOS 的 Profile 配置还会因 `Flutter/Release.xcconfig` 未单独 include profile pods 配置而多一条提示。

不要为了消除这些警告去改 `Podfile` 或 Flutter SDK 文件；升级 Flutter 后工具行为可能变化，改动反而会积累维护成本。

## 5. 新 checkout 完整配置（macOS）

以下假设 clone 到 `/Volumes/PSSD/own/flutter_hongguo`。**按顺序执行，不要跳步**。

### 5.1 前置检查

```bash
xcode-select -p                                          # 有 Xcode 路径输出
pod --version                                            # 本机 1.17.0 可用
/Users/lee/fvm/versions/3.47.4/bin/flutter --version      # 末行应为 Dart 3.13.3
```

若本机还没有 3.47.4 SDK：正常用 `fvm install 3.47.4`；本机的 `fvm` CLI 当前因 Kernel 版本不匹配不可用，需先修复 CLI 或手动准备该 SDK 目录。

### 5.2 Clone 并绑定 Flutter SDK

```bash
git clone https://github.com/skeyboy/flutter_hongguo.git /Volumes/PSSD/own/flutter_hongguo
cd /Volumes/PSSD/own/flutter_hongguo

# fvm CLI 可用时：fvm install && fvm use 3.47.4
# 本机 CLI 不可用时，手动建软链（新 checkout 中它不存在）
ln -s /Users/lee/fvm/versions/3.47.4 .fvm/flutter_sdk

.fvm/flutter_sdk/bin/flutter --version
```

`.fvm/flutter_sdk` 是 gitignored 的软链，不会随 clone 带过来。若该路径已存在且指向别的版本，用 `fvm use 3.47.4` 或先 `unlink .fvm/flutter_sdk`（只删软链，不删 SDK）再建链。**不要**用系统 `flutter`（当前是 3.41.4 / Dart 3.11.1，低于工程要求的 Dart ≥3.13）。

参考工程是 submodule，仅做源码对照，构建不需要；需要时执行：

```bash
git submodule update --init --recursive
```

### 5.3 解析依赖并生成原生配置

```bash
# 仓库根目录：刷新 workspace 依赖与插件映射
.fvm/flutter_sdk/bin/flutter pub get

# app 包：生成两端原生配置
cd packages/app
../../.fvm/flutter_sdk/bin/flutter build ios --config-only --no-codesign
../../.fvm/flutter_sdk/bin/flutter build macos --config-only
cd ../..
```

- iOS 的 config-only 内部会顺带执行一次 `pod install`；macOS 的会生成 ephemeral 配置与 symlink。
- 这两步必须在 `pub get` 之后，否则仍可能拿到旧的插件路径。

### 5.4 显式安装 Pod

```bash
cd packages/app/ios   && pod install && cd ../../..
cd packages/app/macos && pod install && cd ../../..
```

验收输出分别为 `16 dependencies ... 16 total pods installed.` 与 `15 dependencies ... 15 total pods installed.`；第 4 节的警告可以忽略。

### 5.5 运行与验证

```bash
cd packages/app
../../.fvm/flutter_sdk/bin/flutter run -d macos
# iOS：../../.fvm/flutter_sdk/bin/flutter run -d <ios-device-id>
# Android：必须显式带 --flavor mobile 或 --flavor tv
```

完整门禁（可选，需 `node`；`ffmpeg`/`ffprobe` 缺失时会跳过媒体解码检查）：

```bash
cd /Volumes/PSSD/own/flutter_hongguo && ./tool/verify_all.sh
```

### 5.6 若从旧机器拷了生成物

出现 `C:\...` 路径报错时，先清掉旧生成物再回到 5.3：

```bash
cd packages/app && ../../.fvm/flutter_sdk/bin/flutter clean && cd ../..
```

**不要**把 `Flutter/Generated.xcconfig`、`macos/Flutter/ephemeral/`、`.symlinks/` 等生成物从 Windows 拷到 macOS，也不要手工编辑其中的路径——下次 Flutter 工具运行会覆盖它们。

## 6. 本次修复对仓库的实际影响

- `Podfile`（iOS/macOS）未修改。
- 重新生成并被 git 跟踪的文件：`packages/app/ios/Podfile.lock`（原先被删除，现按本机解析结果重建）。
- 重新生成但被 gitignore 忽略的文件：`packages/app/.flutter-plugins-dependencies`、`packages/app/ios/Flutter/Generated.xcconfig`、`flutter_export_environment.sh`、`packages/app/macos/Flutter/ephemeral/` 下的配置与 symlink。
- 验证结果：iOS `pod install` 成功（16 pods），macOS `pod install` 成功（15 pods）。
