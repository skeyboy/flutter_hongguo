import '../navigation/app_navigation.dart';

import 'package:hongguo_tv/hongguo_tv.dart';
import 'package:flutter/material.dart';
import 'package:hongguo_core/hongguo_core.dart';

import '../platform/runtime.dart';
import '../platform/background/host_policy.dart';
import '../playback/capability_preferences.dart';
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
  int? bytes;
  String? error, status;
  final anchors = <String, GlobalKey>{
    for (final name in [
      '后台与悬浮播放',
      '播放与提前缓存',
      '缓存管理',
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
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    ),
  );
  Widget _switch(
    String title,
    String subtitle,
    bool value,
    void Function(bool) update,
  ) => SwitchListTile.adaptive(
    contentPadding: EdgeInsets.zero,
    title: Text(title),
    subtitle: Text(subtitle),
    value: value,
    onChanged: busy ? null : (v) => setState(() => update(v)),
  );
  Widget _capabilitySwitch(PlaybackCapability capability, String subtitle) =>
      SwitchListTile.adaptive(
        contentPadding: EdgeInsets.zero,
        title: Text(capability.title),
        subtitle: Text(subtitle),
        value: capability.enabled(draft),
        onChanged: busy ? null : (value) => _capability(capability, value),
      );
  Widget _number(
    String label,
    int value,
    List<int> choices,
    void Function(int) update, {
    String suffix = '',
    Key? key,
  }) {
    final options = {...choices, value}.toList()..sort();
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
            onChanged: busy ? null : (v) => setState(() => update(v!)),
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
      decoration: InputDecoration(labelText: label, hintText: hint),
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
            SizedBox(
              width: 170,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 20),
                  for (final entry in anchors.entries)
                    ListTile(
                      title: Text(
                        entry.key,
                        style: const TextStyle(fontSize: 13),
                      ),
                      onTap: () {
                        final target = entry.value.currentContext;
                        if (target != null) {
                          Scrollable.ensureVisible(
                            target,
                            duration: MediaQuery.disableAnimationsOf(context)
                                ? Duration.zero
                                : const Duration(milliseconds: 180),
                            alignment: 0.03,
                          );
                        }
                      },
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
              child: TextButton(
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
                padding: const EdgeInsets.all(20),
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
                          (v) =>
                              draft = draft.copyWith(concurrentPreparations: v),
                        ),
                      Text(
                        '当前播放优先于排队的预缓存任务。网络速度或空间不足时，后续剧集可能仍需等待。',
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          const Expanded(child: Text('默认清晰度')),
                          DropdownButton<String>(
                            value: draft.defaultQuality,
                            items: const [
                              DropdownMenuItem(
                                value: 'best',
                                child: Text('自动'),
                              ),
                              DropdownMenuItem(
                                value: '720p',
                                child: Text('720p'),
                              ),
                              DropdownMenuItem(
                                value: '1080p',
                                child: Text('1080p'),
                              ),
                            ],
                            onChanged: busy
                                ? null
                                : (v) => setState(
                                    () => draft = draft.copyWith(
                                      defaultQuality: v!,
                                    ),
                                  ),
                          ),
                        ],
                      ),
                      Text(
                        '默认清晰度在下次打开播放器时生效。',
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      _switch(
                        '自动连播',
                        '当前集结束后继续播放下一集。',
                        draft.autoNext,
                        (v) => draft = draft.copyWith(autoNext: v),
                      ),
                      Row(
                        children: [
                          const Expanded(child: Text('界面主题')),
                          DropdownButton<String>(
                            value: draft.themeMode,
                            items: const [
                              DropdownMenuItem(
                                value: 'system',
                                child: Text('跟随系统'),
                              ),
                              DropdownMenuItem(
                                value: 'light',
                                child: Text('浅色'),
                              ),
                              DropdownMenuItem(
                                value: 'dark',
                                child: Text('深色'),
                              ),
                            ],
                            onChanged: busy || runtime == null
                                ? null
                                : (v) => _theme(v!),
                          ),
                        ],
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
                      Row(
                        children: [
                          const Expanded(child: Text('全局排序')),
                          DropdownButton<String>(
                            key: const ValueKey('catalog-sort-setting'),
                            value: draft.catalogSort,
                            items: const [
                              DropdownMenuItem(
                                value: 'online_time',
                                child: Text('最新上架'),
                              ),
                              DropdownMenuItem(
                                value: 'hot_score',
                                child: Text('热度优先'),
                              ),
                              DropdownMenuItem(
                                value: 'hot_collect',
                                child: Text('收藏最多'),
                              ),
                            ],
                            onChanged: busy || runtime == null
                                ? null
                                : (value) => setState(
                                    () => draft = draft.copyWith(
                                      catalogSort: value,
                                    ),
                                  ),
                          ),
                        ],
                      ),
                      const Text('短剧、漫剧、AI 短剧使用同一排序；保存后生效。搜索与榜单保留各自接口排序。'),
                      if (tvBuild)
                        _number(
                          'TV 分类每页条数',
                          draft.tvPageSize,
                          [30, 50],
                          (value) => draft = draft.copyWith(tvPageSize: value),
                          suffix: ' 条',
                          key: const ValueKey('tv-page-size-setting'),
                        ),
                      if (tvBuild)
                        const Text(
                          'TV 接近列表末尾自动加载下一页。每次请求 30 或 50 条，实际返回数量由上游决定。',
                        ),
                    ]),
                    _section('缓存管理', [
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
                        '缓存剧集数量',
                        draft.maxCacheFiles,
                        [10, 20, 30, 50, 100, 200],
                        (v) => draft = draft.copyWith(maxCacheFiles: v),
                        suffix: ' 集',
                      ),
                      _number(
                        '缓存空间上限',
                        draft.maxCacheMb,
                        [128, 256, 512, 1024, 2048, 4096],
                        (v) => draft = draft.copyWith(maxCacheMb: v),
                        suffix: ' MB',
                      ),
                      Text(
                        '保留手动下载、正在播放和预缓存窗口中的文件；手动下载请在下载管理中删除。被保留文件可能使使用量暂时超过上限。',
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 14),
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
                    _section('签名与设备', [
                      Text('签名由本地 Dart 核心生成。视频内容密钥按每集自动解析，无需手动填写。'),
                      const SizedBox(height: 10),
                      Text(
                        '刷新签名状态会重新生成本进程的随机签名上下文，不会刷新账号登录会话。算法更新随 App 版本发布。',
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 14),
                      OutlinedButton.icon(
                        onPressed: busy || runtime == null
                            ? null
                            : () =>
                                  _action(runtime.refreshSigning, '本地签名状态已刷新'),
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
                      const SizedBox(height: 12),
                      Text(
                        '当前设备编号',
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      SelectableText(runtime?.deviceId ?? '当前运行方式不可用'),
                      TextButton(
                        onPressed: busy || runtime == null
                            ? null
                            : () async {
                                final confirmed = await showDialog<bool>(
                                  context: context,
                                  builder: (context) => AlertDialog(
                                    title: Text('重建设备身份？'),
                                    content: Text('将生成新的设备编号，已有登录会话可能需要重新配置。'),
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
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 16),
                      _field('Cookie', cookie, secret: true),
                      _field('x-tt-token', token, secret: true),
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
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _field('内容接口域名', apiHost),
                                _field('视频模型域名', videoHost),
                                _field('内容接口版本号', catalogVersion),
                                _field('内容接口版本代码', catalogCode),
                                _field('视频版本号', videoVersion),
                                _field('视频版本代码', videoCode),
                                _field('视频 User-Agent', userAgent),
                                _switch(
                                  '列表接口也签名',
                                  '默认关闭；只在上游要求时启用。',
                                  draft.signLists,
                                  (v) => draft = draft.copyWith(signLists: v),
                                ),
                                _number(
                                  '请求超时',
                                  draft.timeoutSeconds,
                                  [10, 15, 20, 30, 60, 120],
                                  (v) =>
                                      draft = draft.copyWith(timeoutSeconds: v),
                                  suffix: ' 秒',
                                ),
                                Text(
                                  '版本号、版本代码与 User-Agent 需要匹配。改完后保存，后续请求使用新参数。',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                                ),
                                TextButton(
                                  onPressed: busy ? null : _protocolDefaults,
                                  child: Text('恢复默认接口与签名参数'),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
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
    );
  }
}
