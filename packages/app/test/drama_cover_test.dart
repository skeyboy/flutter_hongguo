import 'dart:io';

import 'package:file/local.dart';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_app/widgets/drama_cover.dart';

class _Images extends Fake implements BaseCacheManager {
  final File file;
  bool fail = true;
  int requests = 0, removals = 0;
  _Images(this.file);
  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) async* {
    requests++;
    if (fail) throw StateError('offline');
    yield FileInfo(
      const LocalFileSystem().file(file.path),
      FileSource.Cache,
      DateTime(2099),
      url,
    );
  }

  @override
  Future<void> removeFile(String key) async {
    removals++;
  }
}

void main() {
  testWidgets(
    'failed async cover retries independently and local mode never fetches',
    (tester) async {
      final folder = Directory.systemTemp.createTempSync('cover-test-');
      final file = File(
        'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_16.png',
      ).copySync('${folder.path}/pixel.png');
      final cache = _Images(file);
      CachedNetworkImageProvider.defaultCacheManager = cache;
      addTearDown(() {
        PaintingBinding.instance.imageCache.clear();
        folder.deleteSync(recursive: true);
      });
      const drama = Drama(
        id: 'cover-test',
        title: '测试封面',
        cover: 'https://example.test/cover-test.png',
      );
      Future<void> mount(bool network) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 140,
              height: 200,
              child: DramaCover(drama: drama, allowNetwork: network),
            ),
          ),
        ),
      );
      await mount(true);
      await tester.pumpAndSettle();
      expect(find.byTooltip('重试加载封面'), findsOneWidget);
      expect(cache.requests, 1);
      cache.fail = false;
      await tester.tap(find.byTooltip('重试加载封面'));
      var decoded = false;
      // Native file IO/codec completion needs real async time between frames;
      // pumpAndSettle alone advances only the fake clock of the loading spinner.
      for (var i = 0; i < 30 && !decoded; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        decoded = tester
            .widgetList<RawImage>(find.byType(RawImage))
            .any((image) => image.image != null);
      }
      expect(decoded, isTrue);
      await tester.pumpAndSettle();
      expect(cache.removals, 1);
      expect(cache.requests, 2);
      expect(find.byTooltip('重试加载封面'), findsNothing);
      await mount(false);
      await tester.pumpAndSettle();
      expect(find.byType(CachedNetworkImage), findsNothing);
      expect(cache.requests, 2);
      expect(tester.takeException(), isNull);
    },
  );
}
