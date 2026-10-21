import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hongguo_cast/hongguo_cast.dart';

import 'cast_controller.dart';

/// Lists renderers found on the Wi-Fi network and returns the chosen one.
///
/// Discovery itself is started by the caller so that the sheet stays pure
/// presentation and can be pumped without touching a socket.
Future<KnownRenderer?> showCastDevicePicker(
  BuildContext context,
  CastController controller,
) {
  final size = MediaQuery.sizeOf(context);
  final sheet = CastDeviceSheet(controller: controller);
  if (size.width >= 720 && size.height >= 400) {
    return showDialog<KnownRenderer>(
      context: context,
      builder: (_) => Dialog(
        child: SizedBox(width: 520, height: size.height * .7, child: sheet),
      ),
    );
  }
  return showModalBottomSheet<KnownRenderer>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => SizedBox(height: size.height * .65, child: sheet),
  );
}

class CastDeviceSheet extends StatelessWidget {
  final CastController controller;
  const CastDeviceSheet({super.key, required this.controller});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (_, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 8, 4),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  '选择附近的电视/盒子',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                key: const ValueKey('cast-refresh'),
                tooltip: '重新搜索',
                onPressed: controller.browsing || controller.active
                    ? null
                    : () => unawaited(controller.browse()),
                icon: const Icon(Icons.refresh),
              ),
              IconButton(
                tooltip: '关闭',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
        if (controller.browsing)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Row(
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 10),
                Text('正在搜索同一 Wi-Fi 的电视…'),
              ],
            ),
          ),
        Expanded(
          child: controller.devices.isEmpty
              ? _Empty(
                  notice: controller.error ?? '未发现设备。',
                  searching: controller.browsing,
                )
              : ListView(
                  children: [
                    for (final renderer in controller.devices)
                      ListTile(
                        key: ValueKey('cast-renderer-${renderer.udn}'),
                        dense: true,
                        leading: const Icon(Icons.tv_rounded),
                        title: Text(renderer.friendlyName),
                        subtitle: Text(
                          renderer.isControllable
                              ? renderer.device.modelName
                              : '${renderer.device.modelName} · 该设备不支持播控',
                        ),
                        trailing: controller.target?.udn == renderer.udn
                            ? const Icon(Icons.check)
                            : null,
                        onTap:
                            controller.browsing ||
                                controller.active ||
                                !renderer.isControllable
                            ? null
                            : () => Navigator.pop(context, renderer),
                      ),
                  ],
                ),
        ),
        if (!controller.browsing && controller.devices.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
            child: Text(
              '排查：两台设备需在同一 Wi-Fi；电视端需在系统设置里开启 DLNA/投屏服务；'
              '路由器开启 AP 隔离时彼此不可见。',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    ),
  );
}

class _Empty extends StatelessWidget {
  final String notice;
  final bool searching;
  const _Empty({required this.notice, required this.searching});

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(
        searching ? '电视通常需要几秒才应答，请稍候。' : notice,
        textAlign: TextAlign.center,
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    ),
  );
}
