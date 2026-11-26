import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hongguo_core/hongguo_core.dart';

import 'background/host_policy.dart';
import 'desktop_window.dart';
import 'macos_window.dart';
import 'windows_window.dart';

typedef SettingsReader = Future<AppSettings> Function();
typedef SettingsPersister = Future<void> Function(AppSettings settings);

/// 确认框的一次裁决结果。
@visibleForTesting
class CloseChoice {
  const CloseChoice({required this.behavior, required this.remember});
  final WindowCloseBehavior behavior;
  final bool remember;
}

/// 窗口动作的窄接口：产品行为走 [DesktopWindow]，测试注入假实现。
@visibleForTesting
abstract interface class WindowCloseActions {
  Future<void> hide();
  Future<void> quit();
  Future<void> applyPreferences({
    required WindowCloseBehavior closeBehavior,
    required bool rememberWindowState,
  });
}

class _DesktopWindowActions implements WindowCloseActions {
  const _DesktopWindowActions();
  @override
  Future<void> hide() => DesktopWindow.hide();
  @override
  Future<void> quit() => DesktopWindow.quit();
  @override
  Future<void> applyPreferences({
    required WindowCloseBehavior closeBehavior,
    required bool rememberWindowState,
  }) => DesktopWindow.applyPreferences(
    closeBehavior: closeBehavior,
    rememberWindowState: rememberWindowState,
  );
}

/// 关闭按钮的裁决器：偏好 tray/exit 直接执行，ask（默认）弹确认框。
/// 纯逻辑、依赖可注入，widget 测试不需要任何 MethodChannel。
@visibleForTesting
class WindowCloseCoordinator {
  WindowCloseCoordinator({
    required this.readSettings,
    required this.persist,
    this.actions = const _DesktopWindowActions(),
    this.confirmDialog = showCloseConfirmDialog,
  });

  final SettingsReader readSettings;
  final SettingsPersister persist;
  final WindowCloseActions actions;
  final Future<CloseChoice?> Function(BuildContext) confirmDialog;

  /// 原生层转发 closeRequested 后的入口。
  Future<void> resolve() async {
    if (!DesktopWindow.supported) return;
    AppSettings settings;
    try {
      settings = await readSettings();
    } catch (_) {
      // 拿不到设置（engine 早期/异常）时退回托盘语义，至少不吞关闭事件。
      return actions.hide();
    }
    switch (settings.windowCloseBehavior) {
      case WindowCloseBehavior.tray:
        return actions.hide();
      case WindowCloseBehavior.exit:
        return actions.quit();
      case WindowCloseBehavior.ask:
        return _ask(settings);
    }
  }

  Future<void> _ask(AppSettings settings) async {
    final context = WindowCloseGate.navigatorKey.currentContext;
    // 无处弹框（导航未就绪）时退回托盘语义，不让关闭按钮彻底失灵。
    if (context == null || !context.mounted) return actions.hide();
    final choice = await confirmDialog(context);
    if (choice == null) return; // 取消：什么都不做。
    if (choice.remember) {
      try {
        final next = settings.copyWith(windowCloseBehavior: choice.behavior);
        await persist(next);
        await actions.applyPreferences(
          closeBehavior: choice.behavior,
          rememberWindowState: next.rememberWindowState,
        );
      } catch (_) {
        // 记住选择失败不阻塞本次关闭动作。
      }
    }
    switch (choice.behavior) {
      case WindowCloseBehavior.tray:
      case WindowCloseBehavior.ask:
        return actions.hide();
      case WindowCloseBehavior.exit:
        return actions.quit();
    }
  }
}

/// 关闭确认对话框：二选一 + 「记住我的选择」+ 影响说明（见设计文档）。
@visibleForTesting
Future<CloseChoice?> showCloseConfirmDialog(BuildContext context) =>
    showDialog<CloseChoice>(
      context: context,
      useRootNavigator: true,
      barrierDismissible: false,
      builder: (_) => const _CloseConfirmDialog(),
    );

class _CloseConfirmDialog extends StatefulWidget {
  const _CloseConfirmDialog();

  @override
  State<_CloseConfirmDialog> createState() => _CloseConfirmDialogState();
}

class _CloseConfirmDialogState extends State<_CloseConfirmDialog> {
  WindowCloseBehavior _behavior = WindowCloseBehavior.tray;
  bool _remember = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      key: const ValueKey('window-close-confirm'),
      title: const Text('关闭窗口'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          RadioGroup<WindowCloseBehavior>(
            groupValue: _behavior,
            onChanged: (value) =>
                setState(() => _behavior = value ?? _behavior),
            child: Column(
              children: [
                RadioListTile<WindowCloseBehavior>(
                  key: const ValueKey('close-choice-tray'),
                  value: WindowCloseBehavior.tray,
                  title: const Text('最小化到托盘'),
                  subtitle: const Text('播放和后台下载继续进行，托盘图标可随时恢复窗口'),
                ),
                RadioListTile<WindowCloseBehavior>(
                  key: const ValueKey('close-choice-exit'),
                  value: WindowCloseBehavior.exit,
                  title: const Text('退出程序'),
                  subtitle: const Text('退出会中断正在进行的播放与后台下载，托盘图标同时移除'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          CheckboxListTile(
            key: const ValueKey('close-remember-choice'),
            value: _remember,
            onChanged: (value) => setState(() => _remember = value ?? false),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            title: const Text('记住我的选择，下次不再询问'),
            subtitle: Text(
              '可随时在 设置 → 窗口行为 里改回每次询问',
              style: TextStyle(fontSize: 12, color: scheme.outline),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          key: const ValueKey('close-confirm-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('close-confirm-ok'),
          onPressed: () =>
              Navigator.of(context)
                  .pop(CloseChoice(behavior: _behavior, remember: _remember)),
          child: const Text('确定'),
        ),
      ],
    );
  }
}

/// 挂在 `MaterialApp.builder` 里：注册原生 close 入站回调、下发窗口偏好、
/// 开关 Windows 几何监听。桌面之外全部为透传。
class WindowCloseGate extends StatefulWidget {
  const WindowCloseGate({
    super.key,
    required this.readSettings,
    required this.persist,
    this.settings,
    required this.child,
  });

  final SettingsReader readSettings;
  final SettingsPersister persist;

  /// 最近一次的设置快照：偏好变化（含确认框里勾选记住）时即时重发原生。
  final AppSettings? settings;
  final Widget child;

  /// 根 Navigator 的 key：确认对话框弹在最外层，盖住全部路由。
  static final navigatorKey = GlobalKey<NavigatorState>();
  static State<WindowCloseGate>? _instance;

  @override
  State<WindowCloseGate> createState() => WindowCloseGateState();
}

@visibleForTesting
class WindowCloseGateState extends State<WindowCloseGate> {
  late final WindowCloseCoordinator coordinator;

  @override
  void initState() {
    super.initState();
    WindowCloseGate._instance = this;
    coordinator = WindowCloseCoordinator(
      readSettings: widget.readSettings,
      persist: widget.persist,
    );
    if (!desktopHost) return;
    MacWindow.onCloseRequest = coordinator.resolve;
    MacWindow.ensureInboundHandler();
    WindowsWindow.onCloseRequest = coordinator.resolve;
    WindowsWindow.ensureInbound();
    DesktopWindow.onGeometryPersist = _persistGeometry;
    unawaited(_bootstrap());
  }

  @override
  void didUpdateWidget(covariant WindowCloseGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = widget.settings;
    final old = oldWidget.settings;
    if (!desktopHost || next == null) return;
    if (old == null ||
        old.windowCloseBehavior != next.windowCloseBehavior ||
        old.rememberWindowState != next.rememberWindowState) {
      unawaited(_onSettings(next));
    }
  }

  Future<void> _bootstrap() async {
    try {
      final settings = await widget.readSettings();
      await DesktopWindow.restoreWindowState(settings);
      await DesktopWindow.applyPreferences(
        closeBehavior: settings.windowCloseBehavior,
        rememberWindowState: settings.rememberWindowState,
      );
      DesktopWindow.trackWindowState(settings.rememberWindowState);
    } catch (_) {
      // 设置不可用时维持原生默认（托盘隐藏），不阻塞应用启动。
    }
  }

  Future<void> _onSettings(AppSettings settings) async {
    await DesktopWindow.applyPreferences(
      closeBehavior: settings.windowCloseBehavior,
      rememberWindowState: settings.rememberWindowState,
    );
    DesktopWindow.trackWindowState(settings.rememberWindowState);
  }

  Future<void> _persistGeometry(String bounds, bool maximized) async {
    try {
      final settings = await widget.readSettings();
      await widget.persist(
        settings.copyWith(windowBounds: bounds, windowMaximized: maximized),
      );
    } catch (_) {
      // 几何记录失败只损失一次恢复机会。
    }
  }

  @override
  void dispose() {
    if (WindowCloseGate._instance == this) {
      WindowCloseGate._instance = null;
    }
    MacWindow.onCloseRequest = null;
    WindowsWindow.onCloseRequest = null;
    DesktopWindow.onGeometryPersist = null;
    DesktopWindow.trackWindowState(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
