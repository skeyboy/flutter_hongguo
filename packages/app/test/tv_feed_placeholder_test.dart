import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_app/features/tv/tv_library_page.dart';
import 'package:hongguo_app/features/tv/tv_feed_page.dart';
import 'package:hongguo_tv/hongguo_tv.dart';

import 'fakes.dart';

class _Catalog extends FakeCatalog {
  final CatalogClient client;
  _Catalog(this.client);
  @override
  Future<List<CatalogFilter>> themes(String genre) async => [];
  @override
  Future<CatalogPage> browse({
    String genre = 'short_play',
    String sort = 'online_time',
    String? theme,
    String? cursor,
    List<String> seen = const [],
  }) => client.browse(
    genre: genre,
    sort: sort,
    theme: theme,
    cursor: cursor,
    seen: seen,
  );
}

void main() {
  testWidgets(
    'first-page failure is centered in the full content area without a footer',
    (t) async {
      await t.binding.setSurfaceSize(const Size(1280, 720));
      addTearDown(() => t.binding.setSurfaceSize(null));
      final runtime = FakeRuntime(FakeCatalog()..fail = true);
      addTearDown(runtime.dispose);
      await t.pumpWidget(
        MaterialApp(
          builder: (_, child) =>
              TvEnvironment(enabled: true, child: TvNavigation(child: child!)),
          home: TvLibraryPage(runtime: runtime),
        ),
      );
      await t.pumpAndSettle();
      final area = t.getRect(find.byKey(const ValueKey('tv-feed-placeholder')));
      final content = t.getRect(
        find.byKey(const ValueKey('tv-feed-placeholder-content')),
      );
      final grid = t.getRect(find.byType(GridView));
      expect((area.center - content.center).distance, lessThan(1));
      expect(content.center.dx, greaterThan(640));
      expect(area, grid);
      expect(content.bottom, lessThan(area.bottom));
      expect(find.byKey(const ValueKey('tv-feed-status')), findsNothing);
      expect(find.text('加载失败'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
    },
  );
  testWidgets(
    'no error until three retries fail, then manual retry starts a fresh request',
    (t) async {
      var attempts = 0, fail = true;
      final gates = <Completer<void>>[];
      final dio = Dio();
      addTearDown(dio.close);
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            attempts++;
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: jsonEncode(
                  fail
                      ? {'code': 110001, 'message': '暂不可用'}
                      : {
                          'code': 0,
                          'data': {
                            'video_data': [
                              {'series_id': '123', 'title': '恢复成功'},
                            ],
                            'has_more': false,
                          },
                        },
                ),
              ),
            );
          },
        ),
      );
      final catalog = _Catalog(
        CatalogClient(
          dio: dio,
          deviceId: '1234567890123456',
          retry: NetworkRetry(
            wait: (_) {
              final gate = Completer<void>();
              gates.add(gate);
              return gate.future;
            },
          ),
        ),
      );
      final runtime = FakeRuntime(catalog);
      addTearDown(runtime.dispose);
      final active = ValueNotifier('short_play:');
      addTearDown(active.dispose);
      await t.pumpWidget(
        MaterialApp(
          home: TvEnvironment(
            enabled: true,
            child: TvNavigation(
              child: TvFeedPage(
                runtime: runtime,
                genre: 'short_play',
                routeId: 'short_play:',
                active: active,
              ),
            ),
          ),
        ),
      );
      Future<void> tick() async {
        for (var i = 0; i < 6; i++) {
          await t.pump(const Duration(milliseconds: 100));
        }
      }

      await tick();
      for (var i = 0; i < 3; i++) {
        expect(attempts, i + 1);
        expect(find.text('加载失败'), findsNothing);
        expect(find.text('正在加载'), findsOneWidget);
        expect(gates, hasLength(i + 1));
        gates[i].complete();
        await tick();
      }
      expect(attempts, 4);
      expect(find.text('加载失败'), findsOneWidget);
      fail = false;
      await t.tap(find.text('重试'));
      await tick();
      await t.pumpAndSettle();
      expect(attempts, 5);
      expect(find.text('加载失败'), findsNothing);
      expect(find.text('恢复成功'), findsWidgets);
      expect(find.byKey(const ValueKey('tv-feed-placeholder')), findsNothing);
    },
  );
}
