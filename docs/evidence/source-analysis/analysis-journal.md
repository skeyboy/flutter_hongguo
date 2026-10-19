# 分析记录

日期：2026-10-19；范围：本地 JavaScript 源码、离线模拟。

- 路由 PRIMARY：js-reverse；offline-sample scope 已落地。
- 实际工具：随包 node/bin/node、rg、Python 3；未需要浏览器 Hook 或安装工具。源码可用，因此采用静态调用追踪代替在线 Capture。
- 完成：路由、源码取证、接口映射、算法拆分、离线回归、文档生成。
- 现有自检 165/165 通过；补充签名结构与 spade 5 组真值检查通过。
- HTTP mock 复现官网漏 await，结果 search=[]、episodes=null；未改业务代码。
- 方法经验：异步移植项目必须检查调用方与被调用方的 async/await 契约；算法单测通过不能代表官网/上游数据源可用。
- 未做：上游联网验证、真实内容可播性验证；无在线请求或下载新增视频。
- 交付：docs 下主报告、API-reference、AI-workflow；源码指纹见 source-sha256.json，原始回归输出见 selftest.log。
