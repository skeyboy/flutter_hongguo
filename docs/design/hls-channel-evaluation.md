# HLS 播放通道评估（P2 硬门槛结论）

> 承接 [多源适配器方案 §6](./multi-source-adapters.md) 与 [P2 阶段判据](../design/multi-source-adapters.md#5-分阶段落地与门禁)：
> 「HLS 是硬门槛，未落地前只开放 mp4 集，m3u8 明确标注，不得假装已支持」。
> 本文是 P2 实施前的**评估结论**，先于 DramaBox/ReelShort 适配器落地。

## 1. 结论（先行）

| 问题 | 结论 |
|---|---|
| 当前工程有没有 HLS 通道 | **没有**。`media_kit` 播放器拿到的是 `MediaCache` 下载后的**本地文件路径**，下载层只吃单文件 MP4 + CENC 分片解密，没有 m3u8 播放列表解析/分片拼接/密钥处理 |
| DramaBox 会不会返回 HLS | **不会**。参考实现只接受 `dramaboxdb.com` 官方未加密 MP4，`m3u8Flag` 或路径非 `.mp4` 或含 `encrypt` 一律拒绝 |
| ReelShort 会不会返回 HLS | **会**。`fetchPlayUrlSingle` 按扩展名返回 `format: 'hls'`（m3u8）或 `mp4` |
| 本轮处置 | 两个适配器**只开放 mp4 集**；ReelShort 遇到 m3u8 抛 `SourceUnavailable` 明确文案「该集为 HLS 流，当前版本暂不支持，请在 ReelShort 官方平台观看」，**不静默失败、不把 m3u8 当文件下载** |
| 是否宣称支持 HLS | **否**。P2 不宣称 HLS 能力，UI/文档标注「暂不支持 HLS」 |

## 2. 证据链（为什么没有 HLS 通道）

### 2.1 播放链路只接受本地 MP4 文件

1. `packages/app/lib/platform/runtime_native.dart:587` `PlaybackJob.source` 返回的是 `MediaCache.prepare(...).result` 的**本地文件路径**（`Future<String>`）。
2. `packages/app/lib/features/player_page.dart:896` `player.open(Media(source, ...))` 中 `source` 即该本地路径。
3. `packages/api/lib/src/media_cache.dart` 的下载流程：
   - `_downloadFollowingRedirects` 用 `dio.download` 把 URL 写成一个本地 `.mp4` 文件；
   - 若有 `spadeA`（CENC）则走 `ProgressiveLane` 逐分片解密或整段解密后写出 MP4；
   - 全程没有 m3u8 播放列表解析、TS/fMP4 分片下载循环、HLS key（AES-128）获取。
4. `VideoFormat` 枚举在 P0 才新增（`hls` 仅作为类型占位），此前全工程无任何 m3u8 处理代码。

### 2.2 把 m3u8 交给现有链路会发生什么

若适配器返回 `url = https://.../index.m3u8`、`format = hls`：
- `MediaCache` 会把 m3u8 文本当作「视频字节」下载成 `xxx_best.mp4`；
- 播放器打开这个「MP4」会解析失败，表现为「视频播放异常」——**即静默失败**，正是方案 §6 要避免的。

因此 P2 必须在适配器层**早拒**，而不是让它流到下载层。

## 3. 各源实际形态

| 源 | 取址返回 | 本轮处理 |
|---|---|---|
| 红果 | 签名/明文 MP4（CENC 可选） | 既有链路，不变 |
| 西饭 / 河马（P1） | 明文 MP4 | 既有明文链路，不变 |
| DramaBox（P2） | 仅官方未加密 MP4 | 按 `PublicWebPolicy(hosts:[dramaboxdb.com])` 校验，开放 |
| ReelShort（P2） | MP4 或 m3u8 | mp4 开放；m3u8 抛 `SourceUnavailable`，UI 标注暂不支持 |
| 自定义源（P3） | 苹果 CMS 多线路，可能 m3u8 | 与 ReelShort 同策略：仅 mp4 线路可用 |

## 4. 未来支持 HLS 的最小范围（本次不做，仅记录）

若后续要真正支持 HLS，需新增（每一项都是独立改动，不在 P2 范围）：
1. **播放通道**：`media_kit` 支持网络 m3u8 URL 直开（需绕过 `MediaCache` 本地文件路径，走独立的 HLS 分支）；TV 端 `tvPlayback` 需确认 ExoPlayer HLS 支持。
2. **下载/离线**：m3u8 分片下载器 + AES-128 key 处理 + 分片拼接为可播文件，或明确「HLS 不支持离线缓存」。
3. **安全策略**：m3u8 内每个分片 URL、key URL 都要过 `isPublicMediaUrl` + 逐源 host 校验（比 MP4 单文件的逐跳校验面更大）。
4. **UI**：HLS 集标注「在线播放」，禁用下载按钮。

## 5. 验收口径

- P2 适配器单测必须包含：ReelShort m3u8 集抛 `SourceUnavailable` 且文案含「HLS」「暂不支持」；DramaBox `m3u8Flag` 集拒绝。
- 不得有任何代码路径把 `.m3u8` URL 交给 `MediaCache.download`。
- 门禁：全量 `dart test` 绿，无新增 analyze 告警。真网可达性另跑探测脚本，离线测试不代表上游当前可用。
