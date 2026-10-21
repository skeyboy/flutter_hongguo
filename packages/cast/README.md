# hongguo_cast

局域网投屏（DLNA / UPnP AV）协议核心，独立模块，不依赖 Flutter。

- `lib/hongguo_cast.dart`：对外出口，App 只 import 这一个文件。
- `lib/src/protocol/ssdp.dart`：M-SEARCH 组播与应答解析（`239.255.255.250:1900`）。
- `lib/src/protocol/description.dart`：设备描述 XML → `UpnpDevice` / 控制端点。
- `lib/src/protocol/soap.dart`：AVTransport、RenderingControl 的 SOAP 信封与故障解析。
- `lib/src/protocol/didl.dart`：`SetAVTransportURI` 需要的 DIDL-Lite 元数据。
- `lib/src/protocol/time.dart`：`H:MM:SS.mmm` 时间与时长互转。
- `lib/src/discovery.dart`：SSDP → 描述 → 设备表，按 USN 去重、按 TTL 剪除。
- `lib/src/source/media_source.dart`：手机作为局域网 HTTP 源，服务已缓存的明文 MP4（HEAD / `Range` / 416）。
- `lib/src/session/cast_session.dart`：一次投屏会话的状态机与 `GetPositionInfo` 轮询。

纯 Dart 的目的是让整套协议在 1x 的 Linux 门禁里用 `dart test` 跑完，不增加 macOS/Windows 的付费分钟。

从本目录运行：

```bash
../../.fvm/flutter_sdk/bin/dart test
```

能力边界与验收口径见 [投屏设计](../../docs/design/cast-dlna.md)；[文档索引](../../docs/README.md)。
