import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:file/local.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_app/widgets/cover_decode_size.dart';
import 'package:hongguo_app/widgets/drama_cover.dart';

class _Images extends Fake implements BaseCacheManager {
  final File file;
  int requests = 0;
  _Images(this.file);
  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) async* {
    requests++;
    yield FileInfo(
      const LocalFileSystem().file(file.path),
      FileSource.Cache,
      DateTime(2099),
      url,
    );
  }
}

const _drama = Drama(
  id: 'resize-test',
  title: '缩放测试',
  cover: 'https://example.test/resize-test.png',
);

/// The decode steps actually in the tree, read off the providers the image
/// widgets resolved to: a resize that re-decodes shows a second step alongside
/// the one still being painted, and the placeholder it flashes is the giveaway.
Set<int> _decodeSteps(WidgetTester tester) => tester
    .widgetList<Image>(find.byType(Image))
    .map((widget) => widget.image)
    .whereType<ResizeImage>()
    .map((provider) => provider.width!)
    .toSet();

Future<void> _mount(WidgetTester tester, double width) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: width,
          height: 240,
          child: DramaCover(drama: _drama),
        ),
      ),
    ),
  ),
);

Duration? _fadeIn(WidgetTester tester) => tester
    .widget<CachedNetworkImage>(find.byType(CachedNetworkImage))
    .fadeInDuration;

/// Native file IO and the codec do not run on the fake clock, so a decode needs
/// real time between frames.
Future<void> _awaitDecoded(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    if (tester
        .widgetList<RawImage>(find.byType(RawImage))
        .any((image) => image.image != null)) {
      return;
    }
  }
  throw StateError('封面未解码');
}

/// The gate re-arms while measurements keep arriving, so settling takes one
/// quiet window per burst, and the cell commits on the frame after that.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12 && ResizeGate.instance.holding.value; i++) {
    await tester.pump(const Duration(milliseconds: 300));
  }
  await tester.pump();
}

void main() {
  setUp(ResizeGate.instance.debugReset);
  tearDown(() => PaintingBinding.instance.imageCache.clear());

  test('解码宽度按阶梯取档，同档之内不换档', () {
    // 3× 设备上 140 逻辑像素是 420 设备像素，进到 512 一档。
    expect(coverDecodeBucket(140, 3), 512);
    expect(coverDecodeBucket(170, 3), 512);
    expect(coverDecodeBucket(171, 3), 640);
    expect(coverDecodeBucket(260, 3), 896);
    // 量程沿用改动前后一致的 1..1600 语义，只是改成了整档。
    expect(coverDecodeBucket(100, 0.5), 128);
    expect(coverDecodeBucket(900, 3), 1664);
    expect(coverDecodeBucket(double.infinity, 3), 0);
    expect(coverDecodeBucket(0, 3), 0);
  });

  test('缩放持续有测量时闸门不合，静默一个窗口后释放', () async {
    final gate = ResizeGate.instance;
    expect(gate.holding.value, isFalse);
    gate.touch();
    expect(gate.holding.value, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    gate.touch();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(gate.holding.value, isTrue, reason: '拖动还在继续，不该中途放图');
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(gate.holding.value, isFalse);
  });

  testWidgets('拖动窗口期间封面不重建元素、不重取图', (tester) async {
    final folder = Directory.systemTemp.createTempSync('cover-resize-');
    final file = File(
      'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_16.png',
    ).copySync('${folder.path}/pixel.png');
    final cache = _Images(file);
    CachedNetworkImageProvider.defaultCacheManager = cache;
    addTearDown(() => folder.deleteSync(recursive: true));

    await _mount(tester, 140);
    await _awaitDecoded(tester);
    await _settle(tester);
    expect(_decodeSteps(tester), {512});
    expect(cache.requests, 1);
    final painted = tester.element(find.byType(Image));

    // 一次连续的拖宽：需要的档位一路涨到 896，但假时钟没有走过一个静默窗口。
    for (var width = 143.0; width <= 260; width += 3) {
      await _mount(tester, width);
      expect(tester.element(find.byType(Image)), same(painted));
      expect(_decodeSteps(tester), {512});
      // 只有一路图片元素：换档会同时留下新旧两份，那正是明灭的形状。
      expect(find.byType(Image), findsOneWidget);
    }
    expect(cache.requests, 1, reason: '拖动期间一次也不该重解码');

    // 停手：闸门释放，一次补到准确档位。
    await _settle(tester);
    expect(_decodeSteps(tester), contains(896));
    await _settle(tester);
    expect(cache.requests, 2, reason: '停手之后只补一次解码');
    // 旧档位此刻是无空隙回放的底图，仍在树里：换档的那一帧没有空过。
    expect(_decodeSteps(tester), containsAll(<int>[512, 896]));
    expect(tester.takeException(), isNull);
    await _settle(tester);
  });

  testWidgets('离开屏幕的封面不留定时器，闸门不为空场合着', (tester) async {
    final folder = Directory.systemTemp.createTempSync('cover-detach-');
    final file = File(
      'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_16.png',
    ).copySync('${folder.path}/pixel.png');
    CachedNetworkImageProvider.defaultCacheManager = _Images(file);
    addTearDown(() => folder.deleteSync(recursive: true));

    await _mount(tester, 140);
    await tester.pump();
    expect(ResizeGate.instance.holding.value, isTrue);

    // 封面全部下树：静默窗口不该再有人等，否则用例结束时会留下一个定时器。
    await tester.pumpWidget(const SizedBox());
    expect(ResizeGate.instance.holding.value, isFalse);
  });

  testWidgets('补档位不重播淡入，首次出图照旧', (tester) async {
    final folder = Directory.systemTemp.createTempSync('cover-fade-');
    final file = File(
      'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_16.png',
    ).copySync('${folder.path}/pixel.png');
    CachedNetworkImageProvider.defaultCacheManager = _Images(file);
    addTearDown(() => folder.deleteSync(recursive: true));

    await _mount(tester, 140);
    expect(_fadeIn(tester), const Duration(milliseconds: 140));

    await _mount(tester, 260);
    await _settle(tester);
    expect(_fadeIn(tester), Duration.zero, reason: '同一张封面补档位，不该再明灭一次');
    await _settle(tester);
  });
}
