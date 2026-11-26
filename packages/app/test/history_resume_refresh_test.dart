// 从观看历史进入播放时的分集解析：`resolveResumeDetail`（my_page 的
// 继续观看走它）必须先联网刷新详情，让上游新增的剧集能接着看；离线时
// 逐级兜底，绝不挡播放。
//
// PlayerPage 自己实例化 media_kit 原生资源，widget 测试里打不开，所以
// 这里对纯函数做单元测试；页面层的接线由 my_page/tv_library_surfaces
// 既有测试兜住渲染，接线正确性由 dart analyze 与函数签名钉住。

import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_app/catalog/library_cache.dart';
import 'package:hongguo_app/personal/personal_library.dart';
import 'package:hongguo_app/personal/resume_detail.dart';
import 'package:hongguo_app/platform/runtime.dart';

import 'fakes.dart';

class _CountingCatalog extends FakeCatalog {
  int detailCalls = 0;
  @override
  Future<DramaDetail> detail(String id) async {
    detailCalls++;
    return super.detail(id);
  }
}

class _RefreshRuntime extends FakeRuntime
    implements DetailRefreshRuntime, LibraryCacheRuntime {
  _RefreshRuntime(super.catalog);
  @override
  _CountingCatalog get catalog => super.catalog as _CountingCatalog;
  @override
  final LibraryCache libraryCache = LibraryCache();

  /// 「上游现在在线的剧集」——独立于 FakeCatalog.episodes，模拟刷新通道
  /// 绕开主目录客户端的 6 小时内存缓存。
  List<Episode> online = const [
    Episode(vid: '11', index: 1),
    Episode(vid: '12', index: 2),
    Episode(vid: '13', index: 3),
  ];
  bool offline = false;
  int refreshCalls = 0;
  @override
  Future<DramaDetail> refreshDetail(String id) async {
    refreshCalls++;
    if (offline) throw const CatalogError('网络不可达');
    return DramaDetail(
      Drama(
        id: FakeCatalog.demo.id,
        title: FakeCatalog.demo.title,
        intro: FakeCatalog.demo.intro,
        episodeCount: online.length,
      ),
      online,
    );
  }
}

WatchRecord _record({String vid = '11', int episode = 1, int known = 3}) =>
    WatchRecord(
      drama: Drama(
        id: FakeCatalog.demo.id,
        title: FakeCatalog.demo.title,
        episodeCount: known,
      ),
      vid: vid,
      episode: episode,
      positionMs: 42000,
      durationMs: 120000,
      updated: DateTime.now(),
    );

void main() {
  test('历史续播先联网刷新：快照与 6 小时缓存都不再短路', () async {
    final runtime = _RefreshRuntime(_CountingCatalog());
    addTearDown(runtime.dispose);
    // 磁盘快照还停在旧的三集——旧行为是它直接短路，联网从未发生。
    await runtime.libraryCache.rememberDetail(
      const DramaDetail(FakeCatalog.demo, [
        Episode(vid: '11', index: 1),
        Episode(vid: '12', index: 2),
        Episode(vid: '13', index: 3),
      ]),
    );
    // 上游新增了两集。
    runtime.online = const [
      Episode(vid: '11', index: 1),
      Episode(vid: '12', index: 2),
      Episode(vid: '13', index: 3),
      Episode(vid: '14', index: 4),
      Episode(vid: '15', index: 5),
    ];

    final plan = await resolveResumeDetail(runtime, _record());

    expect(runtime.refreshCalls, 1, reason: '续播必须真发一次在线刷新');
    expect(runtime.catalog.detailCalls, 0, reason: '快照在，旧路径会短路主目录');
    expect(plan.detail.episodes.map((e) => e.vid), [
      '11',
      '12',
      '13',
      '14',
      '15',
    ]);
    // 记录的 vid 还在：从它续播，且后面的新集都可点。
    expect(plan.start, 0);
    expect(plan.start + 1, lessThan(plan.detail.episodes.length));
    expect(plan.offset, const Duration(milliseconds: 42000));
    expect(plan.noticeCount, 5, reason: '记录时 3 集，现在 5 集，要提示');
  });

  test('集数没有增长时不播「已更新」', () async {
    final runtime = _RefreshRuntime(_CountingCatalog());
    addTearDown(runtime.dispose);

    final plan = await resolveResumeDetail(runtime, _record());
    expect(plan.noticeCount, isNull);
    expect(plan.start, 0);
  });

  test('离线时逐级兜底：内存缓存、再磁盘快照，播放不被挡', () async {
    final runtime = _RefreshRuntime(_CountingCatalog());
    addTearDown(runtime.dispose);
    await runtime.libraryCache.rememberDetail(
      const DramaDetail(FakeCatalog.demo, [
        Episode(vid: '11', index: 1),
        Episode(vid: '12', index: 2),
      ]),
    );
    // 网络死了：刷新失败，主目录的 detailFail 也让它拿不到内存缓存。
    runtime.offline = true;
    runtime.catalog.detailFail = true;

    final plan = await resolveResumeDetail(runtime, _record());

    expect(runtime.refreshCalls, 1);
    expect(runtime.catalog.detailCalls, 1, reason: '刷新失败先试内存缓存');
    expect(plan.detail.episodes.map((e) => e.vid), ['11', '12']);
    expect(plan.start, 0);
    expect(plan.offset, const Duration(milliseconds: 42000));
    // 快照兜底不算「更新」，不给提示。
    expect(plan.noticeCount, isNull);
  });

  test('刷新死了但内存缓存还热：用缓存列表播放，不提示更新', () async {
    final runtime = _RefreshRuntime(_CountingCatalog());
    addTearDown(runtime.dispose);
    runtime.offline = true;

    final plan = await resolveResumeDetail(runtime, _record());
    expect(runtime.catalog.detailCalls, 1);
    expect(plan.detail.episodes.map((e) => e.vid), ['11', '12', '13']);
    expect(plan.noticeCount, isNull);
  });

  test('上游重发 vid 时按记录的集号续播同一集，偏移清零', () async {
    final runtime = _RefreshRuntime(_CountingCatalog());
    addTearDown(runtime.dispose);
    runtime.online = const [
      Episode(vid: '21', index: 1),
      Episode(vid: '22', index: 2),
      Episode(vid: '23', index: 3),
      Episode(vid: '24', index: 4),
    ];

    final plan = await resolveResumeDetail(runtime, _record(vid: '99', episode: 2));

    expect(plan.start, 1, reason: '第 2 集对应下标 1');
    expect(plan.offset, Duration.zero, reason: '新 vid 没看过，偏移不适用');
    expect(plan.start + 1, lessThan(plan.detail.episodes.length));
  });

  test('所有来源都拿不到分集时保持原报错', () async {
    final runtime = _RefreshRuntime(_CountingCatalog());
    addTearDown(runtime.dispose);
    runtime.offline = true;
    runtime.catalog.detailFail = true;

    await expectLater(
      resolveResumeDetail(runtime, _record()),
      throwsA(isA<CatalogError>()),
    );
  });

  test('不支持刷新的运行时保持旧路径：直接问 catalog，不额外发请求', () async {
    final catalog = _CountingCatalog();
    final runtime = FakeRuntime(catalog);
    addTearDown(runtime.dispose);

    final plan = await resolveResumeDetail(runtime, _record());

    expect(catalog.detailCalls, 1);
    expect(plan.detail.episodes.map((e) => e.vid), ['11', '12', '13']);
    expect(plan.noticeCount, isNull, reason: '缓存与否不可知，宁可不提示');
    expect(plan.offset, const Duration(milliseconds: 42000));
  });
}
