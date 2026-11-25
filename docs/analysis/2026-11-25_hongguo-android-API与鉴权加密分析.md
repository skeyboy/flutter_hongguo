# hongguo-android 参考实现：API 数据源与鉴权加密分析

> 分析对象：`references/hongguo-android`，上游 `https://github.com/OOIUa/hongguo-android`，submodule 固定提交 `62705d4fc8c6b44d9754c063f7a2722cc8daee0a`（`v0.7.16-41-g62705d4`，2026-11-24）。
> 方法：静态源码分析 + 工程自带 `README.md` / `docs/ACCOUNT_INTEGRATION.md` / `VALIDATION.md` 交叉核对；**本轮未做联网探测**，不把源码注释或离线测试写成线上验收结论。
> 相对路径均以本文件所在 `docs/analysis/` 为基准。

## 1. 结论摘要

1. Android 参考实现是**本机闭环客户端**：所有签名、设备注册、内容取址、媒体解密、缓存与播放在 APK 内完成，没有自建后端；`OkHttp 4.12 + Bouncy Castle 1.79` 是唯一网络 / 密码学依赖（[app/build.gradle.kts:36-39](../../references/hongguo-android/app/build.gradle.kts#L36-L39)）。
2. 数据源分为四组：① 内容/发现 API（a 主机 + 六头签名）；② 播放取址 API（b 主机 + 六头签名 + 匿名注册身份 + 多路由回退）；③ 官网 Web 层（免签 JSON / SSR）；④ **账号协议**（官网 OAuth/短信登录 + App 业务身份 + 云片单 + 进度上报，独立签名器与加密存储）。Flutter 主工程目前只实现了 ①②③ 的匿名路径，④ 尚无对应实现。
3. 签名核心是 `PureSign`：query+body+khronos → `x-gorgon / x-khronos / x-ladon / x-argus / x-helios / x-medusa` 六头；签名分支由 query/body/timestamp 决定，客户端会抖动 `_rticket` 避开不被接受的分支。Android 内容层避开 `branch==1`（[Client.java:261-275](../../references/hongguo-android/app/src/main/java/com/hongguo/api/service/Client.java#L261-L275)），账号签名器只发 `branch==0`（[Signer.kt:4,155-169](../../references/hongguo-android/app/src/main/java/com/hongguo/account/protocol/Signer.kt#L155-L169)）。Java 版与 Flutter `packages/core/lib/src/crypto/pure_sign.dart` 使用同一组 Medusa 常量与分支判定初值 `0x20230928`（[PureSign.java:700-705,868-907](../../references/hongguo-android/app/src/main/java/com/hongguo/api/core/PureSign.java#L700-L705)、[pure_sign.dart:546-552,1381-1392](../../packages/core/lib/src/crypto/pure_sign.dart#L1381-L1392)），因此**不应重写 Dart 签名算法**。工程里其实有**三套签名**：内容层 `api/core/PureSign.java`；账号/v5 播放层 `account/protocol/Signer.kt`（BouncyCastle SM3、branch==0、v5 常量见 `V5Constants.kt` / `VendorConstants.kt`）；老单集接口专用 `api/core/PlayerSign.java`（[PlayerSign.java:11-163](../../references/hongguo-android/app/src/main/java/com/hongguo/api/core/PlayerSign.java#L11-L163)）。Flutter 目前只有第一套；后两套是取址路由与账号能力的缺口，不是同一算法的重复实现。
4. 设备身份有**两套且刻意隔离**：内容层 `Device.ensureDeviceId` 生成并持久化一个稳定 `device_id`；播放层走匿名 `POST /service/2/device_register/`，把 ttEncrypt 信封里的指纹换成服务端下发的 `device_id / install_id`。播放层内部还有两种策略并存：`AppSource` 对**成功过的身份**用 `PLAYBACK_IDENTITY` 复用、401/403 才清空；`PlaybackDevice.java`（v5 路径）明确「每次取播放信息都注册新身份，播放/预加载/重试之间不共享」（[PlaybackDevice.java:45-50](../../references/hongguo-android/app/src/main/java/com/hongguo/api/service/PlaybackDevice.java#L45-L50)）。因此 Flutter 当前的 fresh-per-ask **已有 Android 对应实现**，不是孤例。账号设备与官网 Cookie 再单独保存，不进媒体请求（[ACCOUNT_INTEGRATION.md:3](../../references/hongguo-android/docs/ACCOUNT_INTEGRATION.md#L3)）。
5. 媒体链路：取址响应里的 `main_url` 可能是 AES 加密串，需用 `key_seed` 与固定 64 字节常量做 SHA-512→AES-128-CBC 解出真实 URL；`spade_a` 解包后作为 CENC 内容密钥；非碎片 MP4 走 Range 渐进解密，不兼容时回退整集处理（[AppSource.java:103-109,1345-1355](../../references/hongguo-android/app/src/main/java/com/hongguo/api/service/AppSource.java#L1345-L1355)）。

## 2. 网络分层与主机清单

```text
UI / ViewModel
 ├─ com.hongguo.api.service.Client     内容/发现：base_query + session_headers + PureSign
 ├─ com.hongguo.api.service.AppSource  播放取址：设备注册 + PureSign + 多路由回退
 │   ├─ PlaybackDevice / MobilePlayerV5 / PublicEpisodeSource / WebSource
 │   └─ Stream / ProgressiveMedia      CDN 下载、URL 解码、Spade/CENC 解密
 ├─ com.hongguo.account.*              账号：独立 Signer/Cookie/加密存储/片单/进度
 └─ com.hongguo.android.UpdateRepository  GitHub Releases 更新清单与下载
```

| 主机 / 来源 | 用途 | 鉴权形态 | 证据 |
|---|---|---|---|
| `api5-normal-sinfonlinea.fqnovel.com` | 搜索、详情、榜单、分类、账号业务接口、弹幕主线路 | 内容/账号均带六头签名；账号额外带 Cookie | [upstream.json](../../references/hongguo-android/app/src/main/assets/upstream.json)、[CloudAccount.kt:95](../../references/hongguo-android/app/src/main/java/com/hongguo/account/protocol/CloudAccount.kt#L95)、[DanmakuRepository.kt:31](../../references/hongguo-android/app/src/main/java/com/hongguo/android/danmaku/DanmakuRepository.kt#L31) |
| `api5-normal-sinfonlineb.fqnovel.com` | 播放模型 `multi_video_model/v1/`、`video_tab`、`player/v1`、`video_model/v1` | 六头签名 + 注册身份；不同 UA/版本模板 | [AppSource.java:74-97](../../references/hongguo-android/app/src/main/java/com/hongguo/api/service/AppSource.java#L74-L97) |
| `api5-normal-hl.fqnovel.com`、`api5-normal-lf.fqnovel.com`、`api5-normal-sinfonlinec.fqnovel.com` | 空响应换主机重试、推荐/相关作品/弹幕备用线路 | 同主线路模板 | [AppSource.java:80-81](../../references/hongguo-android/app/src/main/java/com/hongguo/api/service/AppSource.java#L80-L81)、[GuessFeed.kt:141-143](../../references/hongguo-android/app/src/main/java/com/hongguo/account/protocol/GuessFeed.kt#L141-L143) |
| `log5-applog-lf.fqnovel.com` | 匿名设备注册 `service/2/device_register/`；另有 `app_alert_check/` | **无签名头**，ttEncrypt 二进制体 | [PlaybackDevice.java:61,70](../../references/hongguo-android/app/src/main/java/com/hongguo/api/service/PlaybackDevice.java#L61-L70)、[DeviceRegister.kt:43-52](../../references/hongguo-android/app/src/main/java/com/hongguo/account/protocol/DeviceRegister.kt#L43-L52) |
| `security.snssdk.com` | passport 短信登录 / 验码 | 固定设备号 + passport 通道，不绕过滑块 | [PhoneLogin.kt:162-175](../../references/hongguo-android/app/src/main/java/com/hongguo/account/protocol/PhoneLogin.kt#L162-L175) |
| `hongguoduanju.com` | 官网搜索、详情/播放页、二维码登录、账号资料、官网 Cookie | 桌面 UA + Referer；免签；官网会话独立 | [WebSource.java:31](../../references/hongguo-android/app/src/main/java/com/hongguo/api/service/WebSource.java#L31)、[WebLogin.kt:88-160](../../references/hongguo-android/app/src/main/java/com/hongguo/account/protocol/WebLogin.kt#L88-L160) |
| `qznovelvod.com` / `fqnovelvod.com` / `douyinvod.com` | App 取址返回的媒体 CDN | 解码后的 HTTPS URL；`checkedUrl` 白名单 | [AppSource.java:99-104](../../references/hongguo-android/app/src/main/java/com/hongguo/api/service/AppSource.java#L99-L104) |
| `bytecdn.cn` / `bytecdn.com` / `ibytedtos.com` / `bdcgslb.com` | 官网直链媒体 CDN | 官网层更宽的白名单 | [PublicEpisodeSource.java](../../references/hongguo-android/app/src/main/java/com/hongguo/api/service/PublicEpisodeSource.java) |
| GitHub Releases | `update.json` + APK 下载 | 公开 HTTPS；下载后校验大小/SHA-256/签名/包名 | [README.md「在线更新」](../../references/hongguo-android/README.md) |

## 3. 匿名内容接口（App / 发现层）

公共 query 来自 `upstream.json → upstream.base_query`（剥掉 `_` 注释键）+ 本机生成的 `device_id`，再追加业务 query 与 `_rticket`；公共头来自 `session_headers` + `content-type`、`x-ss-stub`（POST body 的 MD5 大写）（[Client.java:65-95,202-249](../../references/hongguo-android/app/src/main/java/com/hongguo/api/service/Client.java#L202-L249)）。

| 方法与路径 | 关键参数 | 响应提取 / 语义 | 签名 | 证据 |
|---|---|---|---|---|
| GET `/reading/bookapi/search/tab/v` | `query`、`tab_name=feed`、`search_source=1`、`offset`、`count=10`、`use_correct=true`；续页 `passback`、`search_id` | `search_tabs[0].data`、`next_offset`、`has_more`；上层按“攒够一页”连续翻最多 12 轮 | 是 | [Client.java:713-736](../../references/hongguo-android/app/src/main/java/com/hongguo/api/service/Client.java#L713-L736) |
| POST `/novel/player/multi_video_detail/preload/v1` | `series_id`、`dr_scene=preload`、`biz_param`（含 `image_shrink_datas_str`、`screen_width_px=900`、`source=7` 等） | `data[series_id].video_data.video_list[]` → `vid / vid_index / title`；缓存 6 小时；失败回官网 | 是 | [Client.java:525-550,827-852](../../references/hongguo-android/app/src/main/java/com/hongguo/api/service/Client.java#L827-L852) |
| GET `/reading/bookapi/bookmall/cell/change/v` | `cell_id=7470092475068071998`、`tab_type=26`、`client_req_type=2`、`client_template=2`、`screen_width_px=1350`、`selected_items=comic_series_rank`、`sub_selected_items`、`session_uuid`、`filter_ids` | `data.cell_view.cell_data / cell_selector / next_offset` | 跟随 `SIGN_LIST`，默认开 | [Client.java:962-977](../../references/hongguo-android/app/src/main/java/com/hongguo/api/service/Client.java#L962-L977) |
| POST `/reading/distribution/category/landpage/v`（browse / latest） | `filter_ids`（已展示 ID 的 CSV）、`req_scene`、`offset`、`limit`、`select_items{theme,role,epoch,gender,online_time,genre,sort}`、`session_id=""`、`req_type=only_content`、`client_req_type=3` | `data.video_data`、`has_more`、`next_offset` | 跟随 `SIGN_LIST` | [Client.java:1112-1134,1200-1250](../../references/hongguo-android/app/src/main/java/com/hongguo/api/service/Client.java#L1112-L1134) |
| POST 同上（filters） | `need_selector_panel=true`、`req_type=default`、`offset=0`、`limit=1` | `data.selector_rows[]`，行 `type/row_name/selection_type/items[].selector_item_id` | 跟随 `SIGN_LIST` | [Client.java:1137-1165](../../references/hongguo-android/app/src/main/java/com/hongguo/api/service/Client.java#L1137-L1165) |
| 官网 `https://hongguoduanju.com/search/{q}` 与 `/detail?series_id=`、`/player/{id}` | 桌面 UA、`Accept-Language`、`Referer` | `searchList`、`vid_list`、`accessible_episode_cnt`；无签名 | 免签 | [WebSource.java](../../references/hongguo-android/app/src/main/java/com/hongguo/api/service/WebSource.java)、[Client.java:843-850](../../references/hongguo-android/app/src/main/java/com/hongguo/api/service/Client.java#L843-L850) |

错误语义：非 2xx、空 body、非 JSON、`code != 0` 都进 `UpstreamResponseError`；`code ∈ {429,110001,110002,110003}` 或 message 含 verify/captcha/risk/频繁/稍后/验证等 → `RiskControlError`；`code ∈ {401,403,8,1001}` 或 message 含 token/登录/login 等 → `AuthExpiredError`；后两者**不做重放**（[Safeguards.java:273-352](../../references/hongguo-android/app/src/main/java/com/hongguo/api/core/Safeguards.java#L273-L352)、[Client.java:313-329](../../references/hongguo-android/app/src/main/java/com/hongguo/api/service/Client.java#L313-L329)）。传输/上游错误最多再试 1 次，间隔 `300ms × (attempt+1)`；`refreshSession()` 在纯签名模式下是空操作 + 20 秒防抖（[Client.java:332-346](../../references/hongguo-android/app/src/main/java/com/hongguo/api/service/Client.java#L332-L346)）。

## 4. 播放取址接口

### 4.1 路由顺序（20 秒总预算，单次 8 秒）

`fetch(vid, quality, seriesId)` 的尝试序列（[AppSource.java:131-220,365-382](../../references/hongguo-android/app/src/main/java/com/hongguo/api/service/AppSource.java#L131-L220)）：

1. `video_tab/multi_video_model/v1/`（v5 无正文 GET，`MobilePlayerV5.requestVideoTab`）
2. `novel/player/multi_video_model/player/v1`（v5 gzip 正文 POST，`MobilePlayerV5.request`）
3. `novel/player/video_model/v1/`（旧单集 POST，最多 2 次）
4. `video_tab/multi_video_model/v1/`（复用已成功身份的 v5 GET）
5. `multi_video_model/v1/` 主主机 POST（复用身份）
6. 同路径 GET + **重新注册身份**
7. `multi_video_model/v1/` POST 换 `api5-normal-hl.fqnovel.com` 主机
8. 官网匿名公开取址 `PublicEpisodeSource`（有 `seriesId` 时）

成功的播放身份写入 `PLAYBACK_IDENTITY` 复用；出现 401/403 或明确拒绝时清空，下一次重注册（[AppSource.java:310-360](../../references/hongguo-android/app/src/main/java/com/hongguo/api/service/AppSource.java#L310-L360)）。

| 路径 | 方法与请求 | 证据 |
|---|---|---|
| `/novel/player/multi_video_model/v1/` | POST；body `biz_param{detail_page_version:0,device_level:3,need_all_video_definition:true,video_platform:1024,…}` + `mixed_video_id_map{"1004":[vid]}`；UA `com.phoenix.read/71532...`；query 含固定设备模板 + 注册下发的 `device_id/iid/cdid` + `version_code=73932`、`version_name=7.3.9.32`、`ts`、`_rticket`；六头签名 | [AppSource.java:74-97,777-800,835-858,1135-1150](../../references/hongguo-android/app/src/main/java/com/hongguo/api/service/AppSource.java#L835-L858) |
| `/reading/bookapi/video_tab/multi_video_model/v1/` | GET；`tabQuery(vid)` + 注册身份 + 六头签名；用于优先尝试 | [AppSource.java:1075-1111](../../references/hongguo-android/app/src/main/java/com/hongguo/api/service/AppSource.java#L1075-L1111) |
| `/novel/player/multi_video_model/player/v1`、`/reading/bookapi/video_tab/multi_video_model/v1/` | `MobilePlayerV5` 的 GET/POST 变体，各自带版本/UA 模板与签名 | [MobilePlayerV5.kt:10-14](../../references/hongguo-android/app/src/main/java/com/hongguo/api/playback/MobilePlayerV5.kt#L10-L14) |
| `/novel/player/video_model/v1/` | POST；`singleBody(vid)`，`SINGLE_VERSION_CODE=73532`；最多 2 次 | [AppSource.java:931-970](../../references/hongguo-android/app/src/main/java/com/hongguo/api/service/AppSource.java#L931-L970) |
| 响应内 `fallback_api` | GET；域名白名单 `fqnovel.com / snssdk.com`；只带 UA；返回 `video_info.data.video_list`、`key_seed` | [AppSource.java:99-100,610-640](../../references/hongguo-android/app/src/main/java/com/hongguo/api/service/AppSource.java#L610-L640) |
| `/novel/commentapi/comment/list/%s/v1/` | 弹幕列表；a 主机主线路、`api5-normal-hl` 备用 | [DanmakuRepository.kt:28-32](../../references/hongguo-android/app/src/main/java/com/hongguo/android/danmaku/DanmakuRepository.kt#L28-L32) |

### 4.2 匿名设备注册（无签名）

```
POST https://log5-applog-lf.fqnovel.com/service/2/device_register/
     ?tt_data=a&cronet_version=8d40f833_2026-03-03
     &ttnet_version=4.2.243.31-douyin&use_store_region_cookie=1
Content-Type: application/octet-stream;tt-data=a
log-encode-type: gzip ; x-ss-dp: 8662 ; x-ss-req-ticket: <毫秒>
x-vc-bdturing-sdk-version: 4.0.3.cn ; lc: 101 ; sdk-version: 2
passport-sdk-version: 5051452 ; x-neptune: -8|50:51:59:30:40:47:49:39
x-ss-stub: MD5(body) 大写
body = ttEncrypt(gzip(JSON{magic_tag:"ss_app_log",header:{...},_gen_time:<ms>}))
```

- **ttEncrypt**：`746305100000`（magic）‖ 32 字节随机 ‖ AES-128-CBC( key/iv = `sha512(sha512(rnd)‖salt)[0:16]/[16:32]`, PKCS7( `sha512(gzip_json)` ‖ `gzip_json` ) )。KDF salt 与媒体 URL 解密共用同一 64 字节常量（[DeviceRegister.kt:54-89](../../references/hongguo-android/app/src/main/java/com/hongguo/account/protocol/DeviceRegister.kt#L54-L89)）。
- 响应取 `device_id_str / install_id_str`（数字字段在 JS 侧会掉精度，必须优先字符串字段），并记录白名单根路径 Cookie；`device_token / new_user` 可选（[DeviceRegister.kt:170-192](../../references/hongguo-android/app/src/main/java/com/hongguo/account/protocol/DeviceRegister.kt#L170-L192)）。
- 三个坑源码里写得很直白：body 必须是原始二进制而不是 HAR 里的 base64 文本；响应可能被 br 压缩；**这条请求不能有六头签名，query 也不带 `ts/_rticket`**（[DeviceRegister.kt:43-52](../../references/hongguo-android/app/src/main/java/com/hongguo/account/protocol/DeviceRegister.kt#L43-L52)）。
- 另一个实现 `PlaybackDevice.java` 走同样的 `/service/2/device_register/`，但 header 里带 `version_code=73932 / os_version="16" / resolution="1280x2772"` 等另一套指纹；只保留 `device_id / iid / cdid` 与响应下发的四个匿名 Cookie，**不保存 device_token、不落盘、不读账号 Cookie**；播放模型 POST 缺 Cookie 会被拒（[PlaybackDevice.java:45-50,55-70](../../references/hongguo-android/app/src/main/java/com/hongguo/api/service/PlaybackDevice.java#L45-L70)）。
- 注册后官方还会做一次匿名设备激活：`GET log5-applog-lf.fqnovel.com/service/2/app_alert_check/?aid=8662&app_name=novelread&channel=update_64&device_id=…&iid=…&device_platform=android&os=android&version_code=73932&version_name=7.3.9.32…`，失败不阻断取流；响应里的不透明 `klink_egdi` 会进入 v5 播放 query（[PlaybackDevice.java:68-70,265-289,430-438](../../references/hongguo-android/app/src/main/java/com/hongguo/api/service/PlaybackDevice.java#L265-L289)）。

## 5. 账号协议（Flutter 侧尚未覆盖）

### 5.1 登录与身份

| 阶段 | 接口 | 关键行为 | 证据 |
|---|---|---|---|
| 官网扫码 | `GET hongguoduanju.com/passport/web/get_qrcode/`、`/passport/web/check_qrconnect/` | 取二维码 + 轮询；过期/取消不自动刷新 | [WebLogin.kt:88-108](../../references/hongguo-android/app/src/main/java/com/hongguo/account/protocol/WebLogin.kt#L88-L108) |
| 官网短信 | `/passport/web/send_code/`、`/passport/web/sms_login/` | 手机号/验证码按 `mix_mode=1` 混淆后发送，桌面 UA | [WebLogin.kt:131-150](../../references/hongguo-android/app/src/main/java/com/hongguo/account/protocol/WebLogin.kt#L131-L150) |
| 官网身份 | `/passport/account/info/v2/` | 以官网 Cookie 判定 `has_login` 或公开身份字段；随后必须再过 App 业务资料 | [WebLogin.kt:160-166](../../references/hongguo-android/app/src/main/java/com/hongguo/account/protocol/WebLogin.kt#L160-L166)、[CloudAccount.kt:172-180](../../references/hongguo-android/app/src/main/java/com/hongguo/account/protocol/CloudAccount.kt#L172-L180) |
| 手机验证码 | `security.snssdk.com/passport/mobile/send_code/v1/`；验码顺序尝试 `/passport/mobile/sms_login/`、`sms_login_only/`、`sms_login_continue/`、`validate_code/v1/`（form 与 json 两种） | 同一验证码最多提交一次；1102 明确错误才允许换码；滑块由用户到官网完成 | [PhoneLogin.kt:71,162-175](../../references/hongguo-android/app/src/main/java/com/hongguo/account/protocol/PhoneLogin.kt#L71-L175) |
| App 业务身份 | `api5-normal-sinfonlinea.fqnovel.com/reading/user/info/v1/` | `biz_user_id` 按**不透明字符串**处理（可含非数字/前导零），并要求本次响应 `agw=1`；`X-Tt-Agw-Login` 头作为网关信号 | [CloudAccount.kt:198-220](../../references/hongguo-android/app/src/main/java/com/hongguo/account/protocol/CloudAccount.kt#L198-L220)、[ACCOUNT_INTEGRATION.md:5,13](../../references/hongguo-android/docs/ACCOUNT_INTEGRATION.md#L5-L13) |
| 账号设备注册 | 同 `/service/2/device_register/` | 官网 Cookie 与注册设备 Cookie **分开保存**，只有域/根路径/未过期白名单 Cookie 可进入 App 请求，`install_id` 与保存的 `iid` 一致 | [CloudAccount.kt:42-76,107-127](../../references/hongguo-android/app/src/main/java/com/hongguo/account/protocol/CloudAccount.kt#L42-L127) |

账号侧签名器与内容侧同源但独立：`branch==0` 才发（最多抖动 128 次 `_rticket`），头集合包含 `x-tt-request-tag: t=0;n=0`、`passport-sdk-version: 50561`、`x-vc-bdturing-sdk-version: 3.7.2.cn`，POST 另带 `Content-Type` 与 `x-ss-stub`；设备 proto 的 nonce 是固定字符串 `"Ai6svO3PyrwDOUSmO6ZcResxu"` 与固定时间戳（[Signer.kt:78-169](../../references/hongguo-android/app/src/main/java/com/hongguo/account/protocol/Signer.kt#L78-L169)）。请求层 `CookieJar.NO_COOKIES`、禁重定向/代理认证/自动重试，响应上限 2 MiB，body `oneShot()` 防重放（[ProtocolTransport.kt:18-78](../../references/hongguo-android/app/src/main/java/com/hongguo/account/protocol/ProtocolTransport.kt#L18-L78)）。

### 5.2 云片单 / 进度接口

| 方法与路径 | 参数 / Body 要点 | 证据 |
|---|---|---|
| GET `/reading/bookapi/read_progress/list/v1/` | `book_types=2`、`limit=50`；响应 `video_data` | [CloudAccount.kt:221-232](../../references/hongguo-android/app/src/main/java/com/hongguo/account/protocol/CloudAccount.kt#L221-L232) |
| GET `/reading/bookapi/read_history/list/v1/` | `book_type=2&limit=0&offset=0&last_min_read_timestamp_ms=0&full_field=true&is_first_load=true&query_soft_deleted=false` | [CloudAccount.kt:235-240](../../references/hongguo-android/app/src/main/java/com/hongguo/account/protocol/CloudAccount.kt#L235-L240) |
| GET `/reading/bookapi/multi-detail/v1/` | `book_id=<CSV>`、`book_type=2`；批量补剧名/封面/集数 | [CloudAccount.kt:227-231,257-270](../../references/hongguo-android/app/src/main/java/com/hongguo/account/protocol/CloudAccount.kt#L257-L270) |
| GET `/reading/ugc/action/mget/v1/` | `count=50&object_type_list=6,15,10&offset=0&action_type=3`；空响应只读重试一次，登录失效不重试 | [CloudAccount.kt:241-254](../../references/hongguo-android/app/src/main/java/com/hongguo/account/protocol/CloudAccount.kt#L241-L254) |
| GET `/reading/user/basic_info/get/v1/` | 关注/粉丝/获赞/签名 | [CloudAccount.kt:271-276](../../references/hongguo-android/app/src/main/java/com/hongguo/account/protocol/CloudAccount.kt#L271-L276) |
| GET `/reading/bookapi/bookshelf/video/list/v1/` → 回退 `/reading/bookapi/bookshelf/video/info/v1/` | 轻量列表只给 ID/时间，再走 `multi-detail` 补元信息；空列表也不能当成失败丢弃 | [CloudAccount.kt:277-299](../../references/hongguo-android/app/src/main/java/com/hongguo/account/protocol/CloudAccount.kt#L277-L299) |
| POST `/reading/bookapi/bookshelf/video/update/v1/` | `update_bookshelf_video_list[{book_id,book_type:2,modify_time,video_shelf_operate_type:0增/1删,group_name}]`，新增附 `shark_extra`；**写入后必须回读确认**，不自动重放 | [CloudAccount.kt:300-313](../../references/hongguo-android/app/src/main/java/com/hongguo/account/protocol/CloudAccount.kt#L300-L313)、[ACCOUNT_INTEGRATION.md:32](../../references/hongguo-android/docs/ACCOUNT_INTEGRATION.md#L32) |
| GET `/reading/user/subscribe/list/v0/` | `offset=0&limit=20&is_online=<bool>&tab_type=13&subscribe_order_type=0&swipe_type=0&need_calendar_schema=false&subscribe_offset=0` | [CloudAccount.kt:314-332](../../references/hongguo-android/app/src/main/java/com/hongguo/account/protocol/CloudAccount.kt#L314-L332) |
| POST `/reading/bookapi/search/uncover_subscribe/v1/` | `{item_id:<BigInteger>,item_type:3,op_type:1,subscribe_source:0}`，**gzip body**，`Content-Encoding: gzip`；`code=0` 只是受理 | [CloudAccount.kt:333-342](../../references/hongguo-android/app/src/main/java/com/hongguo/account/protocol/CloudAccount.kt#L333-L342) |
| POST `/reading/bookapi/read_progress/upload/v1/` | `books[{book_id,item_id,vid_index（零基+1）,current_play_time,current_total_time,episode_count,read_timestamp_ms,book_type:2,progress_rate,…}]`，`write_mode=1`；默认关闭，只在真实首帧后上报 | [CloudAccount.kt:343-354](../../references/hongguo-android/app/src/main/java/com/hongguo/account/protocol/CloudAccount.kt#L343-L354)、[ACCOUNT_INTEGRATION.md:34](../../references/hongguo-android/docs/ACCOUNT_INTEGRATION.md#L34) |
| GET `/reading/bookapi/bookmall/tab/v1/` + `/cell/change/v1/` | 登录后「猜你喜欢」；主机名含 a/hl/lf 三路 | [GuessFeed.kt:135-143](../../references/hongguo-android/app/src/main/java/com/hongguo/account/protocol/GuessFeed.kt#L135-L143) |
| GET `/reading/bookapi/plan/v:version/` | 相关作品 / 待上线预约信息；主机 c/hl/lf | [RelatedWorks.kt:52-56](../../references/hongguo-android/app/src/main/java/com/hongguo/account/protocol/RelatedWorks.kt#L52-L56) |
| GET `/incent_resource/suggestion?app_id=8662` | 官网搜索建议 | [WebsiteCatalog.kt:39](../../references/hongguo-android/app/src/main/java/com/hongguo/account/protocol/WebsiteCatalog.kt#L39) |

## 6. 密钥、存储与本地数据

| 对象 | 位置 / 算法 | 证据 |
|---|---|---|
| 内容设备 ID | `Device.ensureDeviceId` 写入 `upstream.base_query`，进程内单实例；`DevicePool` 当前固定 `null`（单设备） | [Client.java:61-95,113-124](../../references/hongguo-android/app/src/main/java/com/hongguo/api/service/Client.java#L61-L124) |
| 播放身份 | 成功注册的 `device_id / iid / cdid`；`AtomicReference` 内存态，失败/401/403 清空；不写盘 | [AppSource.java:68-70,310-360](../../references/hongguo-android/app/src/main/java/com/hongguo/api/service/AppSource.java#L310-L360) |
| 账号快照 | `noBackupFilesDir/hongguo-account.enc`，Android Keystore AES-GCM（128 bit tag）+ `AtomicFile`，禁备份；Cookie 仅白名单字段 | [AccountStore.kt:24-100](../../references/hongguo-android/app/src/main/java/com/hongguo/account/AccountStore.kt#L24-L100) |
| 媒体 URL | `key_seed`（base64）→ `sha512([...sha512(seed), 64 字节常量])` 派生 AES-128-CBC key/IV；信封 `a8 ?? 01 00 ‖ ciphertext` | [AppSource.java:106-109,1355](../../references/hongguo-android/app/src/main/java/com/hongguo/api/service/AppSource.java#L1355)、[media_url.dart:22-48](../../packages/core/lib/src/crypto/media_url.dart#L22-L48) |
| 内容密钥 | `spade_a` → base64 → `Spade.unwrapV1` 解出 CENC key；无效 key 的轨直接跳过 | [Spade.java](../../references/hongguo-android/app/src/main/java/com/hongguo/api/core/Spade.java)、[video_model_client.dart:851-862](../../packages/api/lib/src/video_model_client.dart#L851-L862) |
| 内存缓存 | LRU + TTL + 条数(4096)/字节(128 MB)双上限，60 秒扫过期；详情/分集缓存 6 小时；渐进与完整缓存各 512 MiB | [Safeguards.java:24-76,127-184](../../references/hongguo-android/app/src/main/java/com/hongguo/api/core/Safeguards.java#L24-L184)、[README.md「缓存额度」](../../references/hongguo-android/README.md) |
| 本机收藏/历史 | 应用私有目录，各最多 200 部；推荐去重窗口 540 部 | [README.md「功能一览」](../../references/hongguo-android/README.md) |
| SharedPreferences | `installation`（device_id）、`hongguo_library`（本机片单快照）、`app_updates`/`theme_preferences`/`video_player_preferences` 等；账号快照单独加密文件 | [HongguoApplication.kt:14](../../references/hongguo-android/app/src/main/java/com/hongguo/android/HongguoApplication.kt#L14)、[LibraryStore.kt:11-12](../../references/hongguo-android/app/src/main/java/com/hongguo/android/LibraryStore.kt#L11-L12)、[UpdateViewModel.kt:46](../../references/hongguo-android/app/src/main/java/com/hongguo/android/UpdateViewModel.kt#L46) |
| 签名/协议固定向量 | `SigningOracleTest.kt` 用 12 组固定时间/随机数向量断言六头，不依赖真网 | [SigningOracleTest.kt:9-137](../../references/hongguo-android/app/src/test/java/com/hongguo/account/protocol/SigningOracleTest.kt#L9-L137) |

## 7. 与 Flutter 主工程的关键差异（供调整方案引用）

| 维度 | Android 参考实现 | Flutter 当前实现 | 影响 |
|---|---|---|---|
| 发现层默认签名 | `SIGN_LIST` 默认 **true**，可用 `HG_SIGN_LIST=0` 关；空响应升级为需要签名 | `signLists` 默认 true；空 body 时 `_listSignatureRequired=true` 升级 | 基本一致 |
| 详情取源顺序 | **App 分集接口优先**，失败再回官网 WebSource（[Client.java:833-851](../../references/hongguo-android/app/src/main/java/com/hongguo/api/service/Client.java#L833-L851)） | **官网两页竞速优先**，失败再走 App 接口（`catalog.dart:917-979`） | 排序相反；官网坏边缘/限免边界时行为不同 |
| 播放路由 | 8 级尝试 + 换主机 + 身份重注册 + 官网兜底 | 3 级：官网直链/player ld+json → App `multi_video_model/v1` → 旧 `preload/v1` | 上游单点空响应时 Flutter 更容易整集失败 |
| 播放身份复用 | 成功身份缓存复用；401/403 才失效 | 每次取址都新注册，`_pending` 只共享在途请求，成功即丢弃 | 与 Android 实测结论相反，需在真网上做 A/B 验证后再改 |
| `MobilePlayerV5` / `video_tab` / `video_model/v1` | 已实现 | 未实现 | 可补为回退路由 |
| 设备池 | 代码有 `DevicePool`，当前固定 `null` | 无设备池，单 `device-id.txt`，可在设置里轮换 | 两端都单设备，无需急改 |
| 账号体系 | 官网/扫码/短信登录、云片单、预约、进度上报、弹幕、登录后推荐 | 仅 `SessionCredentials{cookie,ttToken}` 手工注入到内容请求头；无登录 UI/云片单 | 最大功能缺口；应按“只读验证 → 写回 → 同步”分期 |
| 错误分类 | 风控 / 登录失效 / 普通业务错三类，前两类不重放 | `PlaybackUnavailable`（终止）与 `IncompleteCatalogResponse`（可重试）两类；没有账号态概念 | 引入账号后必须补齐登录失效与写入不重放语义 |
| 账号凭据存储 | Keystore AES-GCM + AtomicFile + 禁备份 | `flutter_secure_storage` 的 `SystemSessionVault`，JSON 文件保存其它设置 | 需建立账号代次/隔离模型 |
| 更新 | GitHub Releases `update.json`，下载后校验大小/SHA-256/包名/版本/签名 | GitHub Releases 自更新 + SHA-256 校验 | 基本对齐 |

## 8. 验证边界

- 本文件只证明「源码里这么写」，不证明上游当前仍按此应答；接口存活、签名分支、账号登录结果必须按 [ACCOUNT_INTEGRATION.md:63-67](../../references/hongguo-android/docs/ACCOUNT_INTEGRATION.md#L63-L67) 的口径由本人账号验收。
- 账号类接口的写入（收藏/预约/进度）只受理一次并回读核对，不把 `code=0`/HTTP 200 写成“同步成功”。
- 不要把 Cookie、`biz_user_id`、设备 ID、签名 URL、媒体密钥写入日志或文档；诊断信息沿用参考实现的白名单字段策略。
