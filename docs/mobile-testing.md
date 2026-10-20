# 按平台验证，而不是把桌面窗口搬到手机

## 验证范围

| 验证层 | Mac 桌面 | Android 真机 | iPhone / iPad 模拟器 |
|---|---|---|---|
| 共享核心/API | 签名、解码、解密、缓存状态与损坏文件拒绝 | 复用同一 Dart 实现 | 复用同一 Dart 实现 |
| 真实窗口 UI | PC 多尺寸、选集覆盖、置顶小窗与还原 | 保留设备分辨率/DPR，不调用虚拟尺寸；手机底部选集、触控按钮、缓存入口 | 保留实际模拟器窗口；手机底部选集，平板宽布局覆盖选集 |
| 系统能力 | 实际窗口 API、实际本地原生传输 | 原生下载、媒体服务、系统 PiP、启动系统 Launcher 退后台后返回 | 实际原生插件调用；PiP 返回不支持时单列，不计通过 |
| 返回行为 | 窗口/页面操作 | 有权限才发送系统 Back；小米拒绝输入注入时记为未测，仍测 Flutter 触控关闭 | Flutter 触控关闭；不冒充系统侧滑返回 |

桌面虚拟 390/800/1280 尺寸只用于响应式回归，不能替代手机验收。测试中的 `_resizeDesktop` 在 Android/iOS 直接返回；移动截图同时断言渲染边界等于实际设备窗口尺寸，并输出 `REAL_MOBILE_VIEWPORT`。

合成目录与加密 MP4 避免依赖账号和上游可用性，生产下载/解密/播放器路径仍真实运行。目录接口的业务正确性、真实内容可用性不是这套离线测试的覆盖范围。

## 在当前 Mac 执行

```sh
python3 tool/verify_mobile.py --platform android \
  --device 192.168.0.4:38949 --output artifacts/mobile/android

python3 tool/verify_mobile.py --platform ios \
  --device 8CAD9D3D-DA70-4811-81A2-0E18EFEA6A8E --output artifacts/mobile/iphone
```

设备 ID 每次以 `flutter devices` 为准。iPad 直接传 iPad 模拟器 ID；不把平板强制改成手机尺寸。测试显式传入 `--no-uninstall`，避免 Flutter 默认在每次结束后卸载 App。安装失败也禁止自动卸载旧版本，保留已有数据。Android 测试自动编译、覆盖安装、运行并保存日志和系统操作 JSON，启动器退后台及返回均检查命令结果与真实前台 Activity。若要求物理系统 Back 必须可测，添加 `--require-system-back`，未授权时在开始前失败。

`tester.tap` 是 Flutter 集成测试注入的触控事件，能验收真实窗口布局、命中目标和组件行为，但不是物理手指/系统边缘手势测试。模拟生命周期回调与真正的系统退后台分别记录。系统强杀、锁屏长播、Doze、电池策略、电话打断、蓝牙切换、数小时下载仍需专项设备测试。

## 开发安装无需反复人工点 APK

```sh
python3 tool/install_android.py --device 192.168.0.4:38949
```

使用 `adb install --no-streaming -r -t`：先推送 APK，再由系统包管理器更新；保留应用数据，不通过文件管理器打开 APK，也不会自动卸载来规避签名或版本冲突。最初小米设备曾返回 `INSTALL_FAILED_USER_RESTRICTED`；用户要求重试后，安装及再次覆盖更新成功，随后完整真机回归也成功更新并保留 App。厂商授权仍是前提，不承诺所有设备无条件免确认。

自动化脚本为 Flutter 子进程提供临时 SDK 视图，仅替换 ADB 的安装调用为 `--no-streaming`；原 Android SDK、Flutter SDK 和全局配置均不修改，结束后恢复项目被忽略的 `local.properties`。Gradle 使用单次进程、Kotlin 使用进程内编译，避免守护进程保留临时 SDK 的失效路径；已验证隔离构建后可正常普通打包。Android 真机测试仅打包当前设备 ABI，正式 Release/CI 的多架构规则不变。如果 Flutter 全局显式配置了 `android-sdk`，脚本会拒绝启动，避免该配置绕过安装保护；本机未显式配置。SDK 位置默认本机 Mac 的 `~/Library/Android/sdk`，可用 `ANDROID_HOME` 指定其他位置。

这属于已授权开发设备的 ADB 安装；普通用户点击安装 APK 的系统确认不由 App 取消。脚本不关闭全局安装验证，不授予所有运行时权限，也不修改小米安全设置。[Android 官方 ADB 文档](https://developer.android.com/tools/adb)、[ADB `--no-streaming` 定义](https://android.googlesource.com/platform/packages/modules/adb/+/refs/tags/android-16.0.0_r4/docs/user/adb.1.md)。

实际结果见 [平台验收记录](evidence/platform-background/README.md)。
