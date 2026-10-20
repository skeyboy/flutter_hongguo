# hongguo_tv

独立 Flutter TV 交互模块，仅依赖 Flutter。没有 hongguo_core/api、HTTP、文件、播放器 SDK 或应用路由依赖。App 通过回调接入现有 Runtime 与 media_kit。

- `TvEnvironment` / `tvBuild`：TV flavor 或显式开发预览配置。
- `TvNavigation`：未被子控件处理的五向导航；不接管编辑器文字输入，处理可返回路由的 Back。
- `TvFocusable`：一个控件一个焦点，明确聚焦描边；确认键重复事件不重复激活。
- `TvGrid`：按稳定 ID 保存焦点；方向移动前先滚动并构建屏幕外目标行。
- `TvPlayerState`：画面、控制栏、进度预览、面板四层状态；进度 clamp 与返回/提交。
- `TvPlayerSurface`：遥控器操作层，播放/seek/选集/清晰度通过回调传出，不访问媒体文件。

从包目录运行 `../../.fvm/flutter_sdk/bin/flutter test`。主工程集成与构建命令见 `docs/design/android-tv-implementation.md`。

确认支持 select / Enter / numpadEnter / gamepad A；Back 支持系统返回、Escape/goBack/gamepad B。音量、电源和 Home 留给系统。控制栏聚焦时保持显示；“返回画面”或 Back 隐藏。面板占用焦点时方向键不触发 seek。视频根节点左右进入预览、确认提交、Back 取消。
