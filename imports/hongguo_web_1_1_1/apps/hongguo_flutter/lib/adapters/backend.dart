import 'package:hongguo_core/hongguo_core.dart';

class Backend {
  final CatalogRepository catalog;
  final PlaybackRepository playback;
  final String label;
  final void Function() close;
  const Backend(
    this.catalog,
    this.playback, {
    required this.label,
    required this.close,
  });
}
