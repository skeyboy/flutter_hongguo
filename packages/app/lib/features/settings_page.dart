import '../navigation/app_navigation.dart';

import 'package:hongguo_tv/hongguo_tv.dart';
import 'package:flutter/material.dart';
import 'package:hongguo_core/hongguo_core.dart';

import '../platform/runtime.dart';
import '../platform/background/host_policy.dart';
import '../playback/capability_preferences.dart';
import '../update/app_release.dart';
import '../update/install_strategy.dart';
import '../update/update_host.dart';
import '../widgets/tv_confirm.dart';
import 'local_cache_page.dart';

class SettingsPage extends StatefulWidget {
  final AppRuntime runtime;
  final bool embedded;
  final VoidCallback? onSaved;
  final bool closeOnSave;
  const SettingsPage({
    super.key,
    required this.runtime,
    this.embedded = false,
    this.onSaved,
    this.closeOnSave = true,
  });
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late AppSettings draft;
  late final TextEditingController apiHost,
      videoHost,
      catalogVersion,
      catalogCode,
      videoVersion,
      videoCode,
      userAgent,
      cookie,
      token;
  bool busy = false, credentialsEdited = false, changed = false;

  /// The advanced panel is an `ExpansionTile` on touch. Its header is a Material
  /// ink target the ring would have to share with the whole subtree, so TV opens
  /// it with its own target instead.
  bool _advancedOpen = false;
  int? bytes;
  String? error, status;
  final anchors = <String, GlobalKey>{
    for (final name in [
      '后台与悬浮播放',
      '播放与提前缓存',
      '缓存管理',
      if (updateSupported) '更新',
      '签名与设备',
      '会话凭据',
      '高级接口与签名参数',
    ])
      name: GlobalKey(),
  };
  ConfigurableRuntime? get configurable => widget.runtime is ConfigurableRuntime
      ? widget.runtime as ConfigurableRuntime
      : null;
  @override
  void initState() {
    super.initState();
    draft = settingsFor(widget.runtime);
    if (tvBuild) {
      draft = draft.copyWith(
        backgroundPlayback: false,
        backgroundDownloads: false,
        floatingPlayback: false,
        concurrentPreparations: 1,
      );
    }
    apiHost = TextEditingController(text: draft.apiHost);
    videoHost = TextEditingController(text: draft.videoHost);
    catalogVersion = TextEditingController(text: draft.catalogVersion);
    catalogCode = TextEditingController(text: draft.catalogVersionCode);
    videoVersion = TextEditingController(text: draft.videoVersion);
    videoCode = TextEditingController(text: draft.videoVersionCode);
    userAgent = TextEditingController(text: draft.videoUserAgent);
    cookie = TextEditingController(
      text: configurable?.credentials.cookie ?? '',
    );
    token = TextEditingController(
      text: configurable?.credentials.ttToken ?? '',
    );
    _usage();
  }

  Future<void> _usage() async {
    try {
      final value = await widget.runtime.cacheBytes();
      if (mounted) setState(() => bytes = value);
    } catch (_) {
      /* usage is optional */
    }
  }

  @override
  void dispose() {
    for (final c in [
      apiHost,
      videoHost,
      catalogVersion,
      catalogCode,
      videoVersion,
      videoCode,
      userAgent,
      cookie,
      token,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _action(Future<void> Function() action, String success) async {
    setState(() {
      busy = true;
      error = null;
      status = null;
    });
    try {
      await action();
      if (mounted) {
        setState(() {
          status = success;
          changed = true;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is FormatException
              ? e.message
              : '操作未完成，请检查系统安全存储或磁盘空间后重试。',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _save() async {
    final runtime = configurable;
    if (runtime == null) return;
    await _action(() async {
      final next = draft.copyWith(
        backgroundPlayback: mobileHost
            ? runtime.settings.backgroundPlayback
            : draft.backgroundPlayback,
        backgroundDownloads: mobileHost
            ? runtime.settings.backgroundDownloads
            : draft.backgroundDownloads,
        floatingPlayback: mobileHost
            ? runtime.settings.floatingPlayback
            : draft.floatingPlayback,
        backgroundPlaybackPrompted:
            runtime.settings.backgroundPlaybackPrompted ||
            draft.backgroundPlaybackPrompted,
        floatingPlaybackPrompted:
            runtime.settings.floatingPlaybackPrompted ||
            draft.floatingPlaybackPrompted,
        apiHost: apiHost.text.trim(),
        videoHost: videoHost.text.trim(),
        catalogVersion: catalogVersion.text.trim(),
        catalogVersionCode: catalogCode.text.trim(),
        videoVersion: videoVersion.text.trim(),
        videoVersionCode: videoCode.text.trim(),
        videoUserAgent: userAgent.text.trim(),
      );
      next.validate();
      await runtime.saveSettings(
        next,
        credentials: credentialsEdited
            ? SessionCredentials(
                cookie: cookie.text.trim(),
                ttToken: token.text.trim(),
              )
            : null,
      );
      widget.onSaved?.call();
      if (mounted && !widget.embedded && widget.closeOnSave) {
        Navigator.pop(context, true);
      }
    }, '设置已保存');
  }

  Future<void> _capability(PlaybackCapability capability, bool value) async {
    final runtime = configurable;
    if (runtime == null || busy) return;
    if (!mobileHost) {
      setState(() => draft = capability.apply(draft, value));
      return;
    }
    setState(() => busy = true);
    final accepted = await confirmPlaybackCapability(
      context,
      capability,
      value,
    );
    if (!mounted) return;
    setState(() => busy = false);
    if (!accepted) return;
    await _action(() async {
      // Commit only this capability; preserve unrelated unsaved form edits.
      await runtime.saveSettings(capability.apply(runtime.settings, value));
      if (mounted) setState(() => draft = capability.apply(draft, value));
      widget.onSaved?.call();
    }, '${capability.title}已${value ? '开启' : '关闭'}并生效');
  }

  Future<void> _theme(String value) async {
    final runtime = configurable;
    if (runtime == null) return;
    final previous = draft.themeMode;
    setState(() => draft = draft.copyWith(themeMode: value));
    await _action(() async {
      try {
        // Save only theme here; other draft fields still require explicit save.
        await runtime.saveSettings(runtime.settings.copyWith(themeMode: value));
        widget.onSaved?.call();
      } catch (_) {
        if (mounted) {
          setState(() => draft = draft.copyWith(themeMode: previous));
        }
        rethrow;
      }
    }, '主题已应用并保存');
  }

  Future<void> _updateChecks(bool value) async {
    final runtime = configurable;
    if (runtime == null) return;
    final previous = draft.updateChecksEnabled;
    setState(() => draft = draft.copyWith(updateChecksEnabled: value));
    await _action(() async {
      try {
        // Saving the switch must not carry the rest of the unsaved form.
        await runtime.saveSettings(
          runtime.settings.copyWith(updateChecksEnabled: value),
        );
        widget.onSaved?.call();
      } catch (_) {
        if (mounted) {
          setState(() => draft = draft.copyWith(updateChecksEnabled: previous));
        }
        rethrow;
      }
    }, value ? '自动检查更新已开启' : '自动检查更新已关闭');
  }

  void _protocolDefaults() {
    const value = AppSettings();
    setState(() {
      draft = draft.copyWith(
        signLists: value.signLists,
        timeoutSeconds: value.timeoutSeconds,
      );
      apiHost.text = value.apiHost;
      videoHost.text = value.videoHost;
      catalogVersion.text = value.catalogVersion;
      catalogCode.text = value.catalogVersionCode;
      videoVersion.text = value.videoVersion;
      videoCode.text = value.videoVersionCode;
      userAgent.text = value.videoUserAgent;
    });
  }

  /// The update rows talk to the app-wide controller, not to the form draft:
  /// a check belongs to the session and has to stay readable after 保存, and its
  /// own two settings persist the moment the user changes them.
  Widget _updateSection() {
    final runtime = configurable;
    final controller = sharedUpdateController(widget.runtime);
    return _section('更新', [
      Text(
        '当前版本 v${AppRelease.version}（构建 ${AppRelease.build}），新版本来自 GitHub Releases。',
      ),
      const SizedBox(height: 6),
      Text(
        updateHandoffDescription,
        style: TextStyle(
          fontSize: 12,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      if (tv)
        _tvRow(
          '启动或回到前台时自动检查',
          subtitle: '一天最多询问一次；没有新版本时不打扰。',
          state: draft.updateChecksEnabled ? '已开启' : '已关闭',
          selected: draft.updateChecksEnabled,
          key: const Key('自动检查更新'),
          onActivate: busy
              ? null
              : () => _updateChecks(!draft.updateChecksEnabled),
        )
      else
        SwitchListTile.adaptive(
          key: const Key('自动检查更新'),
          contentPadding: EdgeInsets.zero,
          title: const Text('启动或回到前台时自动检查'),
          subtitle: const Text('一天最多询问一次；没有新版本时不打扰。'),
          value: draft.updateChecksEnabled,
          onChanged: busy ? null : _updateChecks,
        ),
      ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final release = controller.offer;
          final ignored = runtime?.settings.ignoredUpdateVersion ?? '';
          final lastCheck = runtime?.settings.lastUpdateCheckAt ?? 0;
          final error = controller.error;
          final progress = controller.progress;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _timestamp(lastCheck),
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              if (error != null)
                Text(
                  error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                )
              else if (controller.message != null)
                Text(controller.message!),
              if (controller.downloading)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 8),
                    LinearProgressIndicator(value: progress),
                    Text(
                      progress == null
                          ? '正在下载…'
                          : '正在下载 ${(progress * 100).toStringAsFixed(0)}%',
                    ),
                  ],
                ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 8,
                children: [
                  if (tv) ...[
                    _tvButton(
                      controller.checking ? '正在检查…' : '检查更新',
                      key: const Key('检查更新'),
                      icon: Icons.system_update_alt_rounded,
                      onActivate: controller.busy ? null : controller.checkNow,
                    ),
                    if (release != null && controller.canInstall)
                      _tvButton(
                        controller.downloading
                            ? '正在下载…'
                            : '立即更新 ${release.tag}',
                        key: const Key('立即下载并安装'),
                        icon: Icons.download_rounded,
                        onActivate: controller.busy ? null : controller.install,
                      ),
                    if (ignored.isNotEmpty)
                      _tvButton(
                        '重新提醒 $ignored',
                        key: const Key('重新提醒被忽略的更新'),
                        onActivate: controller.busy
                            ? null
                            : controller.remindAgain,
                      ),
                  ] else ...[
                    OutlinedButton.icon(
                      key: const Key('检查更新'),
                      onPressed: controller.busy ? null : controller.checkNow,
                      icon: const Icon(Icons.system_update_alt_rounded),
                      label: Text(controller.checking ? '正在检查…' : '检查更新'),
                    ),
                    if (release != null && controller.canInstall)
                      FilledButton.icon(
                        key: const Key('立即下载并安装'),
                        onPressed: controller.busy ? null : controller.install,
                        icon: const Icon(Icons.download_rounded),
                        label: Text(
                          controller.downloading
                              ? '正在下载…'
                              : '立即更新 ${release.tag}',
                        ),
                      ),
                    if (ignored.isNotEmpty)
                      TextButton(
                        key: const Key('重新提醒被忽略的更新'),
                        onPressed: controller.busy
                            ? null
                            : controller.remindAgain,
                        child: Text('重新提醒 $ignored'),
                      ),
                  ],
                ],
              ),
              // A platform that cannot install what it downloaded still has to
              // say where the file lives.
              if (release != null &&
                  !controller.canInstall &&
                  release.htmlUrl.isNotEmpty)
                SelectableText(release.htmlUrl),
            ],
          );
        },
      ),
    ]);
  }

  static String _timestamp(int millisecondsSinceEpoch) {
    if (millisecondsSinceEpoch == 0) return '还没有检查过更新。';
    final at = DateTime.fromMillisecondsSinceEpoch(millisecondsSinceEpoch);
    String two(int value) => value.toString().padLeft(2, '0');
    return '上次检查 ${at.year}-${two(at.month)}-${two(at.day)} ${two(at.hour)}:${two(at.minute)}';
  }

  Widget _section(String title, List<Widget> children) => Card(
    key: anchors[title],
    margin: const EdgeInsets.only(bottom: 20),
    elevation: 0,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(18),
      side: BorderSide(color: Theme.of(context).dividerColor),
    ),
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: tv ? 26 : 20,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    ),
  );

  /// True when the app root decided this is the TV layout. `TvEnvironment.of`
  /// falls back to the flavor's `tvBuild`, so the page needs no flag from
  /// whoever hosts it.
  bool get tv => TvEnvironment.of(context);

  /// The settings page has ~30 controls. On a TV each one is a single row the
  /// ring can hold, with its current state spelled out in the label: a switch
  /// thumb is unreadable at ten feet, and the viewer has to be able to tell what
  /// the confirm key will do before pressing it.
  Widget _tvRow(
    String title, {
    String? subtitle,
    String? state,
    bool selected = false,
    VoidCallback? onActivate,
    Key? key,
  }) => TvFocusable(
    key: key,
    label: state == null ? title : '$title $state',
    selected: selected,
    onActivate: onActivate,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 22)),
                if (subtitle != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: const TextStyle(fontSize: 15, color: Colors.grey),
                  ),
                ],
              ],
            ),
          ),
          if (state != null) Text(state, style: const TextStyle(fontSize: 20)),
        ],
      ),
    ),
  );

  Widget _tvButton(
    String label, {
    required VoidCallback? onActivate,
    IconData? icon,
    Key? key,
  }) => TvFocusable(
    key: key,
    label: label,
    onActivate: onActivate,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 22), const SizedBox(width: 8)],
          Text(label, style: const TextStyle(fontSize: 20)),
        ],
      ),
    ),
  );

  /// A spinner instead of a menu route: inside a dropdown's own route the ring
  /// has to be handed over and back again, and confirm-then-pick is two keys for
  /// what one key can do.
  void _tvCycle(
    List<String> values,
    String current,
    void Function(String) update,
  ) {
    final at = values.indexOf(current);
    update(values[(at + 1) % values.length]);
  }

  void _scrollToAnchor(String name) {
    final target = anchors[name]?.currentContext;
    if (target == null) return;
    Scrollable.ensureVisible(
      target,
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 180),
      alignment: 0.03,
    );
  }

  /// The接口参数 block, shared by the touch `ExpansionTile` and the TV section so
  /// the two layouts cannot drift on the riskiest settings.
  List<Widget> _advancedFields() => [
    _field('内容接口域名', apiHost),
    _field('视频模型域名', videoHost),
    _field('内容接口版本号', catalogVersion),
    _field('内容接口版本代码', catalogCode),
    _field('视频版本号', videoVersion),
    _field('视频版本代码', videoCode),
    _field('视频 User-Agent', userAgent),
    _switch(
      '列表接口也签名',
      '默认开启；旧配置遇到空响应时会自动补签重试。',
      draft.signLists,
      (v) => draft = draft.copyWith(signLists: v),
    ),
    _number(
      '请求超时',
      draft.timeoutSeconds,
      [10, 15, 20, 30, 60, 120],
      (v) => draft = draft.copyWith(timeoutSeconds: v),
      suffix: ' 秒',
    ),
    Text(
      '版本号、版本代码与 User-Agent 需要匹配。取址第一跳固定使用播放器自身的 User-Agent，这一项只作用于片源回退的第二跳。内容加载采用独立短超时，总等待不超过 12 秒；上方超时设置不会延长内容加载。改完后保存，后续请求使用新参数。',
      style: TextStyle(
        fontSize: tv ? 16 : 12,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
    if (tv)
      _tvButton('恢复默认接口与签名参数', onActivate: busy ? null : _protocolDefaults)
    else
      TextButton(
        onPressed: busy ? null : _protocolDefaults,
        child: Text('恢复默认接口与签名参数'),
      ),
  ];

  Widget _switch(
    String title,
    String subtitle,
    bool value,
    void Function(bool) update,
  ) {
    if (tv) {
      return _tvRow(
        title,
        subtitle: subtitle,
        state: value ? '已开启' : '已关闭',
        selected: value,
        onActivate: busy ? null : () => setState(() => update(!value)),
      );
    }
    return SwitchListTile.adaptive(
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      subtitle: Text(subtitle),
      value: value,
      onChanged: busy ? null : (v) => setState(() => update(v)),
    );
  }

  Widget _capabilitySwitch(PlaybackCapability capability, String subtitle) {
    if (tv) {
      final value = capability.enabled(draft);
      return _tvRow(
        capability.title,
        subtitle: subtitle,
        state: value ? '已开启' : '已关闭',
        selected: value,
        onActivate: busy
            ? null
            : () => setState(() => _capability(capability, !value)),
      );
    }
    return SwitchListTile.adaptive(
      contentPadding: EdgeInsets.zero,
      title: Text(capability.title),
      subtitle: Text(subtitle),
      value: capability.enabled(draft),
      onChanged: busy ? null : (value) => _capability(capability, value),
    );
  }

  Widget _number(
    String label,
    int value,
    List<int> choices,
    void Function(int) update, {
    String suffix = '',
    Key? key,
    bool enabled = true,
  }) {
    final options = {...choices, value}.toList()..sort();
    if (tv) {
      return _tvRow(
        label,
        state: '$value$suffix',
        key: key,
        onActivate: enabled
            ? () => setState(
                () => update(
                  options[(options.indexOf(value) + 1) % options.length],
                ),
              )
            : null,
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          DropdownButton<int>(
            key: key,
            value: value,
            items: [
              for (final item in options)
                DropdownMenuItem(value: item, child: Text('$item$suffix')),
            ],
            onChanged: enabled ? (v) => setState(() => update(v!)) : null,
          ),
        ],
      ),
    );
  }

  /// One labelled choice list, a menu on touch and a spinner on TV, so the four
  /// string settings cannot drift apart between the two layouts.
  Widget _choice(
    String label,
    String value,
    Map<String, String> options,
    void Function(String) update, {
    Key? key,
    bool enabled = true,
  }) {
    if (tv) {
      return _tvRow(
        label,
        state: options[value] ?? value,
        key: key,
        onActivate: enabled
            ? () => _tvCycle(options.keys.toList(), value, update)
            : null,
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          DropdownButton<String>(
            key: key,
            value: value,
            items: [
              for (final entry in options.entries)
                DropdownMenuItem(value: entry.key, child: Text(entry.value)),
            ],
            onChanged: enabled ? (v) => update(v!) : null,
          ),
        ],
      ),
    );
  }

  Widget _field(
    String label,
    TextEditingController controller, {
    bool secret = false,
    String? hint,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: TextField(
      controller: controller,
      enabled: !busy,
      obscureText: secret,
      enableSuggestions: !secret,
      autocorrect: false,
      onChanged: secret ? (_) => credentialsEdited = true : null,
      style: tv ? const TextStyle(fontSize: 22) : null,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        labelStyle: tv ? const TextStyle(fontSize: 20) : null,
      ),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final runtime = configurable;
    Widget layout(Widget content) => LayoutBuilder(
      builder: (context, size) {
        if (size.maxWidth < 850) return content;
        return Row(
          children: [
            // The longest anchor is 高级接口与签名参数; the phone rail clips it
            // at 13px, but a 20px remote target needs room for the whole word.
            SizedBox(
              width: tv ? 300 : 170,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 20),
                  for (final entry in anchors.entries)
                    if (tv)
                      _tvButton(
                        entry.key,
                        onActivate: () => _scrollToAnchor(entry.key),
                      )
                    else
                      ListTile(
                        title: Text(
                          entry.key,
                          style: const TextStyle(fontSize: 13),
                        ),
                        onTap: () => _scrollToAnchor(entry.key),
                      ),
                ],
              ),
            ),
            const VerticalDivider(width: 1),
            Expanded(child: content),
          ],
        );
      },
    );
    return PopScope<bool>(
      canPop: widget.embedded || !changed,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) Navigator.pop(context, changed);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text('设置'),
          automaticallyImplyLeading: !widget.embedded,
          leading: widget.embedded
              ? null
              : BackButton(onPressed: () => Navigator.pop(context, changed)),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: tv
                  ? _tvButton(
                      busy ? '正在保存…' : '保存',
                      key: const Key('设置保存'),
                      onActivate: busy || runtime == null ? null : _save,
                    )
                  : TextButton(
                      onPressed: busy || runtime == null ? null : _save,
                      child: Text(busy ? '正在保存…' : '保存'),
                    ),
            ),
          ],
        ),
        body: layout(
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: SingleChildScrollView(
                padding: EdgeInsets.all(tv ? 32 : 20),
                // Most of this page's copy is plain `Text` at the default 14px,
                // which is unreadable from a sofa; the inherited style raises it
                // once instead of at each of the ~20 call sites.
                child: DefaultTextStyle.merge(
                  style: TextStyle(
                    fontSize: tv ? 19 : null,
                    color: Theme.of(context).textTheme.bodyMedium?.color,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (runtime == null)
                        const Padding(
                          padding: EdgeInsets.only(bottom: 16),
                          child: Text('当前运行方式不支持保存本机配置。'),
                        ),
                      if (runtime?.settingsWarning != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: Text(
                            runtime!.settingsWarning!,
                            style: const TextStyle(color: Colors.orange),
                          ),
                        ),
                      if (error != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: Text(
                            error!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                      if (status != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: Text(status!),
                        ),
                      if (!tvBuild)
                        _section('后台与悬浮播放', [
                          if (desktopHost)
                            const ListTile(
                              leading: Icon(Icons.desktop_windows_outlined),
                              title: Text('桌面持续播放'),
                              subtitle: Text('遮挡、最小化或切换应用继续播放；手动暂停和退出播放页仍会停止。'),
                            ),
                          if (mobileHost)
                            _capabilitySwitch(
                              PlaybackCapability.backgroundPlayback,
                              mobileHost
                                  ? '切到其他应用或锁屏后继续声音播放，使用系统媒体控制与播放提醒。'
                                  : '桌面遮挡或最小化继续播放，退出播放页停止。',
                            ),
                          _capabilitySwitch(
                            PlaybackCapability.backgroundDownloads,
                            backgroundDownloadDescription,
                          ),
                          if (mobileHost)
                            _switch(
                              '后台下载仅 Wi-Fi',
                              '只作用于开启后台下载后的新系统任务；关闭后可能使用移动数据。',
                              draft.backgroundWifiOnly,
                              (v) =>
                                  draft = draft.copyWith(backgroundWifiOnly: v),
                            ),
                          _capabilitySwitch(
                            PlaybackCapability.floatingPlayback,
                            floatingDescription,
                          ),
                          Text(
                            mobileHost
                                ? '以上播放能力确认后立即生效；其他配置需保存。悬浮播放由播放器按钮手动进入。'
                                : '保存后生效。悬浮播放由播放器按钮手动进入。',
                          ),
                        ]),
                      if (tvBuild)
                        const Text(
                          'TV 模式：离开应用暂停播放，不启用画中画；最多提前缓存 1 集，同时准备 1 个任务。',
                        ),
                      _section('播放与提前缓存', [
                        _switch(
                          '提前缓存后续剧集',
                          '播放当前集时，自动准备后续剧集的完整文件。',
                          draft.prefetchEnabled,
                          (v) => draft = draft.copyWith(prefetchEnabled: v),
                        ),
                        if (!tvBuild)
                          _number(
                            '提前缓存集数',
                            draft.prefetchEpisodes,
                            tvBuild ? [1] : [3, 4, 5],
                            (v) => draft = draft.copyWith(prefetchEpisodes: v),
                            suffix: ' 集',
                          ),
                        if (!tvBuild)
                          _number(
                            '同时准备数量',
                            draft.concurrentPreparations,
                            tvBuild ? [1] : [1, 2, 3],
                            (v) => draft = draft.copyWith(
                              concurrentPreparations: v,
                            ),
                          ),
                        Text(
                          '当前播放优先于排队的预缓存任务。网络速度或空间不足时，后续剧集可能仍需等待。',
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                        ),
                        _number(
                          '同时下载数量',
                          draft.downloadConcurrent,
                          [1, 2, 3, 4, 5],
                          (v) => draft = draft.copyWith(downloadConcurrent: v),
                          suffix: ' 个',
                          key: const ValueKey('download-concurrent-setting'),
                        ),
                        Text(
                          '手动下载按此数量同时进行，不占用播放与提前缓存的准备槽位。',
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 12),
                        _choice(
                          '默认清晰度',
                          draft.defaultQuality,
                          const {
                            'best': '自动',
                            '720p': '720p',
                            '1080p': '1080p',
                          },
                          (v) => setState(
                            () => draft = draft.copyWith(defaultQuality: v),
                          ),
                          enabled: !busy,
                        ),
                        Text(
                          '默认清晰度在下次打开播放器时生效。',
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                        ),
                        _switch(
                          '自动连播',
                          '当前集结束后继续播放下一集。',
                          draft.autoNext,
                          (v) => draft = draft.copyWith(autoNext: v),
                        ),
                        _choice(
                          '界面主题',
                          draft.themeMode,
                          const {'system': '跟随系统', 'light': '浅色', 'dark': '深色'},
                          _theme,
                          enabled: !busy && runtime != null,
                        ),
                        if (!tvBuild)
                          _switch(
                            '自动加载下一页',
                            '列表接近底部时自动加载更多内容。',
                            draft.autoLoadMore,
                            (v) => draft = draft.copyWith(autoLoadMore: v),
                          ),
                      ]),
                      _section('内容列表', [
                        _choice(
                          '全局排序',
                          draft.catalogSort,
                          const {
                            'online_time': '最新上架',
                            'hot_score': '热度优先',
                            'hot_collect': '收藏最多',
                          },
                          (v) => setState(
                            () => draft = draft.copyWith(catalogSort: v),
                          ),
                          key: const ValueKey('catalog-sort-setting'),
                          enabled: !busy && runtime != null,
                        ),
                        const Text('短剧、漫剧、AI 短剧使用同一排序；保存后生效。搜索与榜单保留各自接口排序。'),
                        if (tvBuild)
                          _number(
                            'TV 分类每页条数',
                            draft.tvPageSize,
                            [30, 50],
                            (value) =>
                                draft = draft.copyWith(tvPageSize: value),
                            suffix: ' 条',
                            key: const ValueKey('tv-page-size-setting'),
                          ),
                        if (tvBuild)
                          const Text(
                            'TV 接近列表末尾自动加载下一页。每次请求 30 或 50 条，实际返回数量由上游决定。',
                          ),
                      ]),
                      _section('缓存管理', [
                        if (tv)
                          _tvRow(
                            '本地缓存剧集',
                            subtitle: '查看、离线播放与删除已完成的视频',
                            state: '打开',
                            onActivate: busy
                                ? null
                                : () async {
                                    await pushAppPage<void>(
                                      context,
                                      AppScreen.cache,
                                      (_) => LocalCachePage(
                                        runtime: widget.runtime,
                                      ),
                                    );
                                    await _usage();
                                  },
                          )
                        else
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.video_library_outlined),
                            title: const Text('本地缓存剧集'),
                            subtitle: const Text('查看、离线播放与删除已完成的视频'),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () async {
                              await pushAppPage<void>(
                                context,
                                AppScreen.cache,
                                (_) => LocalCachePage(runtime: widget.runtime),
                              );
                              await _usage();
                            },
                          ),
                        Text(
                          bytes == null
                              ? '正在统计…'
                              : '已使用 ${(bytes! / 1024 / 1024).toStringAsFixed(1)} MB',
                          style: const TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        _number(
                          '自动缓存剧集数量',
                          draft.maxCacheFiles,
                          [10, 20, 30, 50, 100, 200],
                          (v) => draft = draft.copyWith(maxCacheFiles: v),
                          suffix: ' 集',
                        ),
                        _number(
                          '自动缓存空间上限',
                          draft.maxCacheMb,
                          [128, 256, 512, 1024, 2048, 4096],
                          (v) => draft = draft.copyWith(maxCacheMb: v),
                          suffix: ' MB',
                        ),
                        Text(
                          '这两项只限制自动缓存（提前缓存与播放临时文件）；手动下载不受额度限制，请在下载管理中删除。正在播放和预缓存中的文件不会被自动清理。',
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 14),
                        if (tv)
                          _tvButton(
                            '清理未在使用的缓存',
                            icon: Icons.cleaning_services_outlined,
                            onActivate: busy
                                ? null
                                : () => _action(() async {
                                    await widget.runtime.clearCache();
                                    await _usage();
                                  }, '未在使用的缓存已清理'),
                          )
                        else
                          OutlinedButton.icon(
                            onPressed: busy
                                ? null
                                : () => _action(() async {
                                    await widget.runtime.clearCache();
                                    await _usage();
                                  }, '未在使用的缓存已清理'),
                            icon: const Icon(Icons.cleaning_services_outlined),
                            label: Text('清理未在使用的缓存'),
                          ),
                      ]),
                      if (updateSupported) _updateSection(),
                      _section('签名与设备', [
                        Text('签名由本地 Dart 核心生成。视频内容密钥按每集自动解析，无需手动填写。'),
                        const SizedBox(height: 10),
                        Text(
                          '刷新签名状态会重新生成本进程的随机签名上下文，不会刷新账号登录会话。算法更新随 App 版本发布。',
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 14),
                        if (tv) ...[
                          _tvButton(
                            '刷新签名状态',
                            icon: Icons.refresh_rounded,
                            onActivate: busy || runtime == null
                                ? null
                                : () => _action(
                                    runtime.refreshSigning,
                                    '本地签名状态已刷新',
                                  ),
                          ),
                          _tvButton(
                            '检查本地算法',
                            icon: Icons.verified_outlined,
                            onActivate: busy
                                ? null
                                : () => _action(() async {
                                    if (!runCoreDiagnostics().values.every(
                                      (v) => v,
                                    )) {
                                      throw const FormatException('本地算法校验未通过');
                                    }
                                  }, '本地签名与密钥解包检查通过'),
                          ),
                        ] else ...[
                          OutlinedButton.icon(
                            onPressed: busy || runtime == null
                                ? null
                                : () => _action(
                                    runtime.refreshSigning,
                                    '本地签名状态已刷新',
                                  ),
                            icon: const Icon(Icons.refresh_rounded),
                            label: Text('刷新签名状态'),
                          ),
                          OutlinedButton.icon(
                            onPressed: busy
                                ? null
                                : () => _action(() async {
                                    if (!runCoreDiagnostics().values.every(
                                      (v) => v,
                                    )) {
                                      throw const FormatException('本地算法校验未通过');
                                    }
                                  }, '本地签名与密钥解包检查通过'),
                            icon: const Icon(Icons.verified_outlined),
                            label: Text('检查本地算法'),
                          ),
                        ],
                        const SizedBox(height: 12),
                        Text(
                          '当前设备编号',
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                        ),
                        SelectableText(runtime?.deviceId ?? '当前运行方式不可用'),
                        if (tv)
                          _tvButton(
                            '重建设备身份',
                            onActivate: busy || runtime == null
                                ? null
                                : () async {
                                    final confirmed = await showTvConfirm(
                                      context,
                                      title: '重建设备身份？',
                                      body: '将生成新的设备编号，已有登录会话可能需要重新配置。',
                                      confirmLabel: '重建',
                                    );
                                    if (confirmed == true && mounted) {
                                      await _action(
                                        runtime.rotateDeviceIdentity,
                                        '设备身份已重建',
                                      );
                                    }
                                  },
                          )
                        else
                          TextButton(
                            onPressed: busy || runtime == null
                                ? null
                                : () async {
                                    final confirmed = await showDialog<bool>(
                                      context: context,
                                      builder: (context) => AlertDialog(
                                        title: Text('重建设备身份？'),
                                        content: Text(
                                          '将生成新的设备编号，已有登录会话可能需要重新配置。',
                                        ),
                                        actions: [
                                          TextButton(
                                            onPressed: () =>
                                                Navigator.pop(context, false),
                                            child: Text('取消'),
                                          ),
                                          FilledButton(
                                            onPressed: () =>
                                                Navigator.pop(context, true),
                                            child: Text('重建'),
                                          ),
                                        ],
                                      ),
                                    );
                                    if (confirmed == true && mounted) {
                                      await _action(
                                        runtime.rotateDeviceIdentity,
                                        '设备身份已重建',
                                      );
                                    }
                                  },
                            child: Text('重建设备身份'),
                          ),
                      ]),
                      _section('会话凭据', [
                        Text(
                          '有需要时填入有效会话。凭据保存在系统安全存储，不写入普通设置文件；不会转发给 fallback 或视频 CDN。',
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 16),
                        _field('Cookie', cookie, secret: true),
                        _field('x-tt-token', token, secret: true),
                        if (tv)
                          _tvButton(
                            '清空会话字段（保存后生效）',
                            onActivate: busy
                                ? null
                                : () {
                                    setState(() {
                                      cookie.clear();
                                      token.clear();
                                      credentialsEdited = true;
                                    });
                                  },
                          )
                        else
                          TextButton(
                            onPressed: busy
                                ? null
                                : () {
                                    setState(() {
                                      cookie.clear();
                                      token.clear();
                                      credentialsEdited = true;
                                    });
                                  },
                            child: Text('清空会话字段（保存后生效）'),
                          ),
                      ]),
                      if (tv)
                        _section('高级接口与签名参数', [
                          Text('仅在已确认上游参数变化时修改'),
                          const SizedBox(height: 8),
                          _tvRow(
                            _advancedOpen ? '收起' : '展开',
                            state: _advancedOpen ? '已展开' : '已收起',
                            onActivate: () =>
                                setState(() => _advancedOpen = !_advancedOpen),
                          ),
                          if (_advancedOpen) ..._advancedFields(),
                        ])
                      else
                        Card(
                          key: anchors['高级接口与签名参数'],
                          elevation: 0,
                          child: ExpansionTile(
                            title: Text('高级接口与签名参数'),
                            subtitle: Text('仅在已确认上游参数变化时修改'),
                            children: [
                              Padding(
                                padding: const EdgeInsets.all(16),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: _advancedFields(),
                                ),
                              ),
                            ],
                          ),
                        ),
                      const SizedBox(height: 24),
                      if (tv)
                        _tvButton(
                          '保存设置',
                          key: const Key('设置保存底部'),
                          icon: Icons.save_outlined,
                          onActivate: busy || runtime == null ? null : _save,
                        )
                      else
                        FilledButton(
                          onPressed: busy || runtime == null ? null : _save,
                          child: Text('保存设置'),
                        ),
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
