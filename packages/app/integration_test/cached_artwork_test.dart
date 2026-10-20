import 'dart:io';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_app/widgets/drama_cover.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'artwork downloads once, survives memory eviction offline and honors local-only loading',
    (t) async {
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawColor(const Color(0xffe55f37), BlendMode.src);
      final picture = recorder.endRecording();
      final image = await picture.toImage(8, 8);
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!
          .buffer
          .asUint8List();
      image.dispose();
      picture.dispose();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0;
      server.listen((request) async {
        requests++;
        request.response.headers
          ..contentType = ContentType('image', 'png')
          ..set(HttpHeaders.cacheControlHeader, 'max-age=3600');
        request.response.add(bytes);
        await request.response.close();
      });
      final url =
          'http://127.0.0.1:${server.port}/poster-${DateTime.now().microsecondsSinceEpoch}.png';
      final drama = Drama(
        id: 'image-cache-fixture',
        title: '封面缓存验证',
        cover: url,
      );
      Future<void> show(DramaCover cover) => t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(width: 160, height: 240, child: cover),
            ),
          ),
        ),
      );
      Future<void> waitForImage() async {
        for (var i = 0; i < 100; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          await t.pump();
          if (t
              .widgetList<RawImage>(find.byType(RawImage))
              .any((w) => w.image != null)) {
            return;
          }
        }
        fail('Artwork did not decode');
      }

      try {
        await show(DramaCover(drama: drama));
        await waitForImage();
        await t.pumpAndSettle();
        expect(requests, 1);
        final cached = await CachedNetworkImageProvider.defaultCacheManager
            .getFileFromCache(url, ignoreMemCache: true);
        expect(cached, isNotNull);
        expect(await cached!.file.exists(), isTrue);
        print('TV_SCREENSHOT=image-online');
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await t.pumpWidget(const SizedBox());
        await t.pump();
        PaintingBinding.instance.imageCache
          ..clear()
          ..clearLiveImages();
        await server.close(force: true);
        await show(DramaCover(drama: drama));
        await waitForImage();
        await t.pumpAndSettle();
        expect(requests, 1);
        print('TV_SCREENSHOT=image-disk-cache-offline');
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await show(DramaCover(drama: drama, allowNetwork: false));
        await t.pumpAndSettle();
        expect(find.byType(CachedNetworkImage), findsNothing);
        expect(find.text('封面缓存验证'), findsOneWidget);
        await show(
          DramaCover(
            drama: drama,
            imageProvider: MemoryImage(bytes),
            allowNetwork: false,
          ),
        );
        await waitForImage();
        expect(find.byType(CachedNetworkImage), findsNothing);
        expect(requests, 1);
        print(
          'CACHED_ARTWORK_NATIVE_PASS requests=1 disk_cache=true offline_reload=true local_only=true',
        );
      } finally {
        await t.pumpWidget(const SizedBox());
        await server.close(force: true);
        await CachedNetworkImage.evictFromCache(url);
      }
    },
  );
}
