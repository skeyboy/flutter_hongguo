# API 后端切换方案：对齐 hongguo-drama 8.0 取源方式

> 分析依据：[2026-11-23_hongguo-drama-API后端分析.md](../analysis/2026-11-23_hongguo-drama-API后端分析.md)
> 原则：契约不变（`CatalogRepository` / `PlaybackJob` 签名不动），底层协议栈切换为参考项目的「官网优先三层取源」。

## 已确认无缺口的部分

设备注册（`playback_device.dart`）已与参考 8.0 逐字段同步：REGISTER_URL（含 cronet/ttnet 参数）、KDF salt、73932 header 族、注册间隔与失败冷却。无需改动。

## 本轮切换（P0）

### 1. 新增 `packages/api/lib/src/web_source.dart`

参考 `hongguo.js` 官网层 + `catalog.js readRouterData` 的 Dart 移植：

| 函数 | 对应参考实现 | 职责 |
|---|---|---|
| `readRouterData` | catalog.js | 提取 SSR 页面 `_ROUTER_DATA` JSON（花括号配平解析） |
| `parsePlayerDetail` | hongguo.js `parseEpisodeListHtml` | player/detail 页分集列表 + 剧集身份校验（series_id 一致性、vid 去重） |
| `extractWebPlayUrl` | hongguo.js `fetchPlayUrlFromWeb` | ld+json VideoObject.contentUrl 提取 + `matchesPlayer` 绑定校验 + CDN 白名单 |
| `publicFallbackPlayUrl` | hongguo.js `fetchPublicFallbackPlayUrl` | `POST /api/video/protected/fallback-play-info`（`item_id`）解析与校验 |
| `parseSearchResultJson` | hongguo-search.js `parseSearchResponse` | `/api/search/result` JSON 结构解析 |
| `normalizeVideoUrl` / `isPublicMediaUrl` | hongguo.js / web-media-guard.js | URL 归一（去转义/剥 Range）与 CDN 白名单 |

### 2. `catalog.dart` 搜索与详情

- `_search`：**官网 JSON 优先**（`/api/search/result?aid=8662&query=&page=`）→ 失败回退现有 SSR `parseWebSearch` → 再回退 App 签名搜索（顺序与参考 server/search.cjs 一致：App 搜索的游标缓存层不在本轮范围）。
- `detail`：`/player/{id}` 与 `/detail?series_id={id}` **并行竞速**（`Future.any` 语义、双页任一有效即用），替换现有单页顺序尝试。

### 3. `video_model_client.dart` 三层取址

`fetchTrack` 优先级对齐参考 `fetchPlayUrlFresh`：

```
第 1 层  web   官网直链：fallback-play-info POST → /player/{sid}/{vid} 与 /player/_/{vid} ld+json
第 2 层  app   现有链路（注册设备 + 签名/免签 POST multi_video_model/v1 + fallback_api）
第 3 层  api   旧接口：免签 POST multi_video_model/preload/v1（MODEL_BIZ_PARAM）+ parseModelVideo 选流
```

- web 命中的直链为明文 MP4（无 CENC），`VideoTrack.spadeA` 为空、`definition='web'`，新增 `userAgent`/`referer` 字段供下载层使用。
- 任一层失败记录来源，最终抛 `PlaybackUnavailable`（文案保留中文语义）。

### 4. `media_cache.dart` 下载头

下载请求 UA 固定 `'Mozilla/5.0'` → track 提供 `userAgent`/`referer` 时优先使用（web 直链需要 `WEB_UA` + `Referer: https://hongguoduanju.com/`）。

## 下一轮（P1，不在本轮）

- v5 签名族移植（`playback-v5.js` signPlaybackV5 + `playback-signature.js` 551 Argus/Ladon + `player/v1` gzip 协议、`video_tab` GET）——在 App 层端点轮换生效后接入。
- 端点轮换（b/a 主机、MODEL a/c）与 `business_code 110001` 身份重置策略。
- 搜索游标缓存（参考 server/search.cjs）。

## 实施补充（第二次落地，原型与业务逻辑对齐新 API）

切换完成后暴露了四处「协议变了、上层没跟上」的缺口，按影响面从小到大处理：

### A. 官网层两级取址（`web_source.dart` + `video_model_client.dart`）

参考 `fetchPlayUrlFromWeb` 其实有两级：兜底接口 → 公开播放页 ld+json。第一轮只落了第一级，导致接口不认的分集直接掉到 App 层。补上第二级：

- 新增 `playablePageSeries(html, vid)`：读 `_ROUTER_DATA` 的 player 路由，逐项核对 `vid`、两处 `series_id`、`publicVideoSeo.available/itemId/seriesId`、`protectedPlayback`。
- **`protectedPlayback` / `seo.available=false` 一律不采信**：官方对未公开分集挂的是 SEO 预览片，元数据时长对得上、内容只有开头，采信它等于让用户看几十秒就断。
- 走 `/player/_/{vid}` 路由，不要求调用方带 sid（`fetchTrack` 契约不变）。

### B. CDN 白名单按来源分表（`packages/core/lib/src/crypto/media_url.dart`）

官网直链会落到 `bytecdn.cn` / `ibytedtos.com` / `bdcgslb.com`，而下载层的 `MediaUrlDecoder.checked` 只认三张签名 CDN 域，官网直链会在下载前被判 `FormatException`。现在：

- core 导出 `appMediaDomains`（窄）与 `webMediaDomains`（= 窄表 + 页面 CDN）；
- `VideoTrack.fromWeb` 标明来源，`MediaCache` 据此选表——不因为多一层就全局放宽；
- `parsePublicFallbackPlayUrl` 仍用窄表（该接口只回签名 CDN），页面 ld+json 用宽表，与参考一致。

### C. 渐进播放与官网直链的取舍（`preferApp`）

渐进通道只吃带 CENC 的分片。官网直链是明文 MP4，必须整段下完才能播——开着「边下边看」时它反而是慢的那条路。`fetchTrack(preferApp: true)` 让 App 层先答，官网层退到回退位；`runtime_native` 在 `progressivePlayback && !tvBuild` 时传这个标记。默认设置下（渐进关闭）仍是官网优先。

### D. 失败文案分级（`packages/app/lib/playback/playback_failure.dart`）

三层取源把失败信息从「一句 App 业务码」变成了可能带主机名与多层业务码的清单，原来的错误卡片直接 `'$error'` 全量展示。现在：

- `PlaybackFailure.classify` 把异常分七类（取消 / 超时 / 无片源 / 信息不全 / 本地缺文件 / 网络 / 未知），给「一句原因 + 一句下一步」；
- 原始文本折叠进「详情」，第一眼不出现主机名与业务码；
- 取消与本地缺文件不给「重新准备」（重试解决不了），有下一集时给「换下一集」；
- PiP 占位窗口的「下一集准备失败」也带上同一句原因。

## 验证口径

- `dart analyze --fatal-infos` 通过；
- `packages/api` 现有测试全绿 + 新增 web_source/三层取址 mock 测试；
- 现有离线回归 `tool/verify_all.sh` 不回退。
