# 0.2.6 后台与悬浮能力验收

日期：2026-10-20。主工程 `/Users/lee/Desktop/flutter_hongguo`，本机执行；未触发 GitHub Actions 或付费构建。

## 共享与桌面验证

| 验证 | 结果 | 日志 |
|---|---|---|
| Dart 核心 | 114 项通过 | [core-tests.log](core-tests.log) |
| API/缓存 | 31 项通过 | [api-tests.log](api-tests.log) |
| App 单元/页面 | 65 项通过 | [app-tests.log](app-tests.log) |
| Mac 原生集成 | 初轮 7 项；最终 8 项通过（7 项实际执行） | [最终日志](macos-native-final.log) |
| CI 打包契约 | 5 项通过 | [ci-contract.log](ci-contract.log) |
| 静态分析 | 无问题 | [analyze.log](analyze.log) |
| Android debug 编译 | 通过 | [android-build.log](android-build.log) |
| iOS 模拟器编译 | 通过 | [ios-simulator-build.log](ios-simulator-build.log) |

Mac 实际验证置顶小窗、原窗口尺寸/置顶状态还原、同一播放器句柄，以及原生后台传输字节一致、下载记录不含明文密钥、记录清理。后台播放开关的 Mac 生命周期测试为直接调用生命周期回调，不冒充长时间系统睡眠测试。

## 移动端验证

Android 已连接真机：23113RKC6C，Android 16 / API 36；iOS 使用已启动的 iPhone 模拟器，iOS 27.0。测试素材为项目自带的合成加密 MP4，不依赖账号或外部视频接口。

iOS 首轮原生回归通过 7 项，其中桌面窗口和 Mac 钥匙串两项在移动平台提前返回，实际执行 5 项；包含解密播放/seek、跨布局预缓存复用、本地连播、缺集停止、原生系统下载。见 [ios-simulator-regression.log](ios-simulator-regression.log)。模拟器存在音频输出设备告警，因此不能据此宣称真机可听音频通过。

Android 测试发现 Debug 下载访问本机 HTTP 被拒绝，已仅在 debug 资源中放行 localhost，正式版本仍默认禁止明文 HTTP。画中画还原过渡尺寸导致的顶部按钮溢出已修复：仅在 PiP 退出后的短暂窗口过渡中，宽度小于 280 逻辑像素时只显示视频。

Android 首轮跨尺寸回归 8 项通过（两项为桌面平台提前返回）。这批记录只能证明共享逻辑、系统媒体处理器和原生 PiP 进入/退出，不能作为真实手机布局和 Home 系统动作的最终证据。旧外部脚本未检查 `input keyevent` 错误，小米拒绝 `INJECT_EVENTS` 权限，旧 Home 结论已撤销。新的真实屏幕脚本通过启动器 Intent 退后台，并校验目标 App 已不在前台；结果以 `real-viewport/` 为准。物理返回键权限不足时记录未验证，不计通过。

iPhone 模拟器专用测试完成，系统媒体处理器初始化成功，模拟生命周期关闭开关可暂停；PiP API 明确返回不支持，故**不计为 iOS PiP 通过**。见 [ios-mobile.log](ios-mobile.log)。这项测试的生命周期部分是模拟调用，未声称实际 Home 退后台。

[iPhone 真实窗口设置截图](../../assets/platform-background/ios-settings.png) · [真实底部选集截图](../../assets/platform-background/ios-episodes.png)。

短时 Home 测试不代表锁屏、Doze、省电模式、强杀和数小时后台稳定性；这些仍需独立长时验收。iOS 模拟器 PiP 支持情况以实际返回为准，不将不支持记录成通过。

## 安装策略修正

当前 Flutter 3.47.4 的 `flutter test` 默认 `uninstall=true`；新脚本显式设置 `--no-uninstall`，ADB 包装器也拒绝自动卸载。小米仍可能拒绝安装（`INSTALL_FAILED_USER_RESTRICTED`），不能宣称仅使用 `--no-streaming` 就能无条件免确认。需要设备先授权开发者安装；物理系统 Back 另需允许输入注入。详见 [测试与安装方案](../../mobile-testing.md)。

## 按真实窗口重跑

iPhone 模拟器 8 项通过（6 项实际执行，桌面窗口/Mac 钥匙串两项提前返回），截图边界与实际设备窗口相等，日志输出实际分辨率和 DPR，没有虚拟 PC 尺寸。见 [真实窗口日志](real-viewport/ios-device.log)。PiP 不支持、模拟器声音告警单独保留，不当成完整 iOS 后台能力通过。

Android 最终真实窗口回归 9 项通过（7 项实际执行，两项桌面/Mac 专用提前返回）。设备为 1440×3200 / DPR 3.5，没有尺寸覆盖。[最终日志](real-viewport/android-device.log)、[系统操作记录](real-viewport/android-system-operations.json)。Launcher Intent 确实使 App 离开前台；后台下载、持续播放、系统 PiP 持续播放及还原通过。物理 Back 因输入权限不足仍未验证。

iPad 模拟器按实际 2752×2064 / DPR 2.0 宽屏重跑 8 项通过（6 项实际执行），见 [iPad 日志](ipad-real-viewport/ios-device.log)。使用实际平板覆盖式选集，不强制手机尺寸。PiP 仍返回系统不支持。

最终 Mac 原生回归也已按平台分支通过：PC 保留多尺寸响应式检查，移动专用测试提前返回；原生置顶/窗口还原及后台传输均实际执行。iPhone / iPad 模拟器已恢复安装普通 App，不留在测试入口。

普通入口 Android arm64 调试包位于 `artifacts/android/hongguo-0.2.6+8-arm64-debug.apk`；[摘要与 SHA-256](android-normal-apk.json)。用户要求重试后，安装及再次覆盖更新均成功；测试保留 App，不再自动卸载。

真实后台验证发现并修复 Video 组件默认自动暂停与页面设置冲突，统一由页面处理后台/PiP 生命周期。下载在后台完成时以暂停状态打开文件，不会绕过后台播放开关。Android 截图改用设备 compositor 的 screencap，避免原生纹理的 GPU 回读阻塞。

最终修正后，iPhone 模拟器两项边界测试通过，见 [日志](ios-boundaries.log)；Mac 置顶还原及准备完成保持暂停两项通过，见 [日志](mac-boundaries.log)。生命周期模拟调用与真实 Android 系统退后台分别记录，未混算。

测试 SDK 视图采用单次 Gradle/Kotlin 进程，防止守护进程缓存失效的 SDK 路径；[隔离构建](sdk-isolation-build.log)及之后的普通 [Android](android-normal-build.log)、[iOS](ios-normal-build.log)、[Mac](mac-normal-build.log) 打包全部通过。最新普通 Android App 已覆盖安装成功并启动，[安装日志](android-final-install.log)。未触发付费 GitHub 构建。
