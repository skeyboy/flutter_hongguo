# GitHub 私有仓库、五端验证和 Release

## Git 与发布顺序

主工程由本目录 Git 管理；[references/hongguo-web](../references/hongguo-web) 是上游 submodule，URL 为 `https://github.com/sunnysky123/hongguo-web.git`，初始固定提交 `2d88d4855d679cbed59c9237e1672bc5decf3d57`。`imports/` 保留此前迁入的独立 Dart 快照，不与主 workspace 混用。

克隆时使用 `git clone --recurse-submodules`，已有克隆执行 `git submodule update --init`。App 运行不依赖 Node 或 submodule 中的运行时代码。

横向筛选已先完成：48 项 App 测试、3 项 Mac 原生集成通过，见 [实现与截图](design/horizontal-filter-panel.md)。随后配置 CI：

1. main 推送或 PR：完整离线验证 → 五平台构建 → 保存构建附件，不创建 Release。
2. main 提交的平台矩阵通过后，推送与 pubspec 对应的 `v0.2.4` 标签。
3. 标签流程再次验证构建，恢复稳定 Android 发布密钥，检查安装包完整性。
4. 汇总附件并生成 SHA256/manifest，创建草稿，上传成功后发布到私有仓库 Releases。

[build.yml](../.github/workflows/build.yml) 支持 PR、main、手动验证和复用；[release.yml](../.github/workflows/release.yml) 仅由标签触发。Action 固定完整 SHA，PR/main 不读取发布签名密钥。

## 安装包

| 平台 | 架构 | Release 附件 |
|---|---|---|
| Android | arm64-v8a、armeabi-v7a、x86_64 | 三个验证签名的 APK |
| macOS | Apple Silicon arm64 | DMG、完整 App ZIP |
| Windows | x64 | Inno Setup 安装 EXE、包含播放器 DLL/VC runtime 的便携 ZIP |
| Linux | x64，Ubuntu 24.04 构建基线 | DEB、完整 bundle tar.gz |
| iOS | arm64 | 始终验证无签名设备编译；签名资料齐全并启用后附可安装 IPA |

Linux 需要 GTK、libsecret、libmpv 和系统钥匙串服务，DEB 声明运行库依赖。macOS 当前为 ad-hoc 签名且未 Apple 公证；Windows 未做 Authenticode 签名。私有 Release 附件下载需要仓库权限。

iOS 不把无签名 App/ZIP 当作可安装 IPA。没有 Apple 资料时，Release 的 `iOS-signing-status.txt` 及发布说明会明确没有 IPA；启用签名后，签名构建失败会阻止发布。IPA 仅能安装到 provisioning profile 覆盖的设备。

## 登录与上传

在本机登录，不要把 token 发到聊天或写入仓库：

```bash
cd /Users/lee/Desktop/flutter_hongguo
gh auth login --hostname github.com --web --scopes repo,workflow
./tool/publish_github.sh
```

脚本默认创建当前登录账号下的私有 `flutter_hongguo`，也可传入其他仓库名。已有目标必须私有，不覆盖不同的 origin。脚本配置 Android Secrets、推送 main、等待矩阵通过，再打标签并等待 Release。工作区不干净或任一步失败均停止，不强推或跳过校验。

仓库需要允许 Actions 并有可用 runner 配额；脚本不会修改账号计费。

## Android 长期签名

本机 `python3 tool/ci/configure_android_signing.py` 仅首次生成长期密钥，保存在 Git 忽略的 `artifacts/signing/android/`。应单独备份该目录，保留未来升级签名一致性。此前调试 APK 的签名与发布签名不同。

发布脚本将以下值写入目标仓库 Secrets，不提交密钥/密码：

- `ANDROID_KEYSTORE_BASE64`
- `ANDROID_STORE_PASSWORD`
- `ANDROID_KEY_PASSWORD`
- `ANDROID_KEY_ALIAS`

标签构建缺少任意值会失败，不退回 debug 签名。普通 PR/main 编译允许 debug 签名，但不会发布 Release。

## iOS 签名

在私有仓库配置自己的 Apple Distribution 证书和 profile：

| Secret | 内容 |
|---|---|
| `IOS_CERTIFICATE_BASE64` | p12 文件 base64 |
| `IOS_CERTIFICATE_PASSWORD` | p12 密码 |
| `IOS_PROVISION_PROFILE_BASE64` | profile 文件 base64 |
| `IOS_EXPORT_OPTIONS_BASE64` | ExportOptions.plist base64 |

ExportOptions 的 method 支持 `release-testing`、`ad-hoc`、`enterprise`。Team、bundle ID、profile 与证书必须一致；当前 iOS ID 为 `com.example.hongguoApp`。配置完成再设置仓库变量 `IOS_SIGNING_ENABLED=true`。

CI 使用临时 keychain，配置 Runner 的 Team/profile 后导出 IPA，结束后删除临时签名材料。工程修改使用 CocoaPods 提供的 xcodeproj Ruby gem。

参考：[Flutter iOS 发布](https://docs.flutter.dev/deployment/ios)、[GitHub runner 架构与标签](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)、[工作流附件](https://docs.github.com/en/actions/concepts/workflows-and-actions/workflow-artifacts)。

## 本地检查

```bash
./tool/verify_all.sh
python3 -m unittest discover -s tool/ci/tests -v
actionlint .github/workflows/build.yml .github/workflows/release.yml
```

本轮完整验证：核心 113、API 28、App 48 项测试；AOT/JS 各 103 向量、84 个媒体样本解密和 ffmpeg 解码；另有 4 项打包契约测试。静态检查通过不代表 GitHub 已运行，也不等于其他平台的设备验收。

发布构建不使用 `--no-pub`：此 SDK 会据此重新生成 Release 插件注册文件，排除 `integration_test` 等开发期插件。依赖先由 setup 步骤按 lockfile 校验。

## 本轮本机产物与证据

0.2.3 的 macOS DMG/ZIP、三架构 Android APK 已在本机构建，APK 签名与长期发布证书逐一匹配。安装包位于 Git 忽略的 `dist/`，包含 SHA256SUMS 和 manifest。Windows/Linux/iOS 的 GitHub 构建尚未执行；本机 CLI 和 SSH 均未通过 GitHub 认证，尚未创建私有远端或发布 Release。

[本轮验证摘要与日志](evidence/github-ci)。
