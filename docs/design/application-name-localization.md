# 应用显示名称国际化

应用显示名称跟随操作系统的语言偏好，独立于当前固定为中文的内容界面。未支持的语言回退到 English；Flutter 标题按系统语言列表寻找首个受支持语言。

| 语言 | 显示名称 | 匹配规则 |
| --- | --- | --- |
| 简体中文 | 红果剧场 | zh、zh-Hans、CN、SG |
| 繁体中文 | 紅果劇場 | zh-Hant、TW、HK、MO；显式 Hans 优先 |
| English | Hongguo | en 及默认回退 |

## 各平台入口

| 平台 | 实现 | 生效位置 |
| --- | --- | --- |
| Flutter | `packages/app/lib/localization/application_name.dart` | MaterialApp 标题；运行时监听系统语言变更 |
| Android 手机 | `@string/app_name` 与 values/values-zh/values-b+zh+Hant | 系统启动器名称 |
| iOS | Runner 下三组 InfoPlist.strings，注册到 Xcode Resources | 主屏幕应用名 |
| macOS | InfoPlist.strings、MainFlutterWindow、PRODUCT_NAME=Hongguo | Finder、窗口标题，产物为 Hongguo.app |
| Windows | 多语言 STRINGTABLE、LoadStringW、FileDescription | 窗口标题、文件说明 |
| Linux | GLib 语言列表、GTK 标题、打包脚本 Desktop Entry 翻译 | 窗口及安装后的应用菜单 |

Android TV 独立名称资源也支持三种语言，追加 TV 后缀。首页品牌标题复用 ApplicationName.of(context)，桌面通过 window_manager 同步窗口标题，并监听运行时系统语言变化。Windows 安装器名称仍为 Hongguo，未添加安装器语言包。

## 升级与缓存

Android applicationId、Apple bundle identifier、Windows/Linux 二进制内部标识不变。Windows ProductName 仍保留 hongguo_app，因为 path_provider_windows 会用它计算已有数据路径。macOS 产物名称变更已同步本地与 CI 打包脚本；外部引用旧 hongguo_app.app 路径的脚本需要更新。

系统启动器可能缓存旧名称，需安装新构建并重新启动应用后检查。本次没有修改设备全局语言；Apple 各语言资源通过源文件及 macOS 已编译 bundle 分别核验，不等同于三种系统语言的目视测试。

## 验证

- `cd packages/app && ../../.fvm/flutter_sdk/bin/flutter test test/application_name_test.dart`：3 项通过，覆盖区域、显式脚本、语言偏好及运行时语言变化。
- 同目录 `flutter analyze lib/localization/application_name.dart test/application_name_test.dart`：无问题。
- `plutil -lint`：iOS/macOS plist 与六份本地化 strings 全部通过。
- macOS Debug/Hongguo.app 中 en、zh-Hans、zh-Hant 的 CFBundleDisplayName 均已核对。
- Android mobile Debug APK 构建成功（0.2.7+9）；aapt 核对默认 Hongguo、zh/CN 红果剧场、HK/Hant/TW 紅果劇場；applicationId 保持 com.example.hongguo_app。
- Windows/Linux 未在原生系统构建或目视验证。

Apple 字段含义与资源机制参见 [Info.plist Core Foundation keys](https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/CoreFoundationKeys.html) 和 [Localizing your app](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPInternational/LocalizingYourApp/LocalizingYourApp.html)。
