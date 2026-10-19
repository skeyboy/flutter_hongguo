# hongguo_api

主工程的内容访问、播放取址与媒体缓存包。

- `lib/hongguo_api.dart`：CatalogRepository/CatalogClient、视频模型请求与选流。
- `lib/hongguo_native_api.dart`：原生 MediaCache；流式下载、解密调度、lease 取消与缓存。
- `lib/src/catalog.dart`：搜索、分类/题材、详情、分集和官网回退。
- `lib/src/video_model_client.dart`：原始字节签名请求、fallback、URL 与轨道选择。
- `lib/src/media_cache.dart`：原生下载/解密/缓存流水线。
- `bin/mac_poc_probe.dart`：需要显式执行的真实上游单集探测，不属于离线回归。
- `test/`：Dio mock、内容解析与本地缓存验证。

从本目录运行离线测试：

```bash
../../.fvm/flutter_sdk/bin/dart test
```

[原接口分析](../../docs/analysis/API-reference.md) · [分析与源码对应表](../../docs/project-map.md) · [Mac 验收](../../docs/macos-independent-app-poc.md)
