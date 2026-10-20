import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:hongguo_api/hongguo_api.dart';

/// Shared online artwork with cached loading; explicit local providers remain
/// authoritative so offline browsing never falls back to a network request.
class DramaCover extends StatefulWidget {
  final Drama drama;
  final ImageProvider? imageProvider;
  final bool allowNetwork;
  const DramaCover({
    super.key,
    required this.drama,
    this.imageProvider,
    this.allowNetwork = true,
  });

  @override
  State<DramaCover> createState() => _DramaCoverState();
}

class _DramaCoverState extends State<DramaCover> {
  int attempt = 0;
  bool retrying = false;
  Drama get drama => widget.drama;
  ImageProvider? get imageProvider => widget.imageProvider;
  bool get allowNetwork => widget.allowNetwork;

  Future<void> _retry(String url) async {
    if (retrying) return;
    setState(() => retrying = true);
    try {
      await CachedNetworkImage.evictFromCache(url);
    } catch (_) {
      // Still allow a fresh image widget if disk cache eviction is unavailable.
    } finally {
      if (mounted) {
        setState(() {
          retrying = false;
          attempt++;
        });
      }
    }
  }

  Widget _loading() => Stack(
    fit: StackFit.expand,
    children: [
      _placeholder(),
      Positioned(
        right: 10,
        bottom: 10,
        child: SizedBox(
          width: 16,
          height: 16,
          child: MediaQuery.disableAnimationsOf(context)
              ? const Icon(Icons.image_outlined, size: 16)
              : const CircularProgressIndicator(
                  strokeWidth: 2,
                  semanticsLabel: '封面加载中',
                ),
        ),
      ),
    ],
  );

  Widget _failed(String url) => Stack(
    fit: StackFit.expand,
    children: [
      _placeholder(),
      Align(
        alignment: Alignment.bottomCenter,
        child: IconButton.filledTonal(
          tooltip: '重试加载封面',
          onPressed: retrying ? null : () => _retry(url),
          icon: const Icon(Icons.refresh, size: 20),
        ),
      ),
    ],
  );

  String? get _networkUrl {
    final value = drama.cover.trim();
    final url = value.startsWith('//') ? 'https:$value' : value;
    final uri = Uri.tryParse(url);
    return uri != null &&
            (uri.scheme == 'https' || uri.scheme == 'http') &&
            uri.host.isNotEmpty
        ? url
        : null;
  }

  Widget _placeholder() => Container(
    color: Color.lerp(
      const Color(0xffe6d6c3),
      const Color(0xffd1dce0),
      (drama.id.hashCode & 255) / 255,
    ),
    alignment: Alignment.center,
    padding: const EdgeInsets.all(16),
    child: Text(
      drama.title,
      textAlign: TextAlign.center,
      maxLines: 4,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: Color(0xff615347),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final url = allowNetwork ? _networkUrl : null;
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: imageProvider != null
          ? Image(
              image: imageProvider!,
              fit: BoxFit.cover,
              width: double.infinity,
              height: double.infinity,
              errorBuilder: (_, _, _) => _placeholder(),
            )
          : url == null
          ? _placeholder()
          : LayoutBuilder(
              builder: (context, constraints) {
                final reducedMotion = MediaQuery.disableAnimationsOf(context);
                final width = constraints.maxWidth;
                final decodeWidth = width.isFinite && width > 0
                    ? (width * MediaQuery.devicePixelRatioOf(context))
                          .ceil()
                          .clamp(1, 1600)
                    : null;
                return CachedNetworkImage(
                  // New drama IDs must never display another drama's old cover.
                  // URL refreshes for the same ID can keep the previous artwork.
                  key: ValueKey('${drama.id}:$attempt'),
                  imageUrl: url,
                  fit: BoxFit.cover,
                  width: double.infinity,
                  height: double.infinity,
                  memCacheWidth: decodeWidth,
                  useOldImageOnUrlChange: true,
                  fadeInDuration: reducedMotion
                      ? Duration.zero
                      : const Duration(milliseconds: 140),
                  fadeOutDuration: reducedMotion
                      ? Duration.zero
                      : const Duration(milliseconds: 80),
                  placeholder: (_, _) => _loading(),
                  errorWidget: (_, _, _) => _failed(url),
                );
              },
            ),
    );
  }
}
