# 初步共享 Dart 核心验证

> 文档与源码目录见 [项目索引](README.md)；已有验收结果的持久化快照见 [证据索引](evidence/README.md)。

日期：2026-10-19。当前目标是验证原项目关键算法可否从 Node 迁移到 Dart，并建立 Flutter 跨平台工程。不是完整播放器交付。

## 项目结构与参考方式

参考 `hack-news-flutter` 的 Dart workspace 与 core/api/app 分层，以及根目录依赖集中策略。使用其已解析的 Dio 5.11.1、flutter_riverpod 3.4.3、get_it 8.3.0；另外增加 crypto 3.0.7、pointycastle 4.0.0、test。Flutter 3.47.4 与参考项目一致。

核心保持纯 Dart；不像参考 core 包那样混入主题/Flutter API。这样可直接 dart test、编译原生 AOT 和 JavaScript。Flutter app 通过 GetIt 注册离线诊断入口、Riverpod provider 注入。

暂未引入 Retrofit/Freezed/AutoRoute/SQLite：当前没有相应页面/持久化模型需求，签名请求必须精确保留原始 body 字节，直接使用 Dio Stream 数据源。这些依赖可在后续 DTO、页面路由与缓存阶段按参考项目引入，不复制其整套 codegen overrides。

## 已完成

- PureSign 六个签名头：Gorgon/Khronos/Ladon/Argus/Helios/Medusa，含 hashF13 分支和定制 AesV3。
- 明确 JS 32 位有符号/无符号操作，64 位路径使用 BigInt；保留原函数/运算结构方便审查。
- 可注入时钟与随机源；生产默认安全随机，测试使用确定性序列。
- spade v1 解包、flag 回退、格式校验；v2 仍不支持。
- SHA512 派生 URL AES-CBC key/IV、解码与地址白名单检查。
- 标准 AES-CTR 原语，与 Node 跨块向量一致。
- App 模型 POST payload、设备 query 编码、避分支 1、不可修改的签名 body/headers。
- Dio 直接发送签名后的原始 bytes；fallback 不带六头签名，禁用自动重定向。
- fallback 字符串/数组/对象/JSON 包装解析、视频列表选流、URL 解码、spade 预校验。
- Android/iOS/macOS/Windows/Linux/Web Flutter 宿主工程与离线验证页。

## 证据与测试覆盖

Node oracle 使用 vm 在内存中固定 Date、crypto.randomBytes/randomInt，不修改原项目源码。每个 case 新建签名上下文，对齐进程 nonce/启动时间。原签名文件 SHA256 保存在 fixture 的 sourceSha256。

| 验证 | 设计 |
|---|---|
| 96 个签名向量 | 每个逐一核对全部六头；覆盖分支 0/1/2、四种 AesV3 低两位、32 位时间戳高位、无 query、超 53 位字符串 ID、null/空/二进制/UTF-8 body |
| 5 组 spade 真值 | 来自原项目已有离线向量，验证原始解包与 Base64 入口 |
| URL CBC | 用 Node 标准 AES 构造 envelope，Dart 解回原 URL |
| CTR | 513 字节，跨多个块，验证 Node→Dart 密文一致及解回明文 |
| 负向校验 | 畸形 spade、截断 URL envelope、协议/域/端口/用户信息限制 |
| API mock | 精确传输字节、MD5 stub、不可变请求、fallback 包装、拒绝越域、编码与清晰度选择 |
| Flutter widget | 真实运行共享核心诊断，五项全部 PASS |
| AOT / dart2js | 同一批 103 个正向向量（96 签名+5 spade+URL+CTR），无 dart:io/Flutter 依赖 |

自动脚本：`tool/verify_all.sh`；原始日志：`build/verification/`。测试只使用本地数据/模拟 Dio adapter，不请求上游视频接口。

## 本机执行结果

- `dart analyze`：No issues found。
- core：104/104；api mock：8/8；Flutter widget：1/1。
- 原生 AOT 与 dart2js：分别通过 103 个正向向量。
- Flutter Web release：构建成功，产物在 `packages/app/build/web`。
- Flutter macOS debug：构建成功，产物在 `packages/app/build/macos/Build/Products/Debug/hongguo_app.app`；本次未手动启动该 App。
- 机器可读汇总：`build/verification/summary.json`。

## 重要边界

1. AES-CTR 原语通过不等于完整 MP4 已能播放：moov、tenc/senc、sample offset/size、每轨 IV、自证、CENC 减壳均未移植。
2. AppSource 取址客户端通过模拟验证，尚未在真实上游验证其返回格式和可用性；禁用重定向是本版明确行为差异。
3. 96 组对拍说明这些输入路径与原 JS 一致，不构成所有输入的数学等价证明。
4. 原生 AOT 在当前 macOS arm64 上运行；其他原生平台尚未真机运行。Web 算法在 dart2js 产物的 Node host 上运行，不代表浏览器可绕过 CORS/请求头限制。
5. Flutter 页面是验证入口；没有宣称实现搜索/选集/下载/播放完整产品。
6. API/core 不带用户会话；参考项目 `.env`、密钥、数据库均未复制。

## 下一阶段最小闭环

1. 移植 MP4 parser 和逐轨样本解密，使用原项目生成的确定性 fixture 测试，不从公网下载样本。
2. 完成纯 Dart 减壳并原子发布成品；worker isolate 接收文件路径，避免 UI 线程处理大文件。
3. 增加流式下载、取消、失败清理、缓存和进度状态；不复制当前 Node 全文件聚合的内存策略。
4. 接入播放器，在 macOS/Android 优先完成单集播放、音频与 seek 验证；再覆盖 iOS/Windows/Linux。
5. 补 Client 搜索/分类/分集 Repository 与页面；修正原源码已识别的异步/分页问题。

结论：现阶段已有可运行证据支持“共享 Dart 签名与基础媒体加密核心可行”；完整端侧播放的剩余关键验证是 MP4 容器处理、解密吞吐和目标设备解码。
