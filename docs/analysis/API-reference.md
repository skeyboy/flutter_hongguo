# API 参考：本地服务与上游映射

依据当前 1.1.1 源码整理，非上游官方文档；未在线验证第三方接口。默认本地 Base URL：`http://127.0.0.1:8000`。路径没有统一 `/api` 前缀。

## 1. 鉴权与响应约定

- 数据接口：`x-api-key: <本地 key>`，或 `?api_key=<本地 key>`；头优先。
- 管理接口：`x-admin-token`，或 `admin_token` query；不使用数据 key。
- `/`、`/health`、`/api-key`、`/img`、UI 静态资源无需 key。
- 数据接口默认每 key 最近 60 秒最多 120 次（RATE_PER_MIN 可覆盖）；视频 Range 请求也计入。
- 没有统一 `{code,data}` 包装；各路由直接返回对象。常见错误 `{detail:"说明"}`。
- 400 缺失/无效业务参数；401 本地鉴权或上游登录失效；404 无分集/无直链；429 限流；502 未捕获的业务/上游异常；stream 成功可能为 200/206，非法区间为 416。
- series_id、vid 和 device_id 应作为字符串，不能转为浮点数字。

## 2. 本地接口清单

| 方法与路径 | 参数、默认值 | 返回与语义 |
|---|---|---|
| GET `/` | 无 | service/ui/managed/endpoints |
| GET `/health` | 无 | ok、uptime_s、sign_backends、api_host、ffmpeg、transcode、h264_encoder |
| GET `/api-key` | 无 | api_key、note、rate_per_min；返回第一把启用 key，否则生成 |
| GET `/search`、`/search/page` | q 必填；limit 默认由 Client 取 20，最大 40；offset 默认 0 | query/count/results/has_more/next_offset |
| GET `/rank` | board=recommend/hot/new，默认 recommend；limit=30；offset=0 | board/name/items；offset>0 时另有 has_more/next_offset。这里是漫剧榜 |
| GET `/latest` | genre=short_play；only_today 默认 true（仅字面 false 关闭）；limit=120；refresh/no_cache=true 可刷新；offset=0；seen=逗号分隔 ID | genre/name/mode/only_today/count/items；分页分支另有 has_more/next_offset。漫剧与 AI 短剧固定近 7 天逻辑 |
| GET `/filters` | genre=short_play | genre/name/rows；每行 type/row_name/selection_type/items，项含 id/name |
| GET `/browse` | genre=short_play；theme/setting/background/sort/gender/days/status；limit 默认 60、最大 120；offset=0；seen | genre/name/count/items；条件性 has_more/next_offset；条目补 stream_url/episodes_url |
| GET `/episodes` | series_id 必填 | meta 对象和 episodes 数组 |
| POST `/metrics/batch` | JSON：series_ids 数组或 CSV；兼容 series_id；batch_size 默认 20、上限 20；输入最多 200 项 | count/items/failed，items 是剧集 meta，不是分集数组 |
| GET `/play` | series_id 必填；ep 默认 all，可用选集范围 | series_id/title/note/episodes；逐集含 index/vid/title/duration/encrypted_url/size/definition/url_is_http/stream_url；无可用地址的条目仍可能存在 |
| GET `/video_url` | vid 必填 | vid/url/size/definition；内部固定 best，可能仍是加密媒体 |
| GET `/prewarm` | vid 必填；quality=best | ok/vid/state；state 为 cached、warming、failed。ok=true 不表示已能播放 |
| GET `/stream` | vid，或 series_id+ep（默认 1）；quality=best | 普通 MP4 字节，支持基本 Range；可直接作为 video.src |
| GET `/download` | vid，或 series_id+ep（默认 1）；quality=best | ok/path/size；返回服务端文件路径 JSON，不是附件字节 |
| GET `/img` | url | 封面字节代理，初始地址限域；不保证 HEIC 转为浏览器兼容格式 |
| GET `/stats` | 管理口令 | uptime_s/requests/errors/risk/auth_fail/cache_backend/sign_backends/enabled_keys |
| GET `/admin/keys` | 管理口令 | keys/enabled_count；包含完整 key，调用端应妥善处理 |
| POST `/admin/keys` | 管理口令；note 为 query 参数 | ok/key/note |
| POST `/admin/keys/revoke` | 管理口令；key；enable=true 表示启用，否则禁用 | ok |
| DELETE `/admin/keys` | 管理口令；key | ok |

通用 genre：`short_play`、`comic_series`、`ai_series`。
筛选映射：theme→category_dim_theme，setting→category_dim_role，background→category_dim_epoch，days→online_time，status→creation_status。可接受代码映射的名称或 ID；调用端优先读取 `/filters`，避免固定假设类别存在。sort 常用 online_time/hot_score/hot_collect，days 常用 7/14/30/90，status 可用已完结/连载中。

**当前实现限制**：`/browse?offset=...` 进入分页分支时应同时提供非空 seen；只传 offset 会在 split 处异常。`/play`、`/video_url` 不接收有效的清晰度选择参数。回传的相对播放 URL 未附 key，使用方须自行补齐。完整错误与实现问题见主报告。

## 3. 数据结构

```text
SearchResult：series_id,title,episode_cnt,score,play_cnt,hot,copyright,
              cover,tags,abstract,vid,duration,horiz_cover
Episodes：{meta:{series_id,title,abstract,episode_cnt,status,play_cnt,
                followed_cnt,create_time,cover,category,tags,celebrities},
           episodes:[{index,vid,title,duration,cover,comment_count,digged_count,...}]}
```

不同来源/列表类型字段可能缺失、为空或类型不同；不能按搜索字段强制解释所有列表条目。官网回退缺少富元信息，web_available 只表示官网限免展示信息，不是 App 取址授权或可播性的保证。

## 4. 最小接入示例

服务已启动时，在项目根目录运行以下 Node 脚本。脚本会访问本地服务；本地服务按请求需要访问上游。将剧 ID 作为第一个参数、集号作为第二个参数传入：

```bash
./node/bin/node - '1234567890123456789' 1 <<'JS'
(async () => {
  const base = 'http://127.0.0.1:8000';
  const seriesId = process.argv[2], ep = Number(process.argv[3]);
  async function get(path, headers = {}) {
    const r = await fetch(base + path, {headers});
    const data = await r.json();
    if (!r.ok) throw new Error(data.detail || `HTTP ${r.status}`);
    return data;
  }
  const {api_key: key} = await get('/api-key');
  const detail = await get('/episodes?series_id=' + encodeURIComponent(seriesId),
    {'x-api-key': key});
  const episode = detail.episodes.find(x => x.index === ep);
  if (!episode) throw new Error('集号不存在');
  const url = new URL('/stream', base);
  url.search = new URLSearchParams({vid: episode.vid, api_key: key}).toString();
  console.log('将以下地址设置为 video.src（含本地访问凭据，不公开分享）');
  console.log(url.toString());
})().catch(e => {console.error(e.message); process.exitCode = 1;});
JS
```

上面的数字为格式示例，不代表真实可用剧目。本次未运行该联网示例。若已在当前 UI 中获取分集，只需使用已有 vid 构造 stream 地址，不必再请求 `/play`。

## 5. 上游接口映射

普通元数据主机取 `upstream.api_host`，当前配置为 `api5-normal-sinfonlinea.fqnovel.com`；播放取址单独固定 b 主机。基础 query、设备、时间戳和签名由服务端统一补，不由浏览器处理。

| 上游方法与路径 | 请求重点 | 响应提取 | 本地消费者 |
|---|---|---|---|
| GET a主机 `/reading/bookapi/search/tab/v` | query/tab_name=feed/search_source=1/offset/count=10/use_correct=true；续页 passback/search_id；签名 | search_tabs[0].data、next_offset、passback、search_id、has_more | search/page |
| POST a主机 `/novel/player/multi_video_detail/preload/v1` | series_id 字符串，可 CSV；dr_scene=preload；biz_param 见下；签名 | data[sid].video_data | episodes、metrics/batch |
| GET a主机 `/reading/bookapi/bookmall/cell/change/v` | cell_id=7470092475068071998；tab_type=26；client_req_type=2；client_template=2；selected_items=comic_series_rank；sub_selected_items 选择对应榜；session_uuid、offset | data.cell_view.cell_data | rank |
| POST a主机 `/reading/distribution/category/landpage/v` | req_scene、select_items、filter_ids、offset、limit、need_selector_panel、req_type | data.video_data 或 selector_rows | latest、browse、filters |
| POST b主机 `/novel/player/multi_video_model/v1/` | mixed_video_id_map:{"1004":[vid]}，biz_param，独立设备 query 和六头签名 | data[vid].video_model.fallback_api | AppSource.fetch |
| GET 响应提供的 fallback_api | HTTPS/API 域白名单；仅 User-Agent，无六头签名 | video_info.data.video_list、key_seed | URL 解码与选流 |
| GET CDN 媒体 URL | 已解码地址、CDN 白名单；Mozilla/5.0 UA | 完整 MP4 文件 | download/stream |
| GET `https://hongguoduanju.com/search/{keyword}` | 桌面 UA、Accept-Language、Referer，免签 | SSR searchList | 设计上官网搜索优先；当前漏 await |
| GET `https://hongguoduanju.com/player/{series_id}` | 同上 | vid_list、series_name、series_cover、accessible_episode_cnt | 设计上详情回退；当前漏 await |

榜单和 landpage 只有 `HG_SIGN_LIST` 为真才签名，默认免签；搜索/详情始终签名。

### 5.1 分集详情 body

```json
{
  "series_id":"1234567890123456789",
  "dr_scene":"preload",
  "biz_param":{
    "detail_page_version":0,
    "disable_digg_stat":false,
    "image_shrink_datas_str":"由 client.js 的 IMAGE_SHRINK 常量提供",
    "need_all_video_definition":false,
    "need_mp4_align":false,
    "screen_width_px":"900",
    "source":7,
    "use_os_player":false,
    "use_server_dns":false
  }
}
```

此块为字段说明，image_shrink_datas_str 应使用源码常量，不是将中文说明原样发送。

### 5.2 App 播放模型 body

```json
{
  "biz_param":{
    "detail_page_version":0,"device_level":3,
    "disable_digg_stat":false,"need_all_video_definition":true,
    "need_mp4_align":false,"use_os_player":false,
    "use_server_dns":false,"video_platform":1024
  },
  "mixed_video_id_map":{"1004":["1234567890123456789"]}
}
```

这条链路不带 dr_scene。保留路径末尾 `/`、query 的实际编码和 body 字节，签名后不再改动。没有发现当前播放路径调用旧 multi_video_model/preload/v1 或官网 main_url 探测；相关注释是历史背景。

### 5.3 landpage body

共同字段：`filter_ids` 为已展示 ID 的 CSV，`req_scene` 随 genre 变化，`offset`、`limit` 为数字，`session_id=''`、`client_req_type=3`。

- latest：`req_type=only_content`、`need_selector_panel=false`；sort=online_time，非短剧增加 online_time=[days_7]。
- browse：`req_type=only_content`、`need_selector_panel=false`，select_items 包含筛选映射。
- filters：`req_type=default`、`need_selector_panel=true`、offset=0、limit=1，读取 selector_rows。

## 6. 超时、重试、缓存

| 链路 | 行为 |
|---|---|
| Client 普通 API | 30 秒超时；搜索调用指定 1 次，详情/列表通常 3 次；仅特定异常重试；节流默认 260ms |
| 风控重试 | 等待 (2^attempt+1) 秒；MANAGED 模式不做该容错 |
| 登录态过期 | refreshSession 当前为空操作，等 1 秒再试；不能据此恢复 token |
| AppSource POST / fallback GET | 各 15 秒超时；单次 fetch 内无同等通用重试；签名分支尝试不等于网络重试 |
| MP4 下载 | 120 秒超时，完整响应在内存聚合后写盘 |
| prewarm | 首次+2 次重试，间隔 500ms；4 并发、64 排队 |
| 视频缓存 | 默认 server/stream-cache；最多 30 成品，按修改时间淘汰 |

代码定位：`server.js:route`、`client.js:api/searchPage/getEpisodes/landpageBody/browsePage`、`app-source.js:payload/postSigned/fetch`、`stream.js:ensureDecrypted`。
