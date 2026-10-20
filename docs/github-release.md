# GitHub Actions 按需打包与附件上传

当前配置以安装包附件为目标，全部在 GitHub-hosted runners 执行。不依赖本机构建、等待 CI 后打标签、Node 服务或 self-hosted runner。

## 操作入口

进入仓库 **Actions**：

- **Build selected installer attachments**：只构建并上传 Actions 附件。默认 `platforms=["android"]`；可改为 `["macos"]`、`["windows","linux"]` 或四端数组。附件保留 **1 天**。
- **Publish selected installer attachments**：构建选中平台并把安装包、SHA256、manifest 上传到 Release。默认四端，iOS 默认关闭。

两者均可在 GitHub 网页点击 **Run workflow**。不再在 main push/PR 自动执行平台矩阵，避免一次修改、一次标签重复构建。版本标签 `v*` 仍可触发一次四端 Release；不要为同一次发布再手动启动另一条流程。

手动 Release 从所选分支的 pubspec 读取版本，创建对应标签；标签已指向不同提交时会在构建前拒绝。请先同时增加根目录与 App 的 pubspec 版本。Actions 使用 GITHUB_TOKEN 创建的标签不会再次触发标签工作流。

选项 `platforms` 是 JSON 数组，只接受 android/macos/windows/linux，不允许空值、重复或任意 runner 输入。未选平台不占用 runner，也不要求它的附件存在。不同提交不得覆盖同一版本；同提交重试可更新对应附件。

`tool/publish_github.sh` 仅作为兼容入口，提交后调用 workflow_dispatch；不再配置仓库、构建、推送或轮询。

## 保留的检查与已移除的步骤

保留：版本一致性、平台参数、5 项打包契约测试、Flutter lockfile、实际 Release 编译、Android 稳定签名校验、所选安装包存在性、SHA256。

移除默认路径中的完整单元/页面测试、AOT/JS 对拍、ffmpeg 验证、macOS 原生播放器/钥匙串集成、崩溃日志采集、无签名 iOS 构建。这是按需打包流程，**不再声称完整质量或设备验收通过**；需要完整验证时可另行本地执行 `./tool/verify_all.sh` 和 `./tool/verify_native.sh macos`。

不检出 submodule：原生打包不依赖参考项目。Git 中仍保留 `references/hongguo-web` 固定引用及来源说明。

## 平台与附件

| 平台 | Runner | 附件 |
|---|---|---|
| Android | ubuntu-24.04 | arm64-v8a / armeabi-v7a / x86_64 APK |
| macOS | macos-15 arm64 | DMG、完整 App ZIP |
| Windows | windows-2022 x64 | 安装 EXE、含依赖的便携 ZIP |
| Linux | ubuntu-24.04 x64 | DEB、完整 bundle tar.gz |
| iOS（显式勾选） | macos-15 arm64 | 签名 IPA |

普通附件构建的 Android 使用 debug 签名，仅供试装；Release 使用已有稳定发布密钥。macOS 当前为 ad-hoc 签名、无 Apple 公证，Windows 无 Authenticode 签名。Linux DEB 声明 GTK/libsecret/libmpv 依赖。私有仓库 Release 附件仍需仓库权限。

各平台安装包只构建一次，通过 Actions artifact 中转给发布 job，保留 1 天且压缩级别 0（安装包本身已压缩）。Release 附件长期提供下载；本轮不删除既有历史附件或缓存。Flutter/pub 缓存用于缩短后续安装时间，目前远端缓存约 6.1 GB，不缓存构建目录。

## 费用重估（2026-10-20）

采用 GitHub 官方标准 runner 超额单价：Linux x64 **$0.006/分钟**、Windows x64 **$0.010/分钟**、macOS **$0.062/分钟**，每个 job 向上取整到分钟。以下均为未扣免费额度、未含存储的估算，不能当作实际账单。

此前成功的 main 和标签运行分别为 `39273765901`、`39343019017`，按开始/结束时间计算。详见 [基准记录](evidence/ci-cost/baseline.json)。

| 场景 | 估算 runner 成本 |
|---|---:|
| 原 main 全矩阵 + 标签全矩阵 | 约 $1.04 / 版 |
| 新普通 push/PR | $0（不触发） |
| 新只构建 Android 附件 | 约 $0.05～0.08 / 次 |
| 新只构建 Linux 附件 | 约 $0.03～0.05 / 次 |
| 新四端 Release（无 iOS） | 约 $0.30～0.50 / 版 |
| 额外签名 iOS | 约增加 $0.19～0.62 / 次 |

四端单次估算假设：预检/上传合计约 2～3 Linux job 分钟，Linux 约 3～5 分钟，Android 约 7～10 分钟，Windows 约 5～8 分钟，macOS 约 2～4 分钟。冷缓存、下载波动、构建失败重试会增加费用。按每月 10 版计，旧约 $10.4，新约 $3～5；不需要全平台时按需选择可进一步降低。

中间 artifact 的额度按实际 GB·小时与账号计划计算。1 天保留比原 14 天减少约 93% 的同大小保留时长；缓存空间另计。Release 与 Actions artifact 是不同存储，不将 Release 文件体积当作 Actions artifact 长期保留。没有修改账户预算、收费开关或仓库可见性。

来源：[官方 runner 单价](https://docs.github.com/en/billing/reference/actions-runner-pricing)、[Actions 计费](https://docs.github.com/en/billing/concepts/product-billing/github-actions)、[Release 附件限制](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases)。

## 签名配置

已有 Android Secrets 继续使用：`ANDROID_KEYSTORE_BASE64`、`ANDROID_STORE_PASSWORD`、`ANDROID_KEY_PASSWORD`、`ANDROID_KEY_ALIAS`。本机 `artifacts/signing/android/` 为 Git 忽略的备份，工作流不生成新密钥。

需要 IPA 时设置仓库变量 `IOS_SIGNING_ENABLED=true`，配置：

- `IOS_CERTIFICATE_BASE64`、`IOS_CERTIFICATE_PASSWORD`
- `IOS_PROVISION_PROFILE_BASE64`
- `IOS_EXPORT_OPTIONS_BASE64`

然后手动发布时勾选 ios。缺少启用标记在构建前失败；不生成不可安装的“无签名 IPA”。导出 method 支持 release-testing/ad-hoc/enterprise；Team、bundle ID 和 profile 必须匹配。当前 iOS bundle ID 是 `com.example.hongguoApp`。临时 keychain 在结束时清理。

## 工作流检查

```bash
actionlint .github/workflows/*.yml
python3 -m unittest discover -s tool/ci/tests -v
```

未修改 App 功能，因此不重新构建本机五端或重复原生测试。远端验收会单选 Linux 验证附件上传，不为验证工作流重复运行四端。
