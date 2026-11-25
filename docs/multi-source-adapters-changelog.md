# 多源片源适配器——变更说明（P0–P4 全量）

- 分支：`feature/multi-source-adapters`（6 个提交，`a871c08..3177134`）
- 基点：`59bf638`；合并目标：`main`
- 规模：40 文件，+7975 / -23
- 方案来源：`docs/design/multi-source-adapters.md`；契约：`docs/contracts/` 三份

## 1. 这次改了什么

### P0 骨架与红果迁移（a854ee3）
- `packages/api/lib/src/source_id.dart`：`SourceKind`（builtin/custom）与
  `SourceException` 家族的唯一定义点。
- `packages/api/lib/src/source_adapter.dart` + `source_registry.dart`：
  `SourceAdapter` 抽象（browse/search/detail/test/validate）与
  `SourceRegistry`（按 `sourceId` 前缀路由，`expansiveFactories` 支持运行时
  注册自定义源）。
- `packages/api/lib/src/routing_catalog.dart`：`RoutingCatalogRepository`
  门面，实现既有 `CatalogRepository/Filtered/Rank` 三接口，红果行为字节级
  不变（`hongguo` 不可关闭，永远第一跳）。
- `sources/hongguo_adapter.dart`：原 `hongguo_api` 逻辑迁为适配器，红果
  关键路径零语义变化。
- `packages/app/lib/platform/runtime_native.dart`：运行时装配注册表 +
  路由目录；按 `vid` 前缀把播放取址路由到来源适配器。

### P1 国内明文 MP4 源（0185379）
- `sources/xifan_adapter.dart`（西饭）、`sources/hema_adapter.dart`（河马）：
  国内源，明文 MP4 直链，逐跳走 `MediaUrlPolicy` 校验。默认启用。

### P2 海外源（7ad8029）
- `sources/dramabox_adapter.dart`（DramaBox）、`sources/reelshort_adapter.dart`
  （ReelShort）：英文官网离线解析（`__NEXT_DATA__`），默认**关闭**（海外
  网络）。
- **HLS 硬门槛**：m3u8 一律判 `SourceUnavailable`（明确文案），不静默失败；
  MediaCache 下载层提供兜底。评估记录：`docs/design/hls-channel-evaluation.md`。

### P3 苹果 CMS 自定义源 + SSRF 防护（0493a03）
- `sources/custom_source_adapter.dart`：苹果 CMS `api.php/provide/vod` 接口，
  自动补齐路径（裸域名 → `/api.php/provide/vod/`），`validate` + `test`
  连通性检查。
- `packages/core/lib/src/config/app_settings.dart`：`CustomSourceConfig`
  （uuid/name/url/enabled）、`SourceSettings`（内置开关表 + 自定义列表，
  `upsert/remove/toggle/withBuiltin` + validate + JSON 往返）、
  `newSourceUuid()`（RFC 4122 v4，secureBytes）。
- **SSRF 防护**（`packages/core/lib/src/crypto/media_url.dart`）：
  `isPublicMediaUrl` 只放行 https、无 userInfo、443 端口；拒绝私网/回环/
  链路本地/多播/CGNAT/TEST-NET（含 `198.51.100.0/24`、`203.0.113.0/24`）/
  `198.18.0.0/15`；还原十进制、八进制、十六进制 IPv4 与 `::ffff:` IPv6
  映射。`mediaKeyEscape` 单射编码（`_XX` hex）做缓存键。
- 契约：`docs/contracts/source-adapter.md`、`source-id.md`、
  `media-url-policy.md`；`NOTICE.md` 补多源来源链。

### P4 设置页片源分区与 TV 收口（3177134）
- `packages/app/lib/features/settings_page.dart`：新增「片源」分区（含侧边
  锚点与「内容列表」锚点补齐）。内置源开关由注册表派生（web/tv 与测试环境
  退回静态清单）；自定义源行支持开关/删除；「添加自定义片源」弹层支持
  名称 + URL 输入与「测试连接」，改动先落 draft、随统一保存事务持久化。
- **TV 分支**：遥控无文本输入——自定义源行用 `_tvRow`（启用/停用）+
  `_tvButton`（删除），不渲染「添加」按钮，改为提示去手机/桌面端添加。
  保证 `tv_settings_surfaces_test` 的「每个控件都是遥控目标」约束成立。

## 2. 兼容性影响

- **红果路径零语义变化**：老用户无感知；`sources` 是 `AppSettings` 新末位
  字段，老 JSON 缺省回退默认值。
- 首页/搜索结果开始混入西饭、河马内容（可在设置关闭）；海外源默认关。
- `Episode` 增加 `locked` 字段；`VideoTrack` 增加
  `source/format/candidates/policy`（`copyWith` 兼容）。
- 缓存键切换到 `mediaKeyEscape` 编码，旧缓存条目将重新下载一次。

## 3. 验证记录

| 门禁 | 结果 |
|---|---|
| `flutter test` core / api / cast / tv / app | 154 / 312 / 52 / 38 / 525 全绿 |
| `dart analyze`（全仓） | 0 error / 0 warning |
| `flutter build apk --debug --flavor mobile` | 成功 |
| `flutter build apk --debug --flavor tv` | 成功 |
| Windows 桌面真机运行（片源分区 + 自定义源弹层） | 见下节 |
| TV 真机（遥控器） | 未执行——本机无 TV 设备/模拟器，用
  `tv_settings_surfaces_test`（遥控可达性）+ TV APK 构建 + `hongguo_tv` 包
  测试（38）兜底；建议在 TV 设备上补一次人工回归 |

## 4. 已知边界

- 自定义源仅支持未加密 MP4 分集；HLS 明确不支持并给出可读文案。
- 海外源内容为英文短剧，发现页排序权重与红果一致，混排可关。
- `custom_source_adapter.test()` 做真实网络请求（连通性检查），失败会给出
  具体错误文案。
