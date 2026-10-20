# 红果 · 果中有戏

以「果实 + 播放键」组成单一标记：暖白果身包住负形播放三角，斜向金色叶片形成向上生长的动势。深莓红避免普通播放器的大红三角视觉，暖白与杏金提供轻盈、温暖的内容品牌气质。无文字，缩小到 16px 仍能辨识果实与播放关系。

- 编辑母版：hongguo-icon.svg，1024 × 1024。
- 不透明图标：hongguo-icon-1024.png，iOS/Android/Web 使用系统遮罩。
- 透明桌面图标：hongguo-desktop-1024.png，圆角底板留白适配 Dock/任务栏。
- icon-preview.png：平台形态与小尺寸预览。

已接入主工程 packages/app：iOS/macOS AppIcon 资源、Android 各密度与 adaptive icon/Android 13 monochrome、Windows 多尺寸 ICO、Web favicon/PWA maskable、Linux hicolor/桌面入口与窗口内嵌图标。Linux 安装到用户桌面时需将 bundle/share 的图标和 desktop 条目安装到对应 XDG 目录，确保可执行文件位于 PATH 或调整 desktop 中的 Exec。

从仓库根目录运行 `python3 tool/generate_app_icons.py` 重建；需要 Pillow。SVG 和 PNG 均由同一组路径与调色板确定性导出，无 AI 栅格生成依赖。内置 imagegen 当前不可用，未调用收费 API。未更新历史构建产物；各平台下次构建生效。保留 imports 中的历史迁入工程原状。
