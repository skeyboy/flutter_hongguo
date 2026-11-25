# 契约：逐轨媒体 URL 安全策略

> 替代当前 `fromWeb` 布尔开关的固定域名白名单。第三方/自定义源主机不固定，必须逐轨声明策略并在**每一跳重定向**复用校验。
> 依赖：[SourceAdapter 契约](./source-adapter.md)。语义来源：[多源方案 §3.5](../design/multi-source-adapters.md)、参考 `web-media-guard.js`。

## 0. 为什么必须改

当前 `MediaUrlDecoder.checked(value, domains)` 只校验 scheme/userInfo/port/域名表（`core/lib/src/crypto/media_url.dart:50`），`media_cache.dart:593` 用 `track.fromWeb ? webMediaDomains : appMediaDomains` 二选一。这两个域名表**只有字节系 CDN**，任何第三方/自定义源主机都会判非法。

不能用「放宽全局域名表」解决——那会让 SSRF 面扩大到所有源。改为**逐轨声明策略**。

---

## 1. 公网媒体 URL 判定（Dart 版 `isPublicMediaUrl`）

```dart
/// 纯函数，无 IO、无 DNS。在 packages/core/lib/src/crypto/media_url.dart 新增。
/// 返回 null 表示合法；返回 String 为拒绝原因（用于诊断与文案，不回传远端异常）。
String? isPublicMediaUrl(Uri url);
```

### 1.1 判定表（全部满足才放行）

| 检查项 | 规则 | 拒绝 |
|---|---|---|
| scheme | 必须 `https` | 其它（含 http） |
| userInfo | 必须为空 | 任何 `user:pass@` |
| port | 必须 443（或显式默认） | 非 443 |
| host | 非空、合法 DNS 名或 IP | 空 host |
| IP 字面量 | 不得为私网/回环/链路本地/多播/未指定 | `10/8`、`172.16/12`、`192.168/16`、`127/8`、`169.254/16`、`224/4`、`0.0.0.0`、`::1`、`fc00::/7`、`fe80::/10` |
| Fake-IP | 不得落在 `198.18.0.0/15` | 该网段（VPN Fake-IP） |
| 降级写法 | 十进制/八进制/十六进制 IP、IPv4-mapped IPv6（`::ffff:127.0.0.1`）需还原后再判 | 还原后命中上面任一条 |
| 凭据 | URL 中不得含 `userInfo` | 同 userInfo 行 |

> **注意**：DNS rebinding 无法靠纯函数挡住，`isPublicMediaUrl` 只挡字面量与凭据。真正的防 rebinding 在 §3 的逐跳校验（连接时的 IP 由底层解析，本项目用 Dio 的 `beforeRedirect` 拿不到连接 IP——见 §3.2 的诚实边界）。

---

## 2. 逐轨策略（`packages/api/lib/src/media_url_policy.dart`，新增）

```dart
sealed class MediaUrlPolicy {
  const MediaUrlPolicy();
}

/// 红果：app/web 域名表（现有行为字节级不变）。
class DomainAllowlistPolicy extends MediaUrlPolicy {
  const DomainAllowlistPolicy(this.domains);
  final List<String> domains; // appMediaDomains 或 webMediaDomains
}

/// 第三方/自定义源：公网校验 + 可选逐源主机集。
/// hosts == null 表示只做公网校验（上游主机列表可能动态，按域名归属由适配器收窄）。
class PublicWebPolicy extends MediaUrlPolicy {
  const PublicWebPolicy({this.hosts, this.refererHost});
  final List<String>? hosts;      // 逐源主机族，如 ['xifan.tv', 'hema.tv']
  final String? refererHost;      // 逐源 Referer 域名（可选，用于 header）
}
```

### 2.1 策略映射（谁用哪个）

| 源 | 策略 | 理由 |
|---|---|---|
| hongguo（app 层） | `DomainAllowlistPolicy(appMediaDomains)` | 现有行为不变 |
| hongguo（官网层 / `fromWeb`） | `DomainAllowlistPolicy(webMediaDomains)` | 现有行为不变 |
| xifan / hema | `PublicWebPolicy(hosts: [本源域名])` | 明文 MP4，域名相对固定 |
| dramabox / reelshort | `PublicWebPolicy(hosts: [本源域名])` | 海外 CDN，可能含 HLS |
| custom:{uuid} | `PublicWebPolicy(hosts: 配置声明的域名族)` | 用户可控 URL，最强攻击面 |

### 2.2 `checkMediaUrl`（统一入口）

```dart
/// 在 MediaUrlDecoder.checked 之前调用；返回校验后的 Uri，非法抛 FormatException。
/// 红果轨仍走原 MediaUrlDecoder.checked（CENC 解密），本函数只加一层策略判定。
Uri checkMediaUrl(String value, MediaUrlPolicy policy);
```

流程：
1. `isPublicMediaUrl(uri)` 先过公网判定（红果域名也在公网，天然通过）。
2. 按 policy 分派：
   - `DomainAllowlistPolicy` → `MediaUrlDecoder.checked(value, domains)`（保持字节级一致）。
   - `PublicWebPolicy` → 若 `hosts != null`，要求 `hosts.any((h) => uri.host == h || uri.host.endsWith('.$h'))`；否则仅公网判定通过即可。
3. 返回 `uri`。

> 加密轨（`spadeA.isNotEmpty`）的红果 URL 是密文字符串，`checkMediaUrl` 在解密**之后**的明文 URL 上调用（`video_model_client.dart:820` 的 `MediaUrlDecoder.checked(decoded, ...)` 位置），不改解密流程。

---

## 3. 逐跳重定向校验（替代 `fromWeb` 布尔的核心）

当前 `media_cache._downloadFollowingRedirects` 已有 302 跟随循环。**在每一跳插入同一校验**，等价于参考的 `beforeRedirect`：

```dart
// 伪码：media_cache 下载循环内
var current = track.url;
for (var hop = 0; hop < maxRedirects; hop++) {
  final reason = isPublicMediaUrl(current);
  if (reason != null) throw SourceRejected(...);   // 每跳都校验，不是只校验首跳
  if (!track.policy.allows(current)) throw SourceRejected(...);
  final response = await dio.getUri(current, followRedirects: false);
  if (isRedirect(response.statusCode)) {
    current = Uri.parse(response.headers.value('location')!);
    continue;                                       // 下一跳重新校验
  }
  return response;
}
```

### 3.1 必须遵守

1. **不能「先探测后连接」**（TOCTOU）——直接在跟随循环里逐跳校验，不另起探测请求。
2. **Location 相对 URL 要基于当前跳 resolve**，不能基于首跳。
3. **每跳都过 `isPublicMediaUrl` + policy.allows**，不是只校验首跳。
4. **`cancelRequests` 按源撤销**：配置变更时，自定义源工厂取消该源在途请求（P3）。

### 3.2 诚实边界（必须在 P2 评估文档记录）

- Dart/Dio 的 `onBeforeRedirect` 能拿到 `Location`，但**拿不到实际连接的 IP**，因此 DNS rebinding（域名解析到私网 IP）无法在应用层完全挡住。
- 本项目缓解：逐源主机集（`hosts` 白名单）+ 公网字面量校验 + HTTPS 强制；对自定义源额外要求配置期 `validateSource` 做 DNS 解析检查（`InternetAddress.lookup`，仅配置时一次，非每次请求）。
- 不宣称「完全防 SSRF」——文档需明确残留风险。

---

## 4. 验收判据（SSRF 单测用例，P0 建骨架 / P3 全量）

`isPublicMediaUrl` 单测必须全部拒绝以下输入（含等价变形）：

- [ ] `http://example.com/v.mp4`（非 https）
- [ ] `https://user:pass@example.com/v.mp4`（凭据）
- [ ] `https://127.0.0.1/v.mp4`、`https://[::1]/v.mp4`（回环）
- [ ] `https://10.0.0.1/v.mp4`、`https://172.16.0.1/v.mp4`、`https://192.168.1.1/v.mp4`（私网）
- [ ] `https://169.254.169.254/latest/meta-data`（链路本地 / 云元数据）
- [ ] `https://198.18.0.1/v.mp4`（Fake-IP）
- [ ] `https://2130706433/v.mp4`（十进制 127.0.0.1）
- [ ] `https://0x7f000001/v.mp4`（十六进制 127.0.0.1）
- [ ] `https://[::ffff:127.0.0.1]/v.mp4`（IPv4-mapped）
- [ ] 合法公网 URL 通过：`https://cdn.example.com/v.mp4`

逐跳测试（P0 起，用 Dio adapter mock）：

- [ ] 首跳合法 → 302 到 `http://127.0.0.1/x` → 拒绝，且不发起第二跳请求。
- [ ] 首跳合法 → 302 到 `https://evil.com/x` 且 policy.hosts 不含 → 拒绝。
- [ ] 相对 Location `/next` → 正确 resolve 到当前 host，校验通过。

红果回归：

- [ ] `DomainAllowlistPolicy(appMediaDomains)` 下既有 191 项 api 测试的 URL 全部仍通过。
- [ ] `checkMediaUrl` 不改变 `MediaUrlDecoder.checked` 的错误类型/文案。
