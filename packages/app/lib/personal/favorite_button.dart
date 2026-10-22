import 'package:flutter/material.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_tv/hongguo_tv.dart';

import '../platform/runtime.dart';
import 'personal_library.dart';

class FavoriteButton extends StatefulWidget {
  final AppRuntime runtime;
  final Drama drama;

  /// Remote-driven screens cannot reach an `IconButton` reliably, and a bare
  /// icon in an action row reads as decoration rather than a third action.
  final bool tvLayout;
  final FocusNode? focusNode;
  const FavoriteButton({
    super.key,
    required this.runtime,
    required this.drama,
    this.tvLayout = false,
    this.focusNode,
  });
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
  Widget build(BuildContext context) {
    final favorite = library.isFavorite(widget.drama.id);
    if (widget.tvLayout) {
      return TvFocusable(
        key: const ValueKey('favorite-drama'),
        label: favorite ? '已收藏' : '收藏',
        focusNode: widget.focusNode,
        onActivate: busy || (!ready && error == null) ? null : _toggle,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          child: Text(
            error ?? (favorite ? '♥ 已收藏' : '♡ 收藏'),
            style: const TextStyle(fontSize: 20),
          ),
        ),
      );
    }
    return IconButton(
      key: const ValueKey('favorite-drama'),
      tooltip: error ?? (favorite ? '取消收藏' : '收藏剧集'),
      onPressed: busy || (!ready && error == null) ? null : _toggle,
      icon: Icon(favorite ? Icons.favorite : Icons.favorite_border),
    );
  }
}
