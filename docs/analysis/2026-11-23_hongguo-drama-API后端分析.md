# hongguo-drama（jackotom 8.0）API 后端分析

> 依据本地参考仓库快照分析（commit `1639370`，源自 GitHub main @ `8d14d07`，版本 8.0.0）。
> 本文档是 hongguo-drama 作为 `references/hongguo-web`（1.1.x）替代参考的接任分析，格式沿用 [API-reference.md](API-reference.md)。
> 本轮为只读分析 + 方案制定依据；替换实施记录见方案文档。

## 0. 参考仓库位置

- **本地路径**：`C:\Users\lee\WorkBuddy\spaces\2026_11_23_18-01-38\hongguo-drama-ref`（git 仓库，origin 指向 GitHub）
- **未放入主仓 `references/` 的原因**：W 盘（SMB 映射）当前对 bash 写操作返回 Permission denied（git fetch pack / tar / cp 均失败），WorkBuddy Write 工具单文件可写但无法承载整仓复制。待 W 盘权限恢复后可迁回 `references/hongguo-drama`。
- 许可证 GPL-3.0-only；参考使用须保持出处声明（AGENTS/NOTICE 中已注明其来源链：drpys → N3urda/hongguoTV → tsukiyo-zero/hongguoTV）。

## 1. 项目定位与技术形态

| 维度 | hongguo-drama 8.0 | 对比：hongguo-web 1.1.x（旧参考） |
|---|---|---|
| 形态 | Electron 桌面应用 + Node `http` Docker Web/API | Node 本地 HTTP 服务（127.0.0.1:8000） |
| 来源 | 红果 / 西饭 / 河马 / DramaBox / ReelShort / 苹果CMS 自定义源 | 仅红果 |
| 取址策略 | **官网网页版优先，App 接口回退**，旧接口兜底（三层） | App 取址优先，官网回退 |
| 签名 | v5（player 族）+ 551 Argus/Ladon + SM3 | 六头 PureSign |
| 服务角色 | 下载/合并/任务管理 API（内容取源在主进程内） | 内容 API 门户 |

核心结论：**参考项目的"API 后端方式"不是一个 Node 服务，而是一套「多源适配 + 官网优先取源 + 新签名族 + 匿名设备注册」的协议栈**（`src/native/`）。Docker `server/` 只是这套栈之上的下载任务管理器。

## 2. 取源三层结构（hongguo.js）

红果取址入口 `fetchPlayUrlSingle(vid, sid)`（hongguo.js:732）→ 缓存 30s → `fetchPlayUrlFresh`（hongguo.js:820）：

```
第 1 层  官网 web      fetchPlayUrlFromWeb      免签，SSR HTML 内嵌 MP4 直链
第 2 层  App app       app-source.fetchAppPlayUrl  v5/551 签名 + 匿名设备注册
第 3 层  旧接口 api     multi_video_model/preload/v1  免签 POST
        （skipWeb 惩罚窗口内跳过第 1 层，末尾再补试一次）
```

任一层失败均记入 `sourceFailure()` 结构化错误（hongguo.js:772），最终抛 `SOURCE_UNAVAILABLE` 并携带 `sources[]` 明细。

### 2.1 官网层（第 1 层）

- 数据源：`https://hongguoduanju.com/player/{id}` 与 `/detail?series_id={id}` **并行竞速**（hongguo.js:556-600）：
  - 首试 1.5s 预算 + trustedOfficialDns；600ms 后 hedge 双路（trusted DNS + 普通 DNS 各 3.5s）。
  - 理由：部分 /player 页挂在坏 CDN 边缘（挂起后中断），同剧 /detail 正常。
- 分集页 SSR HTML 内嵌**完整 vid 列表 + 可直接下载的 MP4 直链**，免签名（hongguo.js:14-17 注释）。
- 补充通道：`/api/video/protected/fallback-play-info`（`fetchPublicFallbackPlayUrl`，hongguo.js:261）。
- URL 归一：`normalizeVideoUrl` + `isPublicMediaUrl` CDN 白名单（web-media-guard.js）。

### 2.2 App 层（第 2 层，app-source.js）

端点轮换（app-source.js:26-33）：

| 端点 | 用途 | 签名 |
|---|---|---|
| `.../novel/player/multi_video_model/v1/` | 主取址 | 设备注册身份，免六头 |
| `.../reading/bookapi/video_tab/multi_video_model/v1/` | video_tab 恢复 | **v5 GET 无正文**（player 族；Argus/Ladon 会被空响应拒绝） |
| `.../novel/player/multi_video_model/player/v1` | player 取址（b/a 双主机轮换） | **signPlaybackV5**（gzip 协议） |
| `.../novel/player/video_model/v1/`（a/c 双主机） | MODEL 兜底 | — |
| `.../reading/bookapi/search/tab/v` | App 搜索 | 签名 + 注册身份，tab_type=11 |

关键行为（app-source.js:438-560）：

- **节奏控制**：所有取址（含注册）共享一条串行队列，成功后 1s 冷却（`playbackReadyAt`）。
- **身份重置**：`BUSINESS_REJECTED` 且 business_code=110001 → 重置播放设备身份重试一次；`EMPTY_RESPONSE`/`ETIMEDOUT` 连续两轮且距上次重置 ≥30s 亦重置。
- **显式拒绝传染**：HTTP 403/429、其他 BUSINESS_REJECTED、注册被拒 → `playbackRejection` 全局短路后续排队请求。
- 取址 body：`biz_param`（device_level=1、need_all_video_definition=true、video_platform=1024）+ `mixed_video_id_map:{"1004":[vid]}` + `dr_scene:'player'`。
- 版本参数族：主目录 71332/7.1.3.32、注册头 73932/7.3.9.32、播放设备 74332/7.4.3.32（按跳切换）。

### 2.3 签名族（playback-v5.js / playback-signature.js）

| 模块 | 来源 | 要点 |
|---|---|---|
| playback-v5.js（304 行） | N3urda/hongguoTV Signer.kt / AesV3.kt / V5Constants.kt（源自 drpys 22261ad） | SM3 + branch-12 自研 hash（HASH_TABLE 64 项 + ror32 轮转）、AES/魔数 `2d4b4fca…`、protobuf varint 编码、query/body/ts 三段 branch 选择（与六头同思想但新常数族） |
| playback-signature.js（143 行） | ch6vip/fqapp rust Argus/Ladon | LICENSE_ID、Simon 64 位分组密码、551 Argus/Ladon 签名，仅播放跳使用 |
| playback-device.js（124 行） | tsukiyo-zero/hongguoTV DeviceRegister.kt | 匿名设备注册：**REGISTER_URL 新参数**（`tt_data=a&cronet_version=8d40f833_2026-03-03&ttnet_version=4.2.243.31-douyin&use_store_region_cookie=1`）、**新 KDF_SALT**、头版本 73932、进程内单身份复用 + 10s 冷却 |

### 2.4 搜索（server/search.cjs + hongguo-search.js）

- **官网 JSON 接口优先**：`https://hongguoduanju.com/api/search/result`（免签，比 SSR DOM 嗅探快且稳；hongguo-search.js 头注释）。
- 失败回退 App 签名搜索（hongguo-app-search.js，tab_type=11，页码 1-50）。
- server/search.cjs：App 搜索游标缓存 5 分钟（page→cursor map，上限 100），失败回退官网。

### 2.5 下载/解密（media.cjs）

- CDN 白名单硬校验（mediaGuard：qznovelvod/fqnovelvod/douyinvod/bytecdn/ibytedtos/bdcgslb，强制 HTTPS 443）+ 1GiB 上限 + 完整性校验（content-length 对账）。
- 解密：`ffmpeg -decryption_key`（AES-128-CTR CENC，key 由 `deriveKey(spadeA)` 派生）；bytevc2 编码走 librempeg 转码。
- 产出后 ffprobe 验证尺寸/时长/解码三重校验，不满足所选画质即失败不降级。

## 3. Docker Web/API（server/index.cjs）

Bearer token 鉴权（HONGGUO_TOKEN 32-256 字符，timingSafeEqual）、CSP/no-store/同源校验、`reading>=2` 并发闸。

| 路由 | 方法 | 语义 |
|---|---|---|
| `/health` | GET | 存活/停止中 |
| `/api/status` | GET | 版本、下载根、并发=1 |
| `/api/search?q&page` | GET | 三层搜索（游标缓存） |
| `/api/series/:id` | GET | 分集目录（身份/编号/权限强校验） |
| `/api/downloads` | POST | 创建下载任务（同集同画质幂等去重） |
| `/api/merge` | POST | 同剧已完成分集合并 |
| `/api/tasks`、`/api/tasks/:id/retry\|cancel` | GET/POST | 任务队列管理 |
| `/api/files/:taskId` | GET | 已完成 mp4 下载（attachment） |

串行 drain 队列：下载间隔 1s；403/429/业务拒绝/注册失败 → `interruptQueued` 暂停全队列；挂载变化（MOUNT_CHANGED）中断并提示。

## 4. 与当前项目的差异清单（替换动因）

| # | 维度 | 当前 flutter_hongguo | hongguo-drama 8.0 | 差异影响 |
|---|---|---|---|---|
| 1 | 取址优先级 | App 优先（video_model_client）→ 官网回退 | **官网优先 → App → 旧接口** | 弱网/被拒场景成功率反转 |
| 2 | 搜索 | 官网 SSR HTML 优先 → App 签名搜索 | 官网 **JSON** /api/search/result → SSR 兜底 → App 搜索 | JSON 免解析 HTML，SSR 结构变化不再致命 |
| 3 | 官网分集 | 单路 /player/{id} | /player 与 /detail **竞速 + hedge 双 DNS** | 坏 CDN 边缘不再卡死 |
| 4 | 签名族 | 六头 PureSign（取址已免签） | v5（player 族）+ 551 Argus/Ladon + SM3 | 新协议族，旧六头对 player/v1、video_tab 失效 |
| 5 | 设备注册 | 旧 KDF salt、注册 URL 旧参数、71332 族 | 新 KDF salt、新 URL 参数（cronet/ttnet）、73932 头 | 旧注册参数已致空响应/拒绝（参考 8.0 修复记录） |
| 6 | 端点轮换 | 单 b 主机 | b/a 轮换 + MODEL a/c + video_tab | 单主机风控可绕行 |
| 7 | 取址节奏 | registerInterval 800ms | 串行队列 + 1s 冷却 + 身份重置/拒绝传染策略 | 反风控策略更完整 |
| 8 | 错误语义 | CatalogError 文本 | 结构化 sourceFailure（source/code/registrationFailure/networkFailure） | 可诊断、可分派 UI 文案 |

## 5. 切换方案（概要，详见方案文档）

契约不变：`CatalogRepository` / `PlaybackJob` 接口签名保持，App 层（packages/app、tv）零改动或最小改动。

| 包 | 动作 |
|---|---|
| packages/core | 新增 v5 签名（signPlaybackV5）与 551 signPlayer 移植（SM3 已有）；byte 级对拍向量 |
| packages/api | ① catalog.dart：搜索切官网 JSON + SSR 兜底；详情切 /player+/detail 竞速；② video_model_client.dart：取址改三层优先级 + 新注册参数（73932/KDF/URL）+ 端点轮换 + 身份重置策略；③ ranking/latest/browse 维持旧链路（参考项目未覆盖） |
| packages/app | runtime 装配不动；错误文案按结构化 code 分派（可选） |

## 6. 未覆盖/风险

- 西饭/河马/DramaBox/ReelShort/自定义源适配器不在本轮范围（当前项目为单源红果）。
- bytevc2 转码、ffprobe 验证依赖 ffmpeg 工具链，Flutter 端已有本地 MP4/CENC 流水线，不引入。
- 官网 JSON 接口未公开文档化，参考项目自己保留 SSR 兜底——实现必须保留同构兜底。
- v5/551 常数族为 GPL-3.0 项目移植，注意 NOTICE.md 出处声明更新。
