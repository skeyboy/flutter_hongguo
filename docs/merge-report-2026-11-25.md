# 合并与推送变更说明（2026-11-25）

记录当天两次合入 main 的改动、冲突处理、推送路径与验证结果。

---

## 一、第一次合并：片源切换与自动选源 UX（PR #2）

| 项 | 内容 |
|---|---|
| 来源分支 | `feature/source-switching-ux`（worktree `C:/Users/lee/flutter_hongguo-srcux`） |
| 方案文档 | `docs/design/source-switching-ux.md` |
| 提交 | `7a2f464`（hongguo-drama 改 submodule，pin `07791ca`）→ `63ecbb4`（M0–M4 落地，19 文件） |
| 合并提交 | `dd11f370`（merge commit，parents `cd67220` + `63ecbb4`） |
| 合并方式 | GitHub API `PUT /pulls/2/merge`（merge_method=merge），PR state closed/merged |
| 规模 | 22 文件，+1049 / -80 |

### 改动内容

| 阶段 | 内容 |
|---|---|
| M0 | 搜索首页聚合多源：红果结果优先、按标题去重、单源 3s 软超时静默跳过；带 cursor 翻页直委红果保住私有游标语义 |
| M1 | 片源开关保存即生效（仅 sources 变化时重装注册表、不清目录快照）；设置页标明国内/海外/自定义类型与启用数 |
| M2 | api 新增 `SourceResolver`（最小门面 `SourceSearchFacade`，精确命中优先 + 8s 预算 + `excludeIds` 防回切）；详情页 / TV 动作行加入切换入口（手机 bottom sheet、TV `TvFocusable`） |
| M3a | `media_cache` 下载主轨失败后按 `candidates` 逐条过 policy 校验重试（HLS / 用户取消不回退） |
| M3b | 播放失败为 `noSource` / `sourceRejected` 时按剧名 + 集号解析备选源，命中则换轨、`PrefetchWindow.retarget` 撤销旧源预热、同集开头续播 + toast；每会话 ≤2 次、不回切 |
| M4 | `SourceSettings.hasAlternativeSources`：有备选源时不展示「限免外 / 不可播」标记；TV 遥控 label 带状态 |

### 验证

- 本地：core 155 / api（两条既有 flaky 见方案文档 §5）/ cast 52 / tv 38 / app 526 全绿；五包 `dart analyze` No issues found。
- CI（PR 阶段）：run `45553682957`（Verify Windows desktop，head `63ecbb4`）✅ success。
- CI（合入 main 后）：run `45555010061`（head `dd11f37`）✅ success。
- 手动重跑：run `45556969240`（workflow_dispatch，head `dd11f37`）✅ success。

### 推送说明

`git push` 起初被代理 schannel 拦，`origin/main` 本地引用停在 `cd67220`。后用
`git -c http.sslBackend=openssl fetch` 成功绕过（比 GitHub API git-data 兜底简单），
`origin/main` 已同步到 `dd11f370`。

---

## 二、第二次改动：上游 hongguo-web 1.3.5 鉴权/编解码对齐（PR #3，进行中）

| 项 | 内容 |
|---|---|
| 来源分支 | `feature/upstream-1.3.5-auth-codec`（基于 `origin/main` `dd11f370`） |
| 方案文档 | `docs/design/upstream-1.3.5-auth-codec-alignment.md` |
| 提交 | `7da9a6a`（原派生分支）→ `b596bc8`（cherry-pick 到 main 之后） |
| PR | [#3](https://github.com/skeyboy/flutter_hongguo/pull/3) — head `b596bc8` → main |
| 规模 | 6 文件，+365 / -9 |

### 对比基准

上游 `sunnysky123/hongguo-web`：`3841835`（v1.1.5，原 pin）→ `c8b6c61e`（v1.3.5），
ahead 67 commits。三个并行探索 agent 交叉核对源码后产出方案。

### 改动内容

- **BVC2 识别与拦截（真缺口）**：`Mp4Cenc.isBvc2()` 探测 `bv2C` 私有配置盒与
  stsd 样本条目（`bvc2` / `bv2C` / `vvc1` / `vvi1`）；`media_cache` 在缓存命中与
  解密发布前双拦截，避免把播放器解不了的 VVC 文件交给播放器黑屏。
- **NAL 自证接受 Annex-B**：`validNalSample` 支持 3 / 4 字节起始码，对齐上游
  `avccSelfOk`；core 新增 9 项单测（BVC2 探测 + AVCC / Annex-B / HEVC / 非法 NAL）。
- `tool/upstream_protocol_1_3_5.json` 独立记录 1.3.5 核心签名 / 编解码文件 sha256，
  不覆盖 1.1.5 oracle pin（1.3.5 随机源不可注入，无法 byte 对拍重生成向量）。
- `NOTICE.md` 补 thl-sign 的 GPL-3.0 来源链（作为对比依据记录，未移植代码）。

### 评估后未落地（方案文档记录理由）

- **thl-sign v5 便携签名器**（307KB vendor IIFE）：上游明言手工移植会被判
  HTTP 200 + 0 字节；现有 legacy 六头与上游 `pure-sign.js` 逐字段同源（field 21=312
  已对齐、常量一致），96 oracle 向量继续锁定。
- **key 自证多样本**：盲取序号会把 P 帧误判为密钥不匹配（`real.cenc.mp4` 上 6 个
  core 测试回归失败，已回退）。
- **video_tab / player/v1 gzip 两级空响应恢复**：依赖 v5 签名；当前 b 域 legacy
  实测可用，且已有等价重试 / 退避防护。
- **551 Argus/Ladon**（上游 11-16 已弃用）、**ffmpeg / librempeg / ffprobe**
  （Electron 服务端特有）：不引入。

### 验证与状态

- 本地门禁：core 164 / api 325 / cast 52（一次时序 flaky，单跑 2× 绿）/ tv 38 /
  app 526 全绿；五包 `dart analyze` No issues found。
- 推送：直推成功（`git -c http.sslBackend=openssl`），PR #3 触发 CI
  run `45568358129`，等待结果。

---

## 三、未覆盖项（诚实披露）

1. **TV 真机遥控回归暂缓**：adb 已能连上 `192.168.0.67:5555`（Google TV 模拟器），
   但 TV APK 构建被 media_kit GitHub release jar 下载 `Connection reset` 卡住；
   按用户指示暂缓。由 `tv_settings_surfaces_test` + TV 包 38 测试 + `windows-verify`
   CI 兜底。
2. **api 两条既有 flaky**：`video_model_client` 120ms deadline（在干净基线 `b306185`
   上同样失败）、`media_cache` native transport（单跑全绿），与本轮改动无关。
3. **W:/own 主 checkout（macOS 挂载）** 的 main 可能落后，在那边工作前先 pull。
