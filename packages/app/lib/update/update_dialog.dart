import 'package:flutter/material.dart';
import 'package:hongguo_update/hongguo_update.dart';

import 'app_release.dart';
import 'install_strategy.dart';
import 'update_controller.dart';

/// The prompt, and the only place the release note is ever shown.
///
/// The published note is a rolling feature list -- the real v0.3.13 body runs to
/// 12,357 characters -- so the note always lives inside its own scrolling box
/// and the dialog itself never grows past the screen.
Future<void> showUpdateDialog(
  BuildContext context,
  UpdateController controller,
) async {
  final release = controller.offer;
  if (release == null) return;
  await showDialog<void>(
    context: context,
    builder: (context) =>
        UpdateDialog(controller: controller, release: release),
  );
}

class UpdateDialog extends StatefulWidget {
  final UpdateController controller;
  final ReleaseInfo release;

  const UpdateDialog({
    super.key,
    required this.controller,
    required this.release,
  });

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  static const _notesMaxHeight = 360.0;

  /// The note scrolls on its own controller: a dialog route has no
  /// `PrimaryScrollController`, so a `Scrollbar` left to fall back on one asserts
  /// with no position attached as soon as its fade-out timer runs.
  final ScrollController _notes = ScrollController();

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  UpdateController get controller => widget.controller;
  ReleaseInfo get release => widget.release;

  String get _published {
    final at = release.publishedAt;
    return at == null
        ? '时间未知'
        : '${at.year}-${at.month.toString().padLeft(2, '0')}-${at.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final canInstall = controller.canInstall;
    // The number has to be the file this device would actually fetch. The feed
    // lists fifteen attachments in whatever order the release workflow wrote
    // them, and the first of those is not ours.
    final installer = currentUpdateTarget().installer(release);
    return AlertDialog(
      title: Text('发现新版本 ${release.tag}'),
      content: SizedBox(
        width: 520,
        child: Column(
          key: const Key('更新说明'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '当前版本 v${AppRelease.version}，最新版本 v${release.version.versionText} · 发布于 $_published',
            ),
            if (installer != null)
              Text(
                '本机安装包约 ${(installer.bytes / 1024 / 1024).toStringAsFixed(1)} MB',
                style: const TextStyle(fontSize: 12),
              ),
            const SizedBox(height: 10),
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: _notesMaxHeight),
                child: Scrollbar(
                  controller: _notes,
                  child: SingleChildScrollView(
                    controller: _notes,
                    child: SelectableText(release.notes),
                  ),
                ),
              ),
            ),
            // A platform that cannot install what it downloaded still has to
            // say where the file lives.
            if (!canInstall && release.htmlUrl.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text('这个系统不允许应用自行安装，请到发布页下载：'),
              SelectableText(release.htmlUrl),
            ],
            ListenableBuilder(
              listenable: controller,
              builder: (context, _) {
                final error = controller.error;
                final progress = controller.progress;
                if (error != null) {
                  return Text(
                    error,
                    style: TextStyle(color: Colors.red.shade700),
                  );
                }
                if (progress != null) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      LinearProgressIndicator(value: progress),
                      Text('正在下载 ${(progress * 100).toStringAsFixed(0)}%'),
                    ],
                  );
                }
                if (controller.message != null && controller.downloading) {
                  return Text(controller.message!);
                }
                return const SizedBox.shrink();
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('以后再说'),
          onPressed: () {
            controller.dismissOffer();
            Navigator.pop(context);
          },
          child: const Text('以后再说'),
        ),
        TextButton(
          key: const Key('忽略本次更新'),
          onPressed: () async {
            await controller.ignoreOffer();
            if (context.mounted) Navigator.pop(context);
          },
          child: const Text('忽略本次更新'),
        ),
        if (canInstall)
          ListenableBuilder(
            listenable: controller,
            builder: (context, _) => FilledButton(
              key: const Key('立即更新'),
              onPressed: controller.busy
                  ? null
                  : () async {
                      // A failed transfer leaves the dialog up: the reason is
                      // shown inside it, and closing would hide it.
                      final plan = await controller.install();
                      if (plan != null && context.mounted) {
                        Navigator.pop(context);
                      }
                    },
              child: Text(controller.downloading ? '正在下载…' : '立即更新'),
            ),
          ),
      ],
    );
  }
}
