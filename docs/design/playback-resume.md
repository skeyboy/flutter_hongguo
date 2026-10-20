# 剧集续播与自动连播

2026-10-20，项目 `/Users/lee/Desktop/flutter_hongguo`。

“开始观看”恢复这部剧最近实际播放的分集及进度；明确选择某一集时，恢复该集自己的未完成进度。已收到播放结束事件或进度已达到总时长的分集，从头开始播放。只接近片尾但尚未完成的分集继续原位置，不再以“剩余几秒”猜测播放完成。

## 数据与保存时机

`PersonalLibrary` 同时维护每部剧的最近记录 `history` 和按剧集 ID/视频 ID 区分的 `episodeHistory`。`WatchRecord.finished` 显式保存完成状态。旧版只有单集的记录会在加载时兼容导入，不丢收藏和最近续播位置；旧版从未保存的其他分集进度无法恢复。

播放中沿用 10 秒节流写入；暂停、切集、退出页面、应用切到后台和播放完成强制保存。TV 遥控提交进度（包括暂停状态下跳转）也立即保存。打开下一份媒体前等待已排队的保存完成，再读取目标分集进度，避免快速切集读到旧位置。保存失败显示反馈，不阻断播放。

个人记录保存在独立的个人数据文件，不随影视缓存淘汰删除。保留最近 500 部剧、最多 10000 条分集记录。删除一部剧的观看记录会同时删除其分集进度；清空历史也清空分集进度，收藏独立保留。

## 播放入口与连播

TV 与普通详情页的“开始观看”给播放器传递 `resumeLastEpisode`；具体选集只传对应索引。播放器统一使用 `PersonalLibrary.playbackStart` 解析起点，TV ExoPlayer 与其他端 media_kit 使用同一记录策略。“我的”历史入口及本地缓存播放仍可指定已有起点。

自动下一集本来默认开启；这次为旧安装增加一次性 `playbackPolicyVersion` 迁移，将旧设置启用连播。升级后用户若主动关闭并保存，后续启动尊重该选择。播放完成先记录当前集已完成，再准备下一集；下一集已有未完成记录时续播其进度。最后一集不会越界或循环；本地模式缺少连续的下一集时停止，不会自动联网下载。

## 验证

App 109 项测试通过；静态检查无问题。新增测试覆盖分集进度重启恢复、最近剧集定位、已完成从头播放、未完成的片尾续播、旧记录兼容、删除/清空，以及自动下一集旧偏好迁移和新选择持久化。

模拟器原生验证入口：在项目根目录运行

```bash
build/verification/tv-remote-venv/bin/python tool/verify_tv_device.py \
  --device emulator-5554 --input-source emulator \
  --test integration_test/tv_resume_playback_test.dart \
  --output build/verification/tv-resume-device
```

该测试使用可控 CENC 视频，经共享解密与实际 Android 播放器，验证上次分集/进度、手动选集续播、完成后从头、播放结束自动下一集，以及磁盘记录重新加载。证据目录：`build/verification/tv-resume-device/`；App 日志：`build/verification/playback-resume-app-all.log`。

Android TV API34 模拟器验证已通过：`TV_RESUME_PASS last_episode=true unfinished_resume=true completed_restart=true auto_next=true disk_persistence=true`。
