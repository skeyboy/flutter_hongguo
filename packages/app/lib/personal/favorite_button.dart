import 'package:flutter/material.dart';
import 'package:hongguo_api/hongguo_api.dart';

import '../platform/runtime.dart';
import 'personal_library.dart';

class FavoriteButton extends StatefulWidget {
  final AppRuntime runtime;
  final Drama drama;
  const FavoriteButton({super.key, required this.runtime, required this.drama});
  @override
  State<FavoriteButton> createState() => _FavoriteButtonState();
}

class _FavoriteButtonState extends State<FavoriteButton> {
  late final PersonalLibrary library;
  bool ready = false, busy = false;
  String? error;
  @override
  void initState() {
    super.initState();
    library = personalLibraryFor(widget.runtime);
    library.addListener(_changed);
    _load();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    try {
      await library.load();
      if (mounted) {
        setState(() {
          ready = true;
          error = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => error = '收藏读取失败，点击重试');
    }
  }

  @override
  void dispose() {
    library.removeListener(_changed);
    super.dispose();
  }

  Future<void> _toggle() async {
    if (!ready) {
      await _load();
      return;
    }
    setState(() => busy = true);
    try {
      await library.toggleFavorite(widget.drama);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('收藏保存失败，请重试')));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => IconButton(
    key: const ValueKey('favorite-drama'),
    tooltip: error ?? (library.isFavorite(widget.drama.id) ? '取消收藏' : '收藏剧集'),
    onPressed: busy || (!ready && error == null) ? null : _toggle,
    icon: Icon(
      library.isFavorite(widget.drama.id)
          ? Icons.favorite
          : Icons.favorite_border,
    ),
  );
}
