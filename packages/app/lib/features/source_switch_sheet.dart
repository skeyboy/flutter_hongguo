import 'package:flutter/material.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_tv/hongguo_tv.dart';

import '../platform/runtime.dart';
import 'detail_page.dart';
import 'tv/tv_detail_page.dart';

/// 详情页「切换片源」：列出其它启用源 → 跨源同名解析（SourceResolver）→
/// 命中则跳转到该源的详情页；未命中或没有备选时给可读提示。
///
/// Phone 用 bottom sheet；TV 弹层的行同样是遥控可达的 TvFocusable。
/// 解析期间展示加载弹层——跨源搜索可能要走几个源，不能让页面像卡死。
Future<void> showSourceSwitch(
  BuildContext context,
  AppRuntime runtime,
  Drama drama,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final SourceSearchFacade? facade = runtime.catalog is SourceSearchFacade
      ? runtime.catalog as SourceSearchFacade
      : null;
  if (facade == null) {
    messenger.showSnackBar(
      const SnackBar(content: Text('当前环境不支持片源切换')),
    );
    return;
  }
  final resolver = SourceResolver(facade);
  final current = resolver.currentSourceId(drama.id);
  final options = resolver.alternatives(current);
  if (options.isEmpty) {
    messenger.showSnackBar(
      const SnackBar(content: Text('没有其它启用的片源；可在 设置 → 片源 中开启')),
    );
    return;
  }
  final isTv = TvEnvironment.of(context);
  final picked = await showModalBottomSheet<({String id, String label})>(
    context: context,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              '切换片源 · ${drama.title}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          for (final option in options)
            if (isTv)
              TvFocusable(
                key: ValueKey('source-switch-${option.id}'),
                label: option.label,
                onActivate: () => Navigator.pop(context, option),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 14,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          option.label,
                          style: const TextStyle(fontSize: 22),
                        ),
                      ),
                      Text(
                        '搜索同名剧',
                        style: TextStyle(
                          fontSize: 15,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else
              ListTile(
                key: ValueKey('source-switch-${option.id}'),
                leading: const Icon(Icons.travel_explore),
                title: Text(option.label),
                subtitle: Text('搜索「${drama.title}」'),
                onTap: () => Navigator.pop(context, option),
              ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (picked == null || !context.mounted) return;

  // 加载弹层：resolve 内部已按预算限流，这里只负责可见性。
  final resolved = await showDialog<SourceMatch>(
    context: context,
    barrierDismissible: false,
    builder: (context) => FutureBuilder<SourceMatch?>(
      future: SourceResolver(facade).resolve(
        title: drama.title,
        excludeId: current,
      ),
      builder: (context, snapshot) {
        final match = snapshot.data;
        if (snapshot.connectionState != ConnectionState.done) {
          return const AlertDialog(
            content: SizedBox(
              width: 120,
              height: 56,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(width: 16),
                  Text('正在其它片源中搜索同名剧…'),
                ],
              ),
            ),
          );
        }
        // done：把结果带回外层。
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (context.mounted) Navigator.pop(context, match);
        });
        return const SizedBox.shrink();
      },
    ),
  );
  if (!context.mounted) return;
  if (resolved == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('其它片源没有找到「${drama.title}」')),
    );
    return;
  }
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text('已切换到 ${resolved.sourceLabel}')),
  );
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => isTv
          ? TvDetailPage(runtime: runtime, initial: resolved.drama)
          : DetailPage(runtime: runtime, initial: resolved.drama),
    ),
  );
}
