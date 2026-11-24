# Windows 桌面端运行与验证记录

日期：2026-11-24。对象：API 后端切换到 hongguo-drama 8.0 取源方式之后的 Windows 端（最终验证于 `deded2b`，包含 `fff0415` 的三层取源与逐跳校验、`110ddb7` 的窗口与缓存目录改动、`2b71b34` 的 TLS 握手失败识别与有界重试；`6bc7bf6` 与 `deded2b` 为纯文档提交，不涉及代码）。

## 结论

| 项 | 结果 | 证据 |
|---|---|---|
| Windows release 构建 | 通过 | CI `windows-verify` 的 `Compile Windows release`；CI `build` 的 `Build Windows` |
| Windows 安装包打包 | 通过（59.9 MB） | CI 产物 `release-windows` |
| 静态分析（app / tv） | 通过 | CI `Analyze Flutter application` / `Analyze the Android TV interaction module` |
| 单元与组件测试（core / api / update / cast / tv / app） | 通过 | CI `verify` job 逐步 success |
| 真网取源（三层） | 通过 | 本机 Windows 真网探针：官网层应答，落盘可解码 MP4 |

CI 运行记录（`deded2b`，即当前 main）：

- [Verify Windows desktop #45325649944](https://github.com/skeyboy/flutter_hongguo/actions/runs/45325649944)（push 触发，windows-2022）
- [Build selected installer attachments #45325692767](https://github.com/skeyboy/flutter_hongguo/actions/runs/45325692767)（workflow_dispatch，`platforms=["windows"]`，含 analyze + 全包测试 + release 构建 + 安装包）

同一套门禁在此前三个 HEAD 上也跑过，均 success：

- `2b71b34`：[#45323360357](https://github.com/skeyboy/flutter_hongguo/actions/runs/45323360357)、[#45323476596](https://github.com/skeyboy/flutter_hongguo/actions/runs/45323476596)
- `8efb39b`：[#45319297127](https://github.com/skeyboy/flutter_hongguo/actions/runs/45319297127)、[#45319365325](https://github.com/skeyboy/flutter_hongguo/actions/runs/45319365325)
- `fff0415`：[#45314159334](https://github.com/skeyboy/flutter_hongguo/actions/runs/45314159334)、[#45314289919](https://github.com/skeyboy/flutter_hongguo/actions/runs/45314289919)

## 为什么本机不能直接 `flutter build windows`

本机是 **Windows 11 ARM64**（Dart `Abi.windows_arm64`）。三处硬约束叠在一起，导致桌面端无法在工作区原地构建：

1. **W 盘是 SMB 共享，不允许创建符号链接。** `Link.create` 直接 `OS Error: 函数不正确`，于是 `packages/app/windows/flutter/ephemeral/.plugin_symlinks/` 里生成的是 `.lnk` 快捷方式而不是目录链接，CMake 的 `add_subdirectory(url_launcher_windows/windows)` 等全部找不到源码，报 `Unable to generate build files`。
   处理：`robocopy` 镜像到本地 NTFS（`C:\hb`，排除 `.git` / `build` / `.dart_tool` / `references`，781 MB / 4 秒）后再构建。
2. **从 SMB 复制过来的 `.flutter-plugins-dependencies` 带 Hidden 属性**，`flutter pub get` 报「cannot access the file」。删掉重跑即可。
3. **`media_kit_libs_windows_video` 1.0.11 只提供 x86_64 的 libmpv**（`mpv-dev-x86_64-20230924-git-652a1dd.7z`，MD5 `a832ef24…04cd8`），没有 arm64 产物。而 `flutter build windows` 的目标架构由 `hostPlatform` 直接决定（`commands/build_windows.dart` 里 `windows_arm64` → `ARM64`），**没有参数可切**，于是 arm64 目标 + x86_64 库必然链接失败。

结论是这台机器上跑桌面端只能走 x64：CI 的 `windows-2022` 就是 x64。这也是本记录以 CI 为主要证据的原因。

## 真网取源验证（本机 Windows，非 CI）

`packages/api/bin/mac_poc_probe.dart` 是显式单集真网探针（`verify_all.sh` 不会跑它）：

```bash
cd packages/api && dart run bin/mac_poc_probe.dart /tmp/hongguo-live --prepare
```

首次运行暴露了一个**跨层缺口**：官网直链 `v11-hgweb.qznovelvod.com` 立即回 **302**，而下载层写死 `followRedirects: false`，直接 `badResponse: 302`——官网层取到了地址却必然下载失败。修复方式见 [方案 F 节](design/api-web-first-switch.md)（逐跳 catch → 白名单校验 → 重试，上限 5 跳）。

修复后的读数：

```json
{"stage":"catalog","items":18}
{"stage":"episodes","count":50}
{"stage":"video_model","fromWeb":true,"encrypted":false,
 "host":"v11-hgweb.qznovelvod.com","scheme":"https","definition":"360p",
 "size":0,"hasUserAgent":true,"hasReferer":true}
{"stage":"prepare","bytes":6670754}
```

落盘文件结构核对：`ftyp isom/iso2/avc1/mp41`、`moov` 偏移 36、`mdat` 偏移 79187，与 6,670,754 字节的元数据一致——不是 SEO 预览片，也不是空 302 产物。

## 已知缺口（如实记录）

- **GUI 交互未在真窗口上逐项点过。** 本机能构建的只有 x64 目标，为跑窗口做了两条尝试，都被网络挡在最后一步：
  - 装 x64 Flutter SDK（`C:\fl`，`Abi.windows_x64` 已确认）在本机重建：`media_kit_libs_windows_video` 的 CMake 要 `file(DOWNLOAD)` 两个 GitHub Releases 资产（libmpv 7z / ANGLE 7z）。CMake 自带下载器在这个代理下只有 ~10 KB/s（20 秒 0.2 MB），改用 curl 直连则 `schannel: server closed abruptly` 与 `CONNECT tunnel failed, response 502`——`objects.githubusercontent.com` 被挡。
  - 直接下载 CI 的 `release-windows` 产物（内含 x64 便携版 zip）在本机跑：artifact 下载重定向到 `pipelines.actions.githubusercontent.com`，同样被代理挡住。
  - 也就是说，Windows 端结论来自 CI 的 release 构建 + 组件测试，不是「启动窗口 → 搜索 → 播放」的人工走查。取源与落盘的行为由本机真网探针覆盖（见上）。
- **`packages/update` 有 1 项 Windows 专属失败**：`release_downloader_test` 断言临时目录用 `/`，Windows 给 `\`。CI 的 `verify` 跑在 ubuntu-24.04 上所以是绿的，本机 Windows 上会红。与本轮改动无关，未处理。
- `dart analyze` 在工作区（W 盘 SMB）起不来（analyzer server 启动即被 SIGTERM），静态分析的结论完全来自 CI。
