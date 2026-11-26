import 'package:hongguo_api/hongguo_api.dart';

import '../platform/runtime.dart';
import 'personal_library.dart';

/// 历史续播的回执。[start] 是详情分集列表里的 0 起下标，[offset] 是该集的
/// 续播偏移；[noticeCount] 非空表示这次真联网拿到了比记录时更多的集数，
/// 调用方据此播「已更新到 N 集」。离线兜底拿回的分集列表不配这句话——
/// 它的增长不来自这次的网络更新。
class ResumePlan {
  final DramaDetail detail;
  final int start;
  final Duration offset;
  final int? noticeCount;
  const ResumePlan({
    required this.detail,
    required this.start,
    required this.offset,
    this.noticeCount,
  });
}

/// 从观看历史进入播放前先把分集解析出来。联网刷新放最前：上游新增的剧集
/// 要能接着看，而 `CatalogRepository.detail` 背后是 6 小时的内存缓存、
/// `LibraryCache.readDetail` 是磁盘快照，直接问它们都可能拿旧列表。
///
/// 刷新失败绝不挡播放：依次回退 [AppRuntime.catalog]（离线时若内存里还有
/// 未过期的缓存就用它）和本地快照；全都拿不到才把错误交还给调用方的统一
/// 提示。记录的 vid 在新列表里找不到（上游重发了 vid）时按集号续播同一集。
Future<ResumePlan> resolveResumeDetail(
  AppRuntime runtime,
  WatchRecord record,
) async {
  var live = false;
  DramaDetail detail;
  try {
    if (runtime is DetailRefreshRuntime) {
      try {
        detail = await runtime.refreshDetail(record.drama.id);
        live = true;
      } catch (_) {
        // 离线或上游失败：内存里若还有未过期的缓存，它比磁盘快照新。
        detail = await runtime.catalog.detail(record.drama.id);
      }
    } else {
      detail = await runtime.catalog.detail(record.drama.id);
    }
  } catch (_) {
    final cached = runtime is LibraryCacheRuntime
        ? await runtime.libraryCache.readDetail(record.drama.id)
        : null;
    if (cached == null) rethrow;
    detail = cached;
  }
  var start = detail.episodes.indexWhere((e) => e.vid == record.vid);
  var offset = record.resumeAt;
  if (start < 0) {
    if (detail.episodes.isEmpty) throw StateError('该分集已不可用');
    start = (record.episode - 1).clamp(0, detail.episodes.length - 1);
    offset = Duration.zero;
  }
  final known = record.drama.episodeCount;
  final notice =
      live && known > 0 && detail.episodes.length > known
      ? detail.episodes.length
      : null;
  return ResumePlan(
    detail: detail,
    start: start,
    offset: offset,
    noticeCount: notice,
  );
}
