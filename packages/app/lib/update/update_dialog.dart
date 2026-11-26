import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hongguo_tv/hongguo_tv.dart'
    show TvEnvironment, TvFocusable, isRemoteBack;
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
    // The phone prompt stays a Material AlertDialog. On a television the same
    // controller, keys and sentences are laid out as one focus ring so a remote
    // can reach every action without a pointer.
    if (TvEnvironment.of(context)) return _tvDialog(context);
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
                // The owed and ready branches have to be readable too: on Android
                // the handoff says 「去系统设置开权限」 while `downloading` is already
                // false, and a background transfer reports 已下载完成 with no bar in
                // flight -- a prompt that swallows either sentence is what the
                // viewer is left staring at.
                if (controller.message != null && controller.showsMessage) {
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
        // The trip to 「安装未知应用」 sends the viewer out of this app, and coming
        // back is not something the app can force: the entry point has to stay
        // reachable from the prompt until the permission is actually on.
        if (controller.installOwed)
          TextButton(
            key: const Key('去系统设置'),
            onPressed: controller.openInstallSettings,
            child: const Text('去系统设置'),
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
                      // shown inside it, and closing would hide it. An Android
                      // handoff that could only write the APK down as owed does
                      // the same -- the install has not happened, so there is
                      // nothing for this prompt to have finished saying. A
                      // backgrounded download leaves it up too, so the bar and
                      // the 已下载完成 sentence are both on screen when they arrive.
                      final plan = await controller.install();
                      if (plan == null || !context.mounted) return;
                      if (!plan.owesInstall) Navigator.pop(context);
                    },
              child: Text(
                controller.installReady
                    ? '立即安装'
                    : controller.downloading
                    ? '正在下载…'
                    : controller.transferring
                    ? '正在后台下载…'
                    : '立即更新',
              ),
            ),
          ),
      ],
    );
  }

  /// The remote surface. It says the same things and calls the same controller
  /// methods as the AlertDialog above; only the input contract differs. A
  /// `Dialog` (not `AlertDialog`) keeps the notes scrollable at ten feet, and
  /// every button is a [TvFocusable] with a large label, so D-pad traversal and
  /// 确认 reach them through the app-wide `TvNavigation` policy.
  Widget _tvDialog(BuildContext context) {
    final canInstall = controller.canInstall;
    final installer = currentUpdateTarget().installer(release);
    return Focus(
      // Back/Escape belongs to this route. Handling it here rather than leaving
      // it to the root dispatcher means a TV prompt can never leave a stuck
      // route behind when it is shown from a surface without that dispatcher.
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (_, event) {
        if (isRemoteBack(event.logicalKey)) {
          if (event is KeyDownEvent) Navigator.of(context).maybePop();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Dialog(
        child: SizedBox(
          width: 960,
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              key: const Key('更新说明'),
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '发现新版本 ${release.tag}',
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '当前版本 v${AppRelease.version}，最新版本 v${release.version.versionText} · 发布于 $_published',
                  style: const TextStyle(fontSize: 20),
                ),
                if (installer != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    '本机安装包约 ${(installer.bytes / 1024 / 1024).toStringAsFixed(1)} MB',
                    style: const TextStyle(fontSize: 17),
                  ),
                ],
                const SizedBox(height: 16),
                SizedBox(
                  height: 300,
                  child: Scrollbar(
                    controller: _notes,
                    child: SingleChildScrollView(
                      controller: _notes,
                      child: SelectableText(
                        release.notes,
                        style: const TextStyle(fontSize: 18),
                      ),
                    ),
                  ),
                ),
                if (!canInstall && release.htmlUrl.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  const Text(
                    '这个系统不允许应用自行安装，请到发布页下载：',
                    style: TextStyle(fontSize: 18),
                  ),
                  SelectableText(
                    release.htmlUrl,
                    style: const TextStyle(fontSize: 18),
                  ),
                ],
                const SizedBox(height: 8),
                ListenableBuilder(
                  listenable: controller,
                  builder: (context, _) {
                    final error = controller.error;
                    final progress = controller.progress;
                    if (error != null) {
                      return Text(
                        error,
                        style: TextStyle(fontSize: 18, color: Colors.red.shade700),
                      );
                    }
                    if (progress != null) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          LinearProgressIndicator(value: progress),
                          const SizedBox(height: 4),
                          Text(
                            '正在下载 ${(progress * 100).toStringAsFixed(0)}%',
                            style: const TextStyle(fontSize: 18),
                          ),
                        ],
                      );
                    }
                    if (controller.message != null && controller.showsMessage) {
                      return Text(
                        controller.message!,
                        style: const TextStyle(fontSize: 18),
                      );
                    }
                    return const SizedBox.shrink();
                  },
                ),
                const SizedBox(height: 20),
                FocusTraversalGroup(
                  policy: ReadingOrderTraversalPolicy(),
                  child: Wrap(
                    spacing: 18,
                    runSpacing: 12,
                    children: [
                      _tvAction(
                        key: const Key('以后再说'),
                        label: '以后再说',
                        // With no installer there is no primary action, so the
                        // ring has to start somewhere reachable.
                        autofocus: !canInstall,
                        onActivate: () {
                          controller.dismissOffer();
                          Navigator.pop(context);
                        },
                      ),
                      _tvAction(
                        key: const Key('忽略本次更新'),
                        label: '忽略本次更新',
                        onActivate: () async {
                          await controller.ignoreOffer();
                          if (context.mounted) Navigator.pop(context);
                        },
                      ),
                      // Leave the permission entry reachable until the switch
                      // is really on, exactly like the phone prompt does.
                      if (controller.installOwed)
                        _tvAction(
                          key: const Key('去系统设置'),
                          label: '去系统设置',
                          onActivate: controller.openInstallSettings,
                        ),
                      if (canInstall)
                        ListenableBuilder(
                          listenable: controller,
                          builder: (context, _) => _tvAction(
                            key: const Key('立即更新'),
                            label: controller.installReady
                                ? '立即安装'
                                : controller.downloading
                                ? '正在下载…'
                                : controller.transferring
                                ? '正在后台下载…'
                                : '立即更新',
                            autofocus: true,
                            onActivate: controller.busy
                                ? null
                                : () async {
                                    final plan = await controller.install();
                                    if (plan == null || !context.mounted) {
                                      return;
                                    }
                                    if (!plan.owesInstall) Navigator.pop(context);
                                  },
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _tvAction({
    required Key key,
    required String label,
    required VoidCallback? onActivate,
    bool autofocus = false,
  }) => TvFocusable(
    key: key,
    label: label,
    autofocus: autofocus,
    onActivate: onActivate,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      child: Text(label, style: const TextStyle(fontSize: 24)),
    ),
  );
}
